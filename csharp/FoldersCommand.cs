using System.Text.Json;

namespace ForcepointReport;

/// <summary>`folders` subcommand: per-email attachment folders (port of extract_email_folders.py).</summary>
public static class FoldersCommand
{
    public static int Run(string root, string output, bool keepAllVersions, bool extractZips)
    {
        var emails = Core.BuildEmails(root, out _);

        string sevenZip = null;
        if (extractZips)
        {
            sevenZip = Core.Find7Zip();
            if (sevenZip == null)
                Console.Error.WriteLine(
                    "warning: --extract-zips requested but 7-Zip was not found on this machine " +
                    "(checked PATH and standard install locations) - zip attachments will NOT be extracted.");
        }

        string outDir = output ?? Path.Combine(root, "emails_by_date");

        // Bucket emails by agent time: same timestamp -> same folder.
        var groups = new SortedDictionary<string, List<Core.Email>>();
        foreach (var e in emails)
        {
            string ts = Core.TsDirname(Core.AgentTime(e.Ev));
            if (!groups.TryGetValue(ts, out var list)) groups[ts] = list = new List<Core.Email>();
            list.Add(e);
        }

        int made = 0, copied = 0, extracted = 0;
        var zipFailures = new List<string>();

        foreach (var (ts, group) in groups)
        {
            Directory.CreateDirectory(outDir);
            var parties = group.Select(e => Core.Parties(e.Ev)).ToList();
            var frms = parties.Select(p => p.From).Where(f => f != null).Distinct().ToList();
            var tos = parties.Select(p => p.To).Where(t => t != null).Distinct().ToList();

            string baseName = Core.Sanitize($"{ts} - from {(frms.Count > 0 ? string.Join(",", frms) : "unknown")} " +
                                            $"- to {(tos.Count > 0 ? string.Join(",", tos) : "unknown")}");
            var ids = group.Select(e => e.EvidenceId).ToList();

            // Reuse folder on re-runs (idempotent); _N suffix for distinct groups with the same name.
            string folder = Path.Combine(outDir, baseName);
            int n = 1;
            while (Directory.Exists(folder))
            {
                var prev = Core.LoadJson(Path.Combine(folder, ".manifest.json"));
                if (prev != null && prev.Value.TryGetProperty("evidenceIds", out var idsEl) &&
                    idsEl.EnumerateArray().Select(x => x.GetString()).OrderBy(x => x)
                        .SequenceEqual(ids.OrderBy(x => x)))
                    break;   // same group re-processed -> refresh in place
                folder = Path.Combine(outDir, $"{baseName}_{++n}");
            }
            Directory.CreateDirectory(folder);

            var manifest = new
            {
                timestamp = ts,
                evidenceIds = ids,
                emails = group.Zip(parties, (e, p) => new
                {
                    evidenceId = e.EvidenceId,
                    agentTime = Core.AgentTime(e.Ev),
                    from = p.From,
                    to = p.To,
                }).ToList(),
            };
            File.WriteAllText(Path.Combine(folder, ".manifest.json"),
                JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));

            // One copy per filename; with --keep-all-versions, same-named files whose CONTENT
            // differs are kept side by side under a hash-tagged name.
            var present = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var email in group)
                foreach (var att in email.Attachments)
                {
                    string src = Path.Combine(root, "ccd", "binary", att.Hash);
                    if (!File.Exists(src)) continue;
                    string chash = Core.ContentHash(src);
                    string name = Core.Sanitize(att.FileName ?? att.Hash);
                    if (present.ContainsKey(name))
                    {
                        if (present[name] == chash) continue;        // byte-identical copy exists
                        if (!keepAllVersions) continue;              // default: first copy wins
                        int dot = name.IndexOf('.');
                        string stem = dot >= 0 ? name[..dot] : name;
                        string ext = dot >= 0 ? name[dot..] : "";
                        string tag = " [" + att.Hash[..Math.Min(8, att.Hash.Length)] + "]";
                        string cand = $"{stem}{tag}{ext}";
                        int k = 2;
                        while (present.ContainsKey(cand) && present[cand] != chash)
                            cand = $"{stem}{tag} ({k++}){ext}";
                        name = cand;
                    }
                    present[name] = chash;
                    File.Copy(src, Path.Combine(folder, name), true);
                    copied++;

                    if (sevenZip != null && name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                    {
                        string stemName = Path.GetFileNameWithoutExtension(name);
                        string dest = Path.Combine(folder, "extractions",
                            Core.Sanitize(string.IsNullOrEmpty(stemName) ? "archive" : stemName));
                        if (Core.ExtractZip7z(Path.Combine(folder, name), dest, sevenZip)) extracted++;
                        else zipFailures.Add($"{baseName}/{name}");
                    }
                }
            made++;
        }

        string summary = $"Wrote {made} time-grouped email folder(s), {copied} attachment file(s) under {outDir}";
        if (extractZips)
            summary += $", {extracted} zip(s) extracted via 7-Zip" + (sevenZip != null ? $" ({sevenZip})" : "");
        Console.WriteLine(summary);
        foreach (var f in zipFailures) Console.Error.WriteLine($"warning: 7-Zip failed to extract {f}");
        return 0;
    }
}
