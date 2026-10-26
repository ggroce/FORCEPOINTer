using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using static System.Net.WebUtility;

namespace ForcepointReport;

/// <summary>`report` subcommand: HTML report + attachment materialization (port of parse_export.py).</summary>
public static class ReportCommand
{
    // Byte-identical to CSS in parse_export.py (leading/trailing newlines included).
    const string Css = """

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

""";

    // Mirror Python's html.escape: & < > " plus ' (HtmlEncode leaves ' alone).
    static string Esc(string s) => HtmlEncode(s ?? "").Replace("'", "&#x27;");

    public static int Run(string root, string output, string attachmentsDirArg)
    {
        var caseJson = Core.LoadJson(Path.Combine(root, "Case.json"));
        var emails = Core.BuildEmails(root, out int totalRecords);
        var known = Core.KnownBinaries(root);

        string outPath = output ?? Path.Combine(root, "report.html");
        string attDir = attachmentsDirArg == "" ? null
            : attachmentsDirArg != null ? Path.GetFullPath(attachmentsDirArg)
            : Path.Combine(root, "attachments");

        // Materialize: copy referenced binaries under original filenames (collision -> _N).
        var nameMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var used = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (attDir != null)
        {
            Directory.CreateDirectory(attDir);
            foreach (var atts in emails.Select(e => e.Attachments))
                foreach (var a in atts)
                {
                    if (nameMap.ContainsKey(a.Hash)) continue;
                    string target = UniqueName(a.FileName ?? a.Hash, a.Hash, used);
                    string src = Path.Combine(root, "ccd", "binary", a.Hash);
                    if (File.Exists(src)) File.Copy(src, Path.Combine(attDir, target), true);
                    nameMap[a.Hash] = target;
                    used[target] = a.Hash;
                }
        }

        string caseName = caseJson?.TryGetProperty("name", out var nm) == true ? nm.GetString() : "";
        string caseTitle = caseJson?.TryGetProperty("name", out var nm2) == true ? nm2.GetString() : "unnamed";
        string caseId = caseJson?.TryGetProperty("id", out var id) == true ? id.ToString() : "";
        int nAtt = emails.Sum(e => e.Attachments.Count);

        var cards = new StringBuilder();
        if (emails.Count == 0)
            cards.Append("<section class=\"card\"><div class=\"empty\">No email records found. Once evidence records with channel 3 (EMAIL) and populated evidenceFiles are present, they will appear here.</div></section>");
        foreach (var email in emails) RenderEmail(cards, email, root, attDir, outPath, nameMap);

        var sb = new StringBuilder();
        sb.Append($$"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Forcepoint Case Report — {{Esc(caseTitle)}}</title>
<style>{{Css}}</style>
</head>
<body>
<div class="wrap">
<header class="report">
  <h1>Forcepoint Case Report</h1>
  <div class="sub">{{Esc(caseName)}} · case {{Esc(caseId)}} · generated {{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss UTC}}</div>
</header>

<div class="summary">
  <div class="stat"><div class="n">{{emails.Count}}</div><div class="l">Email records</div></div>
  <div class="stat"><div class="n">{{nAtt}}</div><div class="l">Attachments linked</div></div>
  <div class="stat"><div class="n">{{known.Count}}</div><div class="l">Known binaries</div></div>
  <div class="stat"><div class="n">{{totalRecords}}</div><div class="l">Total records</div></div>
</div>

""");
        sb.Append('\n').Append(cards);   // blank line between summary and first card (raw strings drop the final terminator)
        sb.Append("""


<footer class="report">Generated by ForcepointReport (C#) from a Forcepoint Investigations Workbench export.</footer>
</div>
</body>
</html>

""");
        File.WriteAllText(outPath, sb.ToString());

        Console.WriteLine($"Wrote {outPath}  ({emails.Count} email(s), {nAtt} attachment(s), {nameMap.Count} materialized -> {(attDir ?? "(skipped)")}, {known.Count} known binaries)");
        return 0;
    }

    static string UniqueName(string baseName, string hash, Dictionary<string, string> used)
    {
        if (!used.ContainsKey(baseName) || used[baseName] == hash) return baseName;
        int dot = baseName.IndexOf('.');
        string stem = dot >= 0 ? baseName[..dot] : baseName;
        string ext = dot >= 0 ? baseName[dot..] : "";
        for (int n = 1; ; n++)
        {
            string cand = $"{stem}_{n}{ext}";
            if (!used.ContainsKey(cand) || used[cand] == hash) return cand;
        }
    }

    static string Tags(JsonElement ev, string key)
    {
        if (!ev.TryGetProperty(key, out var list) || list.ValueKind != JsonValueKind.Array ||
            list.GetArrayLength() == 0)
            return "<span class=\"empty\">—</span>";
        return "<div class=\"tags\">" + string.Concat(
            list.EnumerateArray().Select(t => $"<span class=\"tag\">{Esc(t.ToString())}</span>")) + "</div>";
    }

    static void RenderEmail(StringBuilder sb, Core.Email email, string root, string attDir, string outPath,
                            Dictionary<string, string> nameMap)
    {
        var ev = email.Ev;
        string Str(string key) => ev.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.ToString() : null;

        string who = null;
        if (email.Search?.TryGetProperty("personLabel", out var pl) == true && pl.ValueKind == JsonValueKind.String)
            who = pl.GetString();
        who ??= Str("applicationName") ?? "—";

        long dateMs = ev.TryGetProperty("dateId", out var d1) && d1.ValueKind == JsonValueKind.Number && d1.GetInt64() != 0
            ? d1.GetInt64()
            : (ev.TryGetProperty("startDate", out var d2) && d2.ValueKind == JsonValueKind.Number ? d2.GetInt64() : 0);

        var rows = new List<(string K, string V)>
        {
            ("Date", $"<code>{Esc(Core.FormatTs(dateMs))}</code>"),
            ("Evidence ID", $"<code>{Esc(email.EvidenceId)}</code>"),
            ("Channel / Activity", $"{Esc(Str("channel"))} / {Esc(Str("activityCode"))}"),
            ("Application", Esc(Str("applicationName"))),
            ("User", $"<code>{Esc(Str("userId"))}</code>"),
            ("Agent", $"<code>{Esc(Str("agentId"))}</code>"),
            ("Match text", string.IsNullOrEmpty(Str("matchText")) ? "<span class=\"empty\">—</span>" : Esc(Str("matchText"))),
            ("Triggers", Tags(ev, "triggerLabels")),
            ("Categories", Tags(ev, "categoryLabels")),
            ("Groups", Tags(ev, "groupLabels")),
        };

        sb.Append($"<section class=\"card\"><h2>Email</h2><div class=\"who\">{Esc(who)}</div><table class=\"meta\">");
        foreach (var (k, v) in rows) sb.Append($"<tr><td class=\"k\">{k}</td><td>{v}</td></tr>");
        sb.Append("</table>");

        int n = email.Attachments.Count;
        sb.Append($"<h3 class=\"att\">Attachments ({n})</h3>");
        if (n == 0)
            sb.Append("<div class=\"empty\">No attachments captured for this record (evidenceFiles empty — placeholder or no files).</div>");
        foreach (var att in email.Attachments)
        {
            string display = nameMap.TryGetValue(att.Hash, out var mat) ? mat : att.FileName ?? att.Hash;
            string binUrl = attDir != null
                ? Path.GetRelativePath(Path.GetDirectoryName(Path.GetFullPath(outPath)),
                                       Path.Combine(attDir, display)).Replace('\\', '/')
                : $"ccd/binary/{att.Hash}";

            sb.Append($"<div class=\"attach\"><div class=\"top\"><span class=\"fn\">{Esc(display)}</span> · " +
                      $"<a class=\"bin\" href=\"{Esc(binUrl)}\" title=\"Open binary attachment\">{Esc(att.Hash)}</a>" +
                      $" <a class=\"te-link\" href=\"ccd/textextract/{Esc(att.Hash)}.json\">textextract.json</a></div>");

            var te = Core.LoadJson(Path.Combine(root, "ccd", "textextract", att.Hash + ".json"));
            if (te == null) sb.Append("<div class=\"empty\">no text extract</div>");
            else sb.Append($"<pre class='te'>{Esc(JsonSerializer.Serialize(te.Value, new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))}</pre>");
            sb.Append("</div>");
        }
        sb.Append("</section>");
    }
}
