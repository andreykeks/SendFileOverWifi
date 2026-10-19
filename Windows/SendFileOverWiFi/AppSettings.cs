using System.Text.Json;

namespace SendFileOverWiFi;

public sealed class AppSettings
{
    public string DisplayName { get; set; } = Environment.MachineName;
    public string Theme { get; set; } = "system";
    public string Language { get; set; } = "";
    public string ReceiveDirectory { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    public bool PreserveDates { get; set; } = false;
    public Dictionary<string, string> TrustedDevices { get; set; } = [];
    public PendingOutgoingTransfer? PendingOutgoing { get; set; }

    private static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SendFile over WiFi");
    private static string FilePath => Path.Combine(DirectoryPath, "settings.json");

    public static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings(); }
        catch { return new AppSettings(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
