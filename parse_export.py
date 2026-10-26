#!/usr/bin/env python3
"""Parse a Forcepoint Investigations Workbench case export and generate an
email-centric HTML report that links each email record to its binary
attachments.

Usage:
    python3 parse_export.py <path-to-CaseExport> [-o report.html]

Design notes
------------
The export's authoritative per-record data lives in the evidence record files
referenced by ``evidences/EvidencesManifest.json``; each has the shape::

    { "evidence": { "channel": 3, "activityCode": 96, ... },
      "evidenceFiles": [ ... ],        # <- attachments live here
      "scores": [...], ... }

Two things were *not* fully captured in the source screenshots, so the parser
is deliberately defensive about them:

1. **Email classification.** A record is treated as an email if its own
   ``evidence.channel == 3`` (the real signal) OR if it appears in
   ``searchresults/SearchResults.json`` labelled ``EMAIL``. The second clause
   keeps the report populated while the on-disk records are still generic
   placeholders (channel 2); with real data the channel field is what wins.

2. **The exact schema of ``evidenceFiles`` entries.** Rather than assume field
   names, we collect the set of known attachment hashes (the 32-hex filenames
   under ``ccd/binary/``) and match any such value found anywhere inside a
   record's ``evidenceFiles`` array. This lights up correctly once real
   records with attachments are present, regardless of the exact key names.

**Attachment materialization.** As the export is processed, each referenced
binary is copied out of ``ccd/binary/`` into an ``attachments/`` folder under
its *original* filename (taken from the ``evidenceFiles`` entry; the hash is
used as a fallback when no name is known). This is non-destructive — the
source files and ``hashes.json`` references are left untouched — and it is what
the report links to, so attachments appear by their real names rather than
opaque hashes. Filename collisions (two distinct binaries sharing a name) are
disambiguated with a ``_N`` suffix.

The generated HTML is self-contained (inline CSS) and written next to the data
by default so its relative links to ``attachments/<name>`` and
``ccd/textextract/<hash>.json`` resolve when opened in a browser.
"""
import argparse
import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path

EMAIL_CHANNEL = 3


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
def load_json(path: Path):
    """Return parsed JSON, or None if the file is missing / malformed."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def esc(value) -> str:
    """HTML-escape a value (None -> empty string)."""
    return html.escape("" if value is None else str(value))


def fmt_ts(ms) -> str:
    """Format an epoch-milliseconds timestamp as readable UTC."""
    if not ms:
        return "—"
    try:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S UTC"
        )
    except (OverflowError, OSError, ValueError):
        return str(ms)


# --------------------------------------------------------------------------- #
# Data extraction
# --------------------------------------------------------------------------- #
def known_binary_hashes(root: Path) -> set:
    """Set of attachment filenames present under ccd/binary/ in this export.

    The directory listing is the source of truth — we do NOT assume a fixed
    hash length, because some reconstructed names are 31/33 chars (OCR slips;
    real MD5 is always 32). Whatever files exist here are the known binaries.
    """
    hashes = set()
    bin_dir = root / "ccd" / "binary"
    if bin_dir.is_dir():
        for p in bin_dir.iterdir():
            if p.is_file():
                hashes.add(p.name.lower())
    return hashes


def find_hashes(obj, known: set):
    """Recursively collect any known attachment hashes found in obj's strings."""
    found = []

    def walk(o):
        if isinstance(o, dict):
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
        elif isinstance(o, str):
            lo = o.strip().lower()
            if lo in known and lo not in found:
                found.append(lo)

    walk(obj)
    return found


def find_filename(entry):
    """Best-effort extraction of a human filename from an evidenceFiles entry."""
    if isinstance(entry, dict):
        for key in ("fileName", "name", "originalName", "displayName", "file_name"):
            v = entry.get(key)
            if isinstance(v, str) and v:
                return v
    return None


def build(root: Path) -> dict:
    """Assemble everything the report needs from the export tree."""
    known = known_binary_hashes(root)

    # SearchResults indexed by evidenceId (for display labels + email fallback).
    sr_list = load_json(root / "searchresults" / "SearchResults.json") or []
    search_by_id = {}
    for sr in sr_list:
        if not isinstance(sr, dict):
            continue
        eid = (sr.get("evidencePK") or {}).get("evidenceId")
        if eid:
            search_by_id[eid] = sr

    # Full evidence records via EvidencesManifest.json.
    em = load_json(root / "evidences" / "EvidencesManifest.json") or {}
    emails = []
    total_records = 0
    for man_eid, rel in em.items():
        rec = load_json(root / rel)
        if not isinstance(rec, dict):
            continue
        total_records += 1
        ev = rec.get("evidence") or {}
        # Placeholder records carry evidenceId=null; the manifest key is the
        # canonical ID and is what SearchResults joins on.
        eid = ev.get("evidenceId") or man_eid
        sr = search_by_id.get(eid)

        is_email = ev.get("channel") == EMAIL_CHANNEL or (
            sr is not None and str(sr.get("channel", "")).upper() == "EMAIL"
        )
        if not is_email:
            continue

        # Attachments: match known binary hashes anywhere in evidenceFiles.
        atts, seen = [], set()
        for entry in rec.get("evidenceFiles") or []:
            for h in find_hashes(entry, known):
                if h not in seen:
                    seen.add(h)
                    atts.append({"hash": h, "fileName": find_filename(entry)})

        emails.append(
            {
                "evidenceId": eid,
                "ev": ev,
                "search": sr,
                "attachments": atts,
            }
        )

    case = load_json(root / "Case.json") or {}
    export = load_json(root / "CaseExport.json") or {}

    return {
        "case": case,
        "export": export,
        "emails": emails,
        "known": known,
        "total_records": total_records,
    }


def _unique_name(base: str, h: str, used: dict) -> str:
    """Return ``base``, or ``base`` with a ``_N`` suffix if a *different* hash
    already claims that filename."""
    if base not in used or used[base] == h:
        return base
    stem, dot, ext = base.partition(".")
    n = 1
    while True:
        cand = f"{stem}_{n}.{ext}" if dot else f"{base}_{n}"
        if cand not in used or used[cand] == h:
            return cand
        n += 1


def materialize_attachments(emails, root: Path, dest_dir: Path) -> dict:
    """Copy each referenced binary from ``ccd/binary/<hash>`` into ``dest_dir``
    under its original filename (hash as fallback). Non-destructive.

    Returns ``{hash: final_filename}`` so the report can link by name.
    """
    # Unique (hash, fileName) pairs across all emails, order-preserving.
    pairs, seen = [], set()
    for email in emails:
        for att in email["attachments"]:
            h = att["hash"]
            if h not in seen:
                seen.add(h)
                pairs.append((h, att.get("fileName")))

    name_map, used = {}, {}
    if pairs:
        dest_dir.mkdir(parents=True, exist_ok=True)
    for h, fname in pairs:
        base = fname if fname else h
        target = _unique_name(base, h, used)
        src = root / "ccd" / "binary" / h
        if src.is_file():
            (dest_dir / target).write_bytes(src.read_bytes())
        name_map[h] = target
        used[target] = h
    return name_map


# --------------------------------------------------------------------------- #
# HTML rendering
# --------------------------------------------------------------------------- #
CSS = """
:root { --bg:#f6f7f9; --card:#fff; --ink:#1c2530; --muted:#6b7684;
        --line:#e2e6ea; --accent:#2b6cb0; --mono:#0f1720; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
       font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
.wrap { max-width:960px; margin:0 auto; padding:32px 20px 80px; }
header.report h1 { font-size:24px; margin:0 0 4px; }
header.report .sub { color:var(--muted); font-size:14px; }
.summary { display:flex; gap:12px; flex-wrap:wrap; margin:20px 0 8px; }
.stat { background:var(--card); border:1px solid var(--line); border-radius:8px;
        padding:10px 16px; min-width:120px; }
.stat .n { font-size:22px; font-weight:600; }
.stat .l { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px;
        padding:20px 22px; margin:18px 0; box-shadow:0 1px 2px rgba(16,24,40,.04); }
.card h2 { font-size:17px; margin:0 0 2px; }
.card .who { color:var(--muted); font-size:14px; margin-bottom:14px; }
table.meta { width:100%; border-collapse:collapse; font-size:13.5px; }
table.meta td { padding:5px 8px 5px 0; vertical-align:top; border-bottom:1px solid var(--line); }
table.meta tr:last-child td { border-bottom:none; }
table.meta td.k { color:var(--muted); width:170px; white-space:nowrap; }
code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
              font-size:12.5px; background:#eef1f4; padding:1px 5px; border-radius:4px; }
.tags { display:flex; flex-wrap:wrap; gap:6px; }
.tag { background:#eaf1fb; color:var(--accent); border-radius:20px; padding:2px 10px; font-size:12.5px; }
h3.att { font-size:14px; margin:20px 0 8px; text-transform:uppercase;
         letter-spacing:.04em; color:var(--muted); }
.attach { border-left:3px solid var(--accent); background:#fbfcfe; border-radius:0 8px 8px 0;
          padding:12px 16px; margin:10px 0; }
.attach .top { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap; }
.attach a.bin { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12.5px;
                color:var(--accent); text-decoration:none; word-break:break-all; }
.attach a.bin:hover { text-decoration:underline; }
.attach .fn { font-weight:600; }
.attach .te-link { font-size:12.5px; color:var(--muted); text-decoration:none; }
.attach .te-link:hover { color:var(--accent); text-decoration:underline; }
pre.te { margin:10px 0 0; padding:12px; background:#0f1720; color:#e6edf3;
         border-radius:8px; overflow:auto; max-height:340px; font-size:12.5px;
         font-family:ui-monospace,Menlo,Consolas,monospace; white-space:pre-wrap; }
.empty { color:var(--muted); font-style:italic; font-size:13.5px; }
footer.report { margin-top:40px; color:var(--muted); font-size:12.5px; text-align:center; }
"""


def render_attachment(att: dict, root: Path, data: dict, out_path: Path) -> str:
    h = att["hash"]
    name_map = data.get("name_map", {})
    display_name = name_map.get(h) or att.get("fileName") or h

    # Link to the materialized copy (original filename), relative to the report.
    att_dir = data.get("attachments_dir")
    if att_dir is not None:
        bin_url = os.path.relpath(Path(att_dir) / display_name, out_path.parent).replace(os.sep, "/")
    else:
        bin_url = f"ccd/binary/{h}"
    te_url = f"ccd/textextract/{h}.json"

    te_raw = load_json(root / "ccd" / "textextract" / f"{h}.json")
    if te_raw is None:
        te_html = '<div class="empty">no text extract</div>'
    else:
        te_text = json.dumps(te_raw, indent=2, ensure_ascii=False)
        te_html = f"<pre class='te'>{esc(te_text)}</pre>"

    return (
        '<div class="attach">'
        f'<div class="top"><span class="fn">{esc(display_name)}</span> · '
        f'<a class="bin" href="{esc(bin_url)}" title="Open binary attachment">{esc(h)}</a>'
        f' <a class="te-link" href="{esc(te_url)}">textextract.json</a></div>'
        f"{te_html}"
        "</div>"
    )


def render_email(email: dict, root: Path, data: dict, out_path: Path) -> str:
    ev = email["ev"]
    sr = email.get("search") or {}

    who = sr.get("personLabel") or ev.get("applicationName") or "—"
    date = fmt_ts(ev.get("dateId") or ev.get("startDate"))

    def tags(lst):
        if not lst:
            return '<span class="empty">—</span>'
        return '<div class="tags">' + "".join(
            f'<span class="tag">{esc(t)}</span>' for t in lst
        ) + "</div>"

    rows = [
        ("Date", f"<code>{esc(date)}</code>"),
        ("Evidence ID", f"<code>{esc(email['evidenceId'])}</code>"),
        ("Channel / Activity", f"{esc(ev.get('channel'))} / {esc(ev.get('activityCode'))}"),
        ("Application", esc(ev.get("applicationName"))),
        ("User", f"<code>{esc(ev.get('userId'))}</code>"),
        ("Agent", f"<code>{esc(ev.get('agentId'))}</code>"),
        ("Match text", esc(ev.get("matchText")) or '<span class="empty">—</span>'),
        ("Triggers", tags(ev.get("triggerLabels"))),
        ("Categories", tags(ev.get("categoryLabels"))),
        ("Groups", tags(ev.get("groupLabels"))),
    ]
    meta = "".join(
        f'<tr><td class="k">{k}</td><td>{v}</td></tr>' for k, v in rows
    )

    atts = email["attachments"]
    if atts:
        att_html = "".join(render_attachment(a, root, data, out_path) for a in atts)
    else:
        att_html = (
            '<div class="empty">No attachments captured for this record '
            "(evidenceFiles empty — placeholder or no files).</div>"
        )

    return (
        '<section class="card">'
        f"<h2>Email</h2>"
        f'<div class="who">{esc(who)}</div>'
        f'<table class="meta">{meta}</table>'
        f'<h3 class="att">Attachments ({len(atts)})</h3>'
        f"{att_html}"
        "</section>"
    )


def render_report(data: dict, root: Path, out_path: Path) -> str:
    case = data["case"]
    emails = data["emails"]
    n_att = sum(len(e["attachments"]) for e in emails)

    body_cards = "".join(render_email(e, root, data, out_path) for e in emails)
    if not emails:
        body_cards = (
            '<section class="card"><div class="empty">'
            "No email records found. Once evidence records with channel 3 "
            "(EMAIL) and populated evidenceFiles are present, they will appear here."
            "</div></section>"
        )

    generated = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Forcepoint Case Report — {esc(case.get('name', 'unnamed'))}</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<header class="report">
  <h1>Forcepoint Case Report</h1>
  <div class="sub">{esc(case.get('name', ''))} · case {esc(case.get('id', ''))} · generated {generated}</div>
</header>

<div class="summary">
  <div class="stat"><div class="n">{len(emails)}</div><div class="l">Email records</div></div>
  <div class="stat"><div class="n">{n_att}</div><div class="l">Attachments linked</div></div>
  <div class="stat"><div class="n">{len(data['known'])}</div><div class="l">Known binaries</div></div>
  <div class="stat"><div class="n">{data['total_records']}</div><div class="l">Total records</div></div>
</div>

{body_cards}

<footer class="report">Generated by parse_export.py from a Forcepoint Investigations Workbench export.</footer>
</div>
</body>
</html>
"""


# --------------------------------------------------------------------------- #
def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate an email-centric HTML report from a Forcepoint case export"
    )
    ap.add_argument("root", help="Path to the CaseExport directory")
    ap.add_argument(
        "-o", "--output", default=None,
        help="Output HTML path (default: <root>/report.html)",
    )
    ap.add_argument(
        "--attachments-dir", default=None,
        help="Where to materialize renamed attachments "
             "(default: <root>/attachments; pass '' to skip)",
    )
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not (root / "UberManifest.json").exists():
        raise SystemExit(f"error: {root} does not look like a CaseExport (no UberManifest.json)")

    out = Path(args.output).resolve() if args.output else root / "report.html"
    data = build(root)

    # Materialize attachments under their original filenames.
    if args.attachments_dir is None:
        att_dir = root / "attachments"
    elif args.attachments_dir == "":
        att_dir = None
    else:
        att_dir = Path(args.attachments_dir).resolve()
    if att_dir is not None:
        data["name_map"] = materialize_attachments(data["emails"], root, att_dir)
        data["attachments_dir"] = str(att_dir)

    out.write_text(render_report(data, root, out))
    n_mat = len(data.get("name_map", {}))
    print(
        f"Wrote {out}  "
        f"({len(data['emails'])} email(s), "
        f"{sum(len(e['attachments']) for e in data['emails'])} attachment(s), "
        f"{n_mat} materialized -> {att_dir if att_dir else '(skipped)'}, "
        f"{len(data['known'])} known binaries)"
    )


if __name__ == "__main__":
    main()
