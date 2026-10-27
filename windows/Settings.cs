using System.Text.Json;

namespace Timbre;

static class AppInfo
{
    public const string Name = "Timbre";
    public const string Home = "https://voice.google.com/";
    public const string Repo = "haroldmenges1611/timbre";
    public static string DataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Name);
    public static Version Version
    {
        get
        {
            var v = typeof(AppInfo).Assembly.GetName().Version ?? new Version(0, 0, 0, 0);
            return new Version(v.Major, v.Minor, Math.Max(v.Build, 0), Math.Max(v.Revision, 0));
        }
    }

    public static bool IsGoogleHost(string host) => host == "google.com" || host.EndsWith(".google.com");

    /// True for the Google pages the app is allowed to show itself (https only).
    public static bool IsAppUri(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var u) && u.Scheme == "https" && IsGoogleHost(u.Host);
}

/// Small settings file in %LocalAppData%\Timbre.
sealed class Settings
{
    public string Mode { get; set; } = "window"; // "window" or "tray"
    public int X { get; set; } = -1;
    public int Y { get; set; } = -1;
    public int Width { get; set; } = 1100;
    public int Height { get; set; } = 760;
    public bool Maximized { get; set; }

    static string FilePath => Path.Combine(AppInfo.DataDir, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
        catch { return new Settings(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(AppInfo.DataDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
        }
        catch { /* settings are a convenience */ }
    }
}
