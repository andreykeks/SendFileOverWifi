namespace SendFileOverWiFi;

/// <summary>Local diagnostics. Never records tokens, SAS codes, keys, contents or full file paths.</summary>
internal static class DebugLog
{
    private static readonly string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SendFile over WiFi", "debug.log");

    internal static void Error(string area, Exception error)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // Exception.Message and stack traces may contain file paths, request headers,
            // or implementation details. The common logging policy excludes all of them.
            File.AppendAllText(path, $"{DateTimeOffset.Now:O} [{area}] {error.GetType().Name}; HRESULT=0x{error.HResult:X8}\n");
        }
        catch { }
    }
}
