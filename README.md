# Forcepoint Case Export → Report & Email Folders

Two small Python tools for working with a **Forcepoint Investigations Workbench**
case export (the JSON + binary tree produced when a case is exported from the
workbench):

| Tool | What it does |
|---|---|
| `parse_export.py` | Generates an **email-centric HTML report** that links each email record to its binary attachments, materializing every attachment under its **original filename** (not the hash). |
| `extract_email_folders.py` | Creates **one folder per email**, named `<agent-time> - from <sender> - to <recipient>`, containing that email's attachments by original filename. |

Both are **non-destructive** — they only read the export and write output into
their own folders. No third-party dependencies; Python 3.8+ standard library only.

## Quick start

Try it on the bundled synthetic demo (no real data needed):

```bash
python3 parse_export.py examples/demo_case
open examples/demo_case/report.html        # macOS; xdg-open on Linux

python3 extract_email_folders.py examples/demo_case
ls examples/demo_case/emails_by_date
# 2026-09-27_071807 - from j.alvarez@northridge-industries.com - to p.nasser@meridian-trade.example/
#     INSPECTION REPORT.pdf          <- two emails in this slot both carry it; one copy kept
#     Q4-budget.xlsx
#     meeting-notes.txt
# 2026-09-28_072203 - from p.nasser@meridian-trade.example - to j.alvarez@northridge-industries.com/
#     Q4-budget.xlsx
#     evidence-bundle.zip
```

(The demo has three emails; two share an agent time, so they land in the same folder.)

```bash
# Zip attachments also unpack into extractions/ — requires 7-Zip installed;
# skipped with a warning when it is not.
python3 extract_email_folders.py examples/demo_case --extract-zips
```

Then point it at a real export:

```bash
python3 parse_export.py /path/to/CaseExport
python3 extract_email_folders.py /path/to/CaseExport
```

> Tip: if you process exports downloaded from untrusted sources, run with
> `python3 -I` (isolated mode) so no local files shadow the stdlib. Both tools
> are built to work under `-I`.

## parse_export.py — HTML report

```
python3 parse_export.py <CaseExport> [-o report.html] [--attachments-dir DIR]
```

- `-o / --output` — report path (default `<CaseExport>/report.html`)
- `--attachments-dir` — where to copy renamed attachments
  (default `<CaseExport>/attachments`; pass `''` to skip materializing)

**Output:** a self-contained HTML file (inline CSS) with one card per email:
date, evidence ID, channel/activity, user, agent, triggers, categories and
groups, plus an **Attachments** section. Each attachment is shown by its
original filename, links to the materialized copy in `attachments/`, shows its
hash for reference, links to its text extract, and renders the extracted text
inline.

## extract_email_folders.py — per-email folders

```
python3 extract_email_folders.py <CaseExport> [-o DIR] [--extract-zips]
```

- `-o / --output` — output root (default `<CaseExport>/emails_by_date`)
- `--extract-zips` — additionally extract every `.zip` attachment into
  `<email folder>/extractions/<zip-name>/`, **using 7-Zip only**:

  ```
  2026-09-28_072203 - from p.nasser@... - to j.alvarez@.../
      evidence-bundle.zip
      extractions/evidence-bundle/
          report.txt
          memo/memo.txt
  ```

  The tool auto-detects the 7-Zip CLI (`7z.exe`) via `PATH` and the standard
  Windows install locations (`C:\Program Files\7-Zip\`). 7-Zip's CLI ships with
  every standard Windows install, so on a machine where 7-Zip is installed this
  works out of the box. **If 7-Zip is not found, zip extraction is skipped
  entirely** with a warning — there is no fallback to other tools, and the run
  never fails. (7-Zip also sanitizes member paths, so extraction is zip-slip
  safe.)

Emails are grouped by **agent time**: every email record sharing the same
timestamp goes into one folder, named

    YYYY-MM-DD_HHMMSS - from <senders> - to <recipients>

(UTC; all senders/recipients in the group are comma-joined; unknown sides
render as `unknown`). Attachments land under their original filenames, and a
filename is kept only **once** per folder — when two emails in the slot carry
the same name, the first one wins. A small hidden `.manifest.json` sidecar
records the group's evidence IDs so re-runs refresh in place instead of
duplicating folders; distinct groups with identical names get `_2`, `_3`, …
suffixes.

## Expected export layout

Both tools read this standard case-export structure:

```
CaseExport/
├── UberManifest.json                      # presence is used as a sanity check
├── Case.json                              # case id + name (report header)
├── CaseExport.json                        # export metadata
├── searchresults/SearchResults.json       # flattened view; display labels, EMAIL fallback
├── security/hashes.json                   # path -> MD5 map (informational)
├── ccd/binary/<hash>                      # binary attachments
├── ccd/textextract/<hash>.json            # extracted text per attachment
└── evidences/
    ├── EvidencesManifest.json             # evidenceId -> record file
    └── evidences/<folder>/<record>.json   # full evidence records
```

## How it works (and the assumptions)

- **Email detection:** a record is an email when `evidence.channel == 3`, or
  when `SearchResults.json` labels it `EMAIL` (fallback that keeps reports
  populated while record files are incomplete).
- **Attachment matching:** the exact schema of `evidenceFiles` entries varies,
  so instead of assuming field names the tools collect the filenames present in
  `ccd/binary/` and match any of them found anywhere inside a record's
  `evidenceFiles`. The original filename is read from common fields
  (`fileName`, `name`, `originalName`, …), falling back to the hash.
- **Sender/recipient:** checked as explicit fields first (`sender`/`from`,
  `recipients`/`to`, …), then by scanning all strings in the record for email
  addresses (first = from, second = to). Real exports vary — verify the
  mapping on your data.
- **Hash lengths:** real MD5 names are 32 hex chars; exports reconstructed from
  other sources may contain near-miss lengths, so nothing assumes a fixed
  length — `ccd/binary/` is the source of truth.

## License

MIT — see [LICENSE](LICENSE).
