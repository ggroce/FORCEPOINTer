#!/usr/bin/env python3
"""Organize a Forcepoint case export's email attachments into per-email folders.

Usage:
    python3 extract_email_folders.py <path-to-CaseExport> [-o outdir] [--extract-zips]

Emails are grouped by the *agent* time of the record (``evidence.agentTime``,
falling back to ``startDate`` / ``dateId``): every email sharing the same
timestamp goes into **one** folder, and attachments with the same filename are
kept only **once** per folder. The folder name lists all senders/recipients in
the group (comma-joined)::

    2026-09-27_143806 - from alice@corp.com - to bob@partner.com/
        INSPECTION REPORT.pdf          <- original filename, not the hash
        Q4-budget.xlsx                 <- single copy even if two emails carry it

Attachments are copied from ``ccd/binary/<hash>`` under their original names.

Sender/recipient extraction
---------------------------
The export does not store "from"/"to" in one canonical place (and the exact
schema of ``evidenceFiles`` is not fully documented), so extraction is layered:

1. Explicit fields on the record, if present: ``sender``/``from``/... and
   ``recipients``/``to``/...
2. Otherwise, all email addresses found anywhere in the record's JSON, in
   order: first = from, second = to (a heuristic; real exports vary).
3. Unknown sides become ``unknown``.

Zip attachments (``--extract-zips``)
-----------------------------------
With the flag on, any attachment whose name ends in ``.zip`` is additionally
extracted into ``<email folder>/extractions/<zip-name>/`` **using 7-Zip only**
— no other backend. 7-Zip's CLI (``7z.exe``) ships with every standard Windows
install; the tool auto-detects it via ``PATH`` and the standard install
locations (``C:\\Program Files\\7-Zip\\7z.exe`` …). If 7-Zip is not found,
zip extraction is **skipped entirely** with a warning — nothing is extracted
by other means, and the run never fails. (7-Zip itself sanitizes absolute
paths and ``..`` traversal when extracting.)

Non-destructive: nothing under the CaseExport tree is modified; folders are
created under ``<root>/emails_by_date`` by default.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Make the sibling module importable even under `python3 -I` (isolated mode).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from parse_export import build  # same repo, shared parsing logic

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
FROM_KEYS = ("from", "sender", "originator", "mailFrom", "fromAddress")
TO_KEYS = ("to", "recipient", "recipients", "rcptTo", "toAddress")


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def agent_time(ev: dict) -> int:
    """Record's agent time, falling back to startDate then dateId."""
    for key in ("agentTime", "startDate", "dateId"):
        v = ev.get(key)
        if isinstance(v, (int, float)) and v:
            return int(v)
    return 0


def ts_dirname(ms: int) -> str:
    if not ms:
        return "unknown-time"
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d_%H%M%S")


def _field_address(ev: dict, keys) -> str:
    """Return the first email address found under any of ``keys`` in ev."""
    for key in keys:
        v = ev.get(key)
        if isinstance(v, list):
            v = " ".join(str(x) for x in v)
        if isinstance(v, str):
            m = EMAIL_RE.search(v)
            if m:
                return m.group(0)
    return None


def extract_parties(ev: dict):
    """Best-effort (from_addr, to_addr) for an email record."""
    frm = _field_address(ev, FROM_KEYS)
    to = _field_address(ev, TO_KEYS)
    if not (frm and to):
        # Fall back to scanning every string in the record, order-preserving.
        found = []
        for addr in EMAIL_RE.findall(json.dumps(ev)):
            if addr.lower() not in [a.lower() for a in found]:
                found.append(addr)
        if not frm and found:
            frm = found[0]
        if not to and len(found) > 1:
            to = found[1]
    return frm, to


def sanitize(name: str) -> str:
    """Make a string safe for a folder/file name on common filesystems."""
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")
    return name[:120] if len(name) > 120 else name


def find_7zip():
    """Locate a 7-Zip CLI: PATH first, then standard Windows install dirs.

    Binary names across builds: ``7z``/``7z.exe`` (Windows), ``7zz`` (the
    official port on macOS/Linux, e.g. Homebrew p7zip), ``7za`` (standalone),
    ``7zip`` (newer 7-Zip releases). Returns the executable path, or None.
    """
    for name in ("7z", "7zz", "7za", "7zip", "7z.exe", "7zz.exe", "7za.exe", "7zip.exe"):
        p = shutil.which(name)
        if p:
            return p
    if os.name == "nt":
        for cand in (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "7-Zip" / "7z.exe",
            Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "7-Zip" / "7z.exe",
        ):
            if cand.is_file():
                return str(cand)
    return None


def extract_zip_7z(archive: Path, dest: Path, sevenzip: str) -> bool:
    """Extract ``archive`` into ``dest`` using 7-Zip only (no fallback).

    7-Zip sanitizes member paths by default (strips absolute paths / drive
    letters, defuses ``..`` traversal), so extraction is zip-slip safe.
    Returns True on success.
    """
    dest.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [sevenzip, "x", "-y", "-bso0", "-bsp0", f"-o{dest}", str(archive)],
        capture_output=True,
    )
    return r.returncode == 0


def unique_folder(out_dir: Path, base: str, evidence_ids) -> Path:
    """Folder for this time-group: reused on re-runs (idempotent), ``_N``-suffixed
    when a *different* group already claimed the same name."""
    want = sorted(evidence_ids)
    cand = out_dir / base
    n = 1
    while cand.exists():
        prev = load_json(cand / ".manifest.json")
        if prev and sorted(prev.get("evidenceIds", [])) == want:
            return cand  # same group re-processed -> refresh in place
        n += 1
        cand = out_dir / f"{base}_{n}"
    return cand


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Create per-email attachment folders (agent time + from/to) "
                    "from a Forcepoint case export"
    )
    ap.add_argument("root", help="Path to the CaseExport directory")
    ap.add_argument(
        "-o", "--output", default=None,
        help="Output root for the folders (default: <root>/emails_by_date)",
    )
    ap.add_argument(
        "--extract-zips", action="store_true",
        help="Extract .zip attachments into <email folder>/extractions/<zip-name>/ "
             "using 7-Zip ONLY; skipped with a warning if 7-Zip is not found",
    )
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not (root / "UberManifest.json").exists():
        raise SystemExit(f"error: {root} does not look like a CaseExport (no UberManifest.json)")

    out_dir = Path(args.output).resolve() if args.output else root / "emails_by_date"
    data = build(root)

    sevenzip = None
    if args.extract_zips:
        sevenzip = find_7zip()
        if not sevenzip:
            print(
                "warning: --extract-zips requested but 7-Zip was not found on this "
                "machine (checked PATH and standard install locations) — zip "
                "attachments will NOT be extracted.",
                file=sys.stderr,
            )

    # Bucket emails by agent-time: same timestamp -> same folder.
    groups = {}
    for email in data["emails"]:
        ts = ts_dirname(agent_time(email["ev"]))
        groups.setdefault(ts, []).append(email)

    made, copied, extracted = 0, 0, 0
    zip_failures = []
    for ts, emails in sorted(groups.items()):
        parties = [extract_parties(e["ev"]) for e in emails]
        frms, tos = [], []
        for f, t in parties:
            if f and f not in frms:
                frms.append(f)
            if t and t not in tos:
                tos.append(t)

        base = sanitize(
            f"{ts} - from {','.join(frms) or 'unknown'} - to {','.join(tos) or 'unknown'}"
        )
        ids = [e["evidenceId"] for e in emails]
        folder = unique_folder(out_dir, base, ids)
        folder.mkdir(parents=True, exist_ok=True)

        # Sidecar so re-runs reuse this folder and disambiguate distinct groups.
        (folder / ".manifest.json").write_text(json.dumps({
            "timestamp": ts,
            "evidenceIds": ids,
            "emails": [
                {"evidenceId": e["evidenceId"], "agentTime": agent_time(e["ev"]),
                 "from": f, "to": t}
                for e, (f, t) in zip(emails, parties)
            ],
        }, indent=4) + "\n")

        # One copy per filename across the whole time-group.
        present = set()
        for email in emails:
            for att in email["attachments"]:
                name = sanitize(att.get("fileName") or att["hash"])
                if name in present:
                    continue  # same-named attachment already in this folder
                present.add(name)
                src = root / "ccd" / "binary" / att["hash"]
                if src.is_file():
                    shutil.copy2(src, folder / name)
                    copied += 1
                    if sevenzip and name.lower().endswith(".zip"):
                        dest = folder / "extractions" / (sanitize(Path(name).stem) or "archive")
                        if extract_zip_7z(folder / name, dest, sevenzip):
                            extracted += 1
                        else:
                            zip_failures.append(f"{folder.name}/{name}")
        made += 1

    summary = f"Wrote {made} time-grouped email folder(s), {copied} attachment file(s) under {out_dir}"
    if args.extract_zips:
        summary += f", {extracted} zip(s) extracted via 7-Zip" + (f" ({sevenzip})" if sevenzip else "")
    print(summary + ("" if data["emails"] else "  (no EMAIL records found in this export)"))
    for f in zip_failures:
        print(f"warning: 7-Zip failed to extract {f}", file=sys.stderr)


if __name__ == "__main__":
    main()
