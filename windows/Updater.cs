using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Timbre;

/// Updates Timbre.exe from the latest GitHub release. Checks on launch and every few hours, asks
/// before installing, verifies the download's SHA-256 when GitHub provides one, then swaps the exe
/// after the app exits and reopens it.
sealed class Updater
{
    static readonly HttpClient Http = CreateClient();
    readonly Form owner;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 6 * 3600 * 1000 };
    bool checking;
    string promptedVersion;

    public Updater(Form owner)
    {
        this.owner = owner;
        timer.Tick += async (_, _) => await CheckAsync(manual: false);
    }

    static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Timbre/{AppInfo.Version.ToString(3)}");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public void Start()
    {
        timer.Start();
        _ = Task.Delay(10_000).ContinueWith(_ => owner.BeginInvoke(new Action(async () => await CheckAsync(manual: false))));
    }

    public async Task CheckAsync(bool manual)
    {
        if (checking) return;
        checking = true;
        try
        {
            using var response = await Http.GetAsync($"https://api.github.com/repos/{AppInfo.Repo}/releases/latest");
            if (!response.IsSuccessStatusCode)
            {
                if (manual) Info("Couldn't check for updates", $"GitHub answered {(int)response.StatusCode}.");
                return;
            }
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var root = doc.RootElement;
            var latest = root.GetProperty("tag_name").GetString()?.TrimStart('v') ?? "0";
            if (!Version.TryParse(latest, out var latestVersion) || Normalize(latestVersion) <= AppInfo.Version)
            {
                if (manual) Info("Timbre is up to date", $"You have version {AppInfo.Version.ToString(3)}.");
                return;
            }

            var wanted = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "Timbre-win-arm64.exe" : "Timbre-win-x64.exe";
            JsonElement? asset = null;
            foreach (var a in root.GetProperty("assets").EnumerateArray())
                if (a.GetProperty("name").GetString() == wanted) asset = a;
            if (asset == null)
            {
                if (manual) Info($"Update {latest} has no Windows download", $"The release has no {wanted}.");
                return;
            }

            if (!manual && promptedVersion == latest) return; // asked once this run; ask again next launch
            promptedVersion = latest;

            var notes = root.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "";
            var ask = MessageBox.Show(owner,
                $"Timbre {latest} is available. You have {AppInfo.Version.ToString(3)}.\n\n{(notes.Length > 400 ? notes[..400] : notes)}\n\nInstall and restart now?",
                "Update available", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (ask != DialogResult.Yes) return;

            string digest = asset.Value.TryGetProperty("digest", out var d) ? d.GetString() : null;
            await InstallAsync(asset.Value.GetProperty("browser_download_url").GetString(), digest, root.GetProperty("html_url").GetString());
        }
        catch (Exception ex)
        {
            if (manual) Info("Couldn't check for updates", ex.Message);
        }
        finally
        {
            checking = false;
        }
    }

    static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(v.Build, 0), Math.Max(v.Revision, 0));

    async Task InstallAsync(string url, string digest, string releasePage)
    {
        var exe = Environment.ProcessPath;
        var dir = Path.GetDirectoryName(exe);
        try
        {
            // The exe's folder must be writable (not Program Files without admin rights).
            var probe = Path.Combine(dir, ".timbre-write-test");
            File.WriteAllText(probe, "");
            File.Delete(probe);
        }
        catch
        {
            Info("Can't update in place", "Timbre isn't in a folder you can write to. Opening the download page instead.");
            MainForm.OpenExternal(releasePage);
            return;
        }

        var download = Path.Combine(dir, "Timbre.update.exe");
        await using (var stream = await Http.GetStreamAsync(url))
        await using (var file = File.Create(download))
            await stream.CopyToAsync(file);

        if (digest != null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            await using var check = File.OpenRead(download);
            var actual = Convert.ToHexString(await SHA256.HashDataAsync(check));
            if (!actual.Equals(digest[7..], StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(download);
                Info("Update failed", "The download didn't match its checksum, so it was discarded.");
                return;
            }
        }

        // A small script waits for this process to exit, swaps the exe, and starts the new one.
        var pid = Environment.ProcessId;
        var script = Path.Combine(Path.GetTempPath(), "timbre-update.cmd");
        File.WriteAllText(script,
            "@echo off\r\n" +
            ":wait\r\n" +
            $"tasklist /fi \"PID eq {pid}\" | find \"{pid}\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
            $"move /y \"{download}\" \"{exe}\" >nul\r\n" +
            $"start \"\" \"{exe}\"\r\n" +
            "del \"%~f0\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"") { CreateNoWindow = true, UseShellExecute = false });
        Application.Exit();
        Environment.Exit(0);
    }

    void Info(string title, string text) =>
        MessageBox.Show(owner, text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
}
