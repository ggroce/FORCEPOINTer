namespace ForcepointReport;

/// <summary>
/// C# port of the two Python tools. Usage:
///   ForcepointReport report  &lt;CaseExport&gt; [-o out.html] [--attachments-dir DIR]
///   ForcepointReport folders &lt;CaseExport&gt; [-o DIR] [--keep-all-versions] [--extract-zips]
/// </summary>
public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length < 2 || args[0] is "-h" or "--help")
        {
            Console.WriteLine("""
ForcepointReport - Forcepoint case export tooling (C# port)

  ForcepointReport report  <CaseExport> [-o out.html] [--attachments-dir DIR]
      HTML report linking emails to attachments (materialized by original name).

  ForcepointReport folders <CaseExport> [-o DIR] [--keep-all-versions] [--extract-zips]
      Per-email folders named '<agent-time> - from X - to Y' with attachments
      by original filename. --keep-all-versions keeps same-named files whose
      content differs ('name [8-char hash].ext'). --extract-zips unpacks .zip
      attachments into extractions/ using 7-Zip ONLY (skipped if not found).
""");
            return args.Length >= 2 ? 0 : 1;
        }

        string command = args[0];
        string root = Path.GetFullPath(args[1]);
        if (!File.Exists(Path.Combine(root, "UberManifest.json")))
        {
            Console.Error.WriteLine($"error: {root} does not look like a CaseExport (no UberManifest.json)");
            return 2;
        }

        string output = null, attachmentsDir = null;
        bool keepAllVersions = false, extractZips = false;
        for (int i = 2; i < args.Length; i++)
            switch (args[i])
            {
                case "-o" or "--output":
                    output = Path.GetFullPath(args[++i]); break;
                case "--attachments-dir":
                    attachmentsDir = args[++i]; break;   // "" disables materialization
                case "--keep-all-versions":
                    keepAllVersions = true; break;
                case "--extract-zips":
                    extractZips = true; break;
                default:
                    Console.Error.WriteLine($"error: unknown option '{args[i]}'"); return 2;
            }

        return command switch
        {
            "report" => ReportCommand.Run(root, output, attachmentsDir),
            "folders" => FoldersCommand.Run(root, output, keepAllVersions, extractZips),
            _ => Usage(),
        };
    }

    static int Usage()
    {
        Console.Error.WriteLine("error: command must be 'report' or 'folders'");
        return 2;
    }
}
