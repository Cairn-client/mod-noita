// Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: MIT OR Apache-2.0 (as the project it is part of)
//
// The Cairn launcher's program for Noita (the pack's `optionsProgram`, docs: the launcher repository's docs/PACKS.md and BRIDGE.md).
// The launcher runs it with a list of arguments and reads one JSON object per line from its standard output:
//
//   saves list                          one {"t":"saves","slots":[...]}: the runs Noita has kept
//   saves delete <id>                   {"t":"toast",...} then the new list; refused while Noita runs
//   saves delete-all                    {"t":"toast",...}: every run (the unlocks in save_shared stay)
//   logs collect --out DIR [--game-exe] copies Noita's own log into DIR
//
// Noita keeps its data in %USERPROFILE%\AppData\LocalLow\Nolla_Games_Noita: save00 is the run being played, save01 the one the game
// is preparing, save_shared what the player has unlocked (kept: deleting it takes the perks and spells away for good).
using System.Diagnostics;
using System.Globalization;
using System.Text;

return Bridge.Run(args);

static class Bridge
{
    static readonly string DataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "LocalLow", "Nolla_Games_Noita");

    // id -> what the player sees
    static readonly (string Id, string Name)[] Runs =
    {
        ("save00", "Current run"),
        ("save01", "Next run"),
    };

    public static int Run(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            return args switch
            {
                ["saves", "list"] => List(),
                ["saves", "delete", var id] => Delete(id),
                ["saves", "delete-all"] => DeleteAll(),
                ["logs", "collect", ..] => Logs(args),
                _ => 2,
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Toast("Noita's saves could not be changed: " + ex.Message, true);
            return 1;
        }
    }

    static int List()
    {
        Console.WriteLine(SavesLine());
        return 0;
    }

    static int Delete(string id)
    {
        var run = Runs.FirstOrDefault(r => r.Id == id);
        if (run.Id is null) { Toast("That save is not there any more.", true); return 1; }
        if (Running()) { Toast("Close Noita first: it keeps its save open while it runs.", true); return 1; }
        string dir = Path.Combine(DataDir, id);
        if (!Directory.Exists(dir)) { Toast("That save is not there any more.", true); Console.WriteLine(SavesLine()); return 1; }
        Directory.Delete(dir, recursive: true);
        Toast($"Deleted {run.Name.ToLowerInvariant()}.", false);
        Console.WriteLine(SavesLine());
        return 0;
    }

    static int DeleteAll()
    {
        if (Running()) { Toast("Close Noita first: it keeps its save open while it runs.", true); return 1; }
        int n = 0;
        foreach (var (id, _) in Runs)
        {
            string dir = Path.Combine(DataDir, id);
            if (Directory.Exists(dir)) { Directory.Delete(dir, recursive: true); n++; }
        }
        Toast(n == 0 ? "There was nothing to delete." : "Deleted every run. What you unlocked is kept.", false);
        return 0;
    }

    static int Logs(string[] args)
    {
        int at = Array.IndexOf(args, "--out");
        if (at < 0 || at + 1 >= args.Length) return 2;
        string outDir = args[at + 1];
        Directory.CreateDirectory(outDir);
        foreach (var name in new[] { "logs.txt", "stderr.txt" })
        {
            string src = Path.Combine(DataDir, name);
            if (File.Exists(src)) File.Copy(src, Path.Combine(outDir, "noita-" + name), overwrite: true);
        }
        return 0;
    }

    static bool Running()
    {
        foreach (var p in Process.GetProcessesByName("noita")) { p.Dispose(); return true; }
        return false;
    }

    static string SavesLine()
    {
        var sb = new StringBuilder("{\"t\":\"saves\",\"slots\":[");
        bool first = true;
        foreach (var (id, name) in Runs)
        {
            string dir = Path.Combine(DataDir, id);
            if (!Directory.Exists(dir)) continue;
            var files = new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories).ToList();
            long bytes = files.Sum(f => f.Length);
            DateTime when = files.Count == 0 ? Directory.GetLastWriteTimeUtc(dir) : files.Max(f => f.LastWriteTimeUtc);
            if (!first) sb.Append(',');
            first = false;
            sb.Append("{\"id\":").Append(Q(id)).Append(",\"name\":").Append(Q(name))
              .Append(",\"detail\":").Append(Q(Size(bytes))).Append(",\"kind\":\"world\",\"when\":")
              .Append(Q(when.ToString("o", CultureInfo.InvariantCulture))).Append('}');
        }
        return sb.Append("]}").ToString();
    }

    static string Size(long bytes) => bytes >= 1 << 20 ? $"{bytes / (double)(1 << 20):0.#} MB" : $"{Math.Max(1, bytes / 1024)} KB";

    static void Toast(string text, bool error) =>
        Console.WriteLine("{\"t\":\"toast\",\"text\":" + Q(text) + ",\"error\":" + (error ? "true" : "false") + "}");

    // a JSON string, written by hand: nothing here needs a serializer (and a native program stays small without one)
    static string Q(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case < ' ': sb.Append("\\u").Append(((int)c).ToString("x4")); break;
                default: sb.Append(c); break;
            }
        }
        return sb.Append('"').ToString();
    }
}
