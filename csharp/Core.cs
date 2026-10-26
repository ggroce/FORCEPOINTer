using System.Text.Json;
using System.Text.RegularExpressions;

namespace ForcepointReport;

/// <summary>Shared parsing helpers for the Forcepoint case export (port of parse_export.py).</summary>
public static class Core
{
    public record Attachment(string Hash, string FileName);
    public record Email(string EvidenceId, JsonElement Ev, JsonElement? Search, List<Attachment> Attachments);

    public static JsonElement? LoadJson(string path)
    {
        if (!File.Exists(path)) return null;
        try { return JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone(); }
        catch (JsonException) { return null; }
    }

    /// <summary>Attachment filenames present under ccd/binary (source of truth, no length assumption).</summary>
    public static HashSet<string> KnownBinaries(string root)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string dir = Path.Combine(root, "ccd", "binary");
        if (Directory.Exists(dir))
            foreach (var f in Directory.EnumerateFiles(dir)) set.Add(Path.GetFileName(f));
        return set;
    }

    /// <summary>Find known binary hashes anywhere inside a JSON element's raw text.</summary>
    public static List<string> FindHashes(string jsonText, HashSet<string> known)
    {
        var hits = new List<(int Index, string Hash)>();
        foreach (var k in known)
        {
            int i = jsonText.IndexOf(k, StringComparison.OrdinalIgnoreCase);
            if (i >= 0) hits.Add((i, k));
        }
        return hits.OrderBy(h => h.Index).Select(h => h.Hash).ToList();
    }

    public static string GetFileName(JsonElement entry)
    {
        foreach (var key in new[] { "fileName", "name", "originalName", "displayName", "file_name" })
            if (entry.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
        return null;
    }

    public static List<Email> BuildEmails(string root, out int totalRecords)
    {
        totalRecords = 0;
        var known = KnownBinaries(root);

        var searchById = new Dictionary<string, JsonElement>();
        var srAll = LoadJson(Path.Combine(root, "searchresults", "SearchResults.json"));
        if (srAll?.ValueKind == JsonValueKind.Array)
            foreach (var e in srAll.Value.EnumerateArray())
                if (e.TryGetProperty("evidencePK", out var pk) &&
                    pk.TryGetProperty("evidenceId", out var eid) && eid.ValueKind == JsonValueKind.String)
                    searchById[eid.GetString()] = e;

        var manifest = LoadJson(Path.Combine(root, "evidences", "EvidencesManifest.json"));
        var emails = new List<Email>();
        if (manifest?.ValueKind != JsonValueKind.Object) return emails;

        foreach (var prop in manifest.Value.EnumerateObject())
        {
            string recPath = Path.Combine(root,
                prop.Value.GetString().Replace('/', Path.DirectorySeparatorChar));
            var rec = LoadJson(recPath);
            if (rec?.ValueKind != JsonValueKind.Object || !rec.Value.TryGetProperty("evidence", out var ev))
                continue;
            totalRecords++;

            string eid = ev.TryGetProperty("evidenceId", out var eidEl) && eidEl.ValueKind == JsonValueKind.String
                ? eidEl.GetString() : prop.Name;   // manifest key is canonical (placeholder records are null)
            searchById.TryGetValue(eid, out var sr);
            JsonElement? search = sr.ValueKind == JsonValueKind.Object ? sr : null;   // default struct is Undefined -> not usable

            int channel = ev.TryGetProperty("channel", out var ch) && ch.ValueKind == JsonValueKind.Number
                ? ch.GetInt32() : -1;
            bool isEmail = channel == 3 ||
                (search != null &&
                 search.Value.TryGetProperty("channel", out var sch) &&
                 string.Equals(sch.GetString(), "EMAIL", StringComparison.OrdinalIgnoreCase));
            if (!isEmail) continue;

            var atts = new List<Attachment>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (rec.Value.TryGetProperty("evidenceFiles", out var files) && files.ValueKind == JsonValueKind.Array)
                foreach (var entry in files.EnumerateArray())
                    foreach (var h in FindHashes(entry.GetRawText(), known))
                        if (seen.Add(h))
                            atts.Add(new Attachment(h, GetFileName(entry)));

            emails.Add(new Email(eid, ev, search, atts));
        }
        return emails;
    }

    public static string Sanitize(string name)
    {
        var cleaned = new string(name.Select(c =>
            "<>:\"/\\|?*".Contains(c) || c < 0x20 ? '_' : c).ToArray()).Trim(' ', '.');
        return cleaned.Length > 120 ? cleaned[..120] : cleaned;
    }

    public static long AgentTime(JsonElement ev)
    {
        foreach (var key in new[] { "agentTime", "startDate", "dateId" })
            if (ev.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.GetInt64() != 0)
                return v.GetInt64();
        return 0;
    }

    public static string TsDirname(long ms) => ms == 0
        ? "unknown-time"
        : DateTimeOffset.FromUnixTimeMilliseconds(ms).ToUniversalTime().ToString("yyyy-MM-dd_HHmmss");

    public static string FormatTs(long ms) => ms == 0
        ? "-"
        : DateTimeOffset.FromUnixTimeMilliseconds(ms).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC");

    private static readonly Regex EmailRx =
        new(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", RegexOptions.Compiled);

    public static string FieldAddress(JsonElement ev, string[] keys)
    {
        foreach (var key in keys)
            if (ev.TryGetProperty(key, out var v))
            {
                string s = v.ValueKind == JsonValueKind.Array
                    ? string.Join(" ", v.EnumerateArray().Select(x => x.ToString()))
                    : v.ToString();
                var m = EmailRx.Match(s);
                if (m.Success) return m.Value;
            }
        return null;
    }

    public static (string From, string To) Parties(JsonElement ev)
    {
        var from = FieldAddress(ev, new[] { "from", "sender", "originator", "mailFrom", "fromAddress" });
        var to = FieldAddress(ev, new[] { "to", "recipient", "recipients", "rcptTo", "toAddress" });
        if (from == null || to == null)
        {
            var found = new List<string>();
            foreach (Match m in EmailRx.Matches(ev.GetRawText()))
                if (!found.Any(f => f.Equals(m.Value, StringComparison.OrdinalIgnoreCase)))
                    found.Add(m.Value);
            from ??= found.Count > 0 ? found[0] : null;
            to ??= found.Count > 1 ? found[1] : null;
        }
        return (from, to);
    }

    public static string ContentHash(string path)
    {
        using var sha = System.Security.Cryptography.SHA256.Create();
        return Convert.ToHexString(sha.ComputeHash(File.ReadAllBytes(path))).ToLowerInvariant();
    }

    /// <summary>Locate the 7-Zip CLI: PATH first, then standard Windows install dirs.</summary>
    public static string Find7Zip()
    {
        var pathVar = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator);
        foreach (var name in new[] { "7z", "7zz", "7za", "7zip", "7z.exe", "7zz.exe", "7za.exe", "7zip.exe" })
            foreach (var dir in pathVar)
            {
                var cand = Path.Combine(dir, name);
                if (File.Exists(cand)) return cand;
            }
        if (OperatingSystem.IsWindows())
            foreach (var pf in new[] { Environment.GetEnvironmentVariable("ProgramFiles"),
                                       Environment.GetEnvironmentVariable("ProgramFiles(x86)") })
                if (!string.IsNullOrEmpty(pf))
                {
                    var cand = Path.Combine(pf, "7-Zip", "7z.exe");
                    if (File.Exists(cand)) return cand;
                }
        return null;
    }

    /// <summary>Extract a zip using 7-Zip ONLY (no fallback). True on success.</summary>
    public static bool ExtractZip7z(string archive, string dest, string sevenZip)
    {
        Directory.CreateDirectory(dest);
        var psi = new System.Diagnostics.ProcessStartInfo(sevenZip)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        psi.ArgumentList.Add("x");
        psi.ArgumentList.Add("-y");
        psi.ArgumentList.Add("-bso0");
        psi.ArgumentList.Add("-bsp0");
        psi.ArgumentList.Add($"-o{dest}");
        psi.ArgumentList.Add(archive);
        using var p = System.Diagnostics.Process.Start(psi);
        p.StandardOutput.ReadToEnd();
        p.StandardError.ReadToEnd();
        p.WaitForExit();
        return p.ExitCode == 0;
    }
}
