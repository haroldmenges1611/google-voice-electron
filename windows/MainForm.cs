using System.Diagnostics;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace Timbre;

/// The main window: Google Voice in WebView2 (Edge's Chromium), with a menu, a navigation toolbar,
/// a tray icon, notifications, and a single pop-up window for sign-in and calls.
public sealed class MainForm : Form
{
    readonly WebView2 web = new() { Dock = DockStyle.Fill };
    readonly NotifyIcon tray = new();
    readonly MenuStrip menu = new();
    readonly Settings settings = Settings.Load();
    readonly Updater updater;
    ToolStrip nav;
    PopupForm popup;
    ToolStripMenuItem trayModeItem, startupItem;
    bool allowVisible = true;
    bool quitting;
    string pageTitle = "";

    bool TrayMode => settings.Mode == "tray";

    public MainForm()
    {
        updater = new Updater(this);
        Text = AppInfo.Name;
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath);
        MinimumSize = new Size(520, 480);
        StartPosition = FormStartPosition.Manual;
        RestoreSavedBounds();

        // The fill control goes first (front of the z-order) so the docked bars sit above it.
        Controls.Add(web);
        nav = NavigationBar.Create(web, GoHome);
        Controls.Add(nav);
        BuildMenu();
        Controls.Add(menu);
        MainMenuStrip = menu;

        BuildTray();
        ApplyMode();
        Shown += async (_, _) => await InitWebViewAsync();
    }

    // MARK: Window state

    void RestoreSavedBounds()
    {
        var bounds = new Rectangle(settings.X, settings.Y, settings.Width, settings.Height);
        bool onScreen = Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(bounds));
        if (settings.X >= 0 && onScreen) Bounds = bounds; else { Size = bounds.Size; StartPosition = FormStartPosition.CenterScreen; }
        if (settings.Maximized && !TrayMode) WindowState = FormWindowState.Maximized;
    }

    void RememberBounds()
    {
        if (!Visible || WindowState == FormWindowState.Minimized) return;
        settings.Maximized = WindowState == FormWindowState.Maximized;
        if (WindowState == FormWindowState.Normal)
        {
            settings.X = Left; settings.Y = Top; settings.Width = Width; settings.Height = Height;
        }
        settings.Save();
    }

    protected override void SetVisibleCore(bool value) => base.SetVisibleCore(allowVisible && value);

    protected override void OnResizeEnd(EventArgs e) { base.OnResizeEnd(e); RememberBounds(); }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // The X button keeps the app running in the tray, so new messages still arrive.
        if (!quitting && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            RememberBounds();
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!TrayMode || quitting) return;
        // Tray mode behaves like a panel: it hides when you click elsewhere.
        BeginInvoke(new Action(() =>
        {
            if (ActiveForm == null && (popup == null || popup.IsDisposed)) Hide();
        }));
    }

    public void ShowWindow()
    {
        allowVisible = true;
        if (TrayMode) PositionNearTray();
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }

    void PositionNearTray()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(Math.Max(area.Left, area.Right - Width - 12), Math.Max(area.Top, area.Bottom - Height - 12));
    }

    void ApplyMode()
    {
        ShowInTaskbar = !TrayMode;
        if (trayModeItem != null) trayModeItem.Checked = TrayMode;
        if (TrayMode) { allowVisible = false; Hide(); } else ShowWindow();
    }

    void ToggleTrayMode()
    {
        settings.Mode = TrayMode ? "window" : "tray";
        settings.Save();
        ApplyMode();
        if (TrayMode) ShowWindow();
    }

    void Quit()
    {
        quitting = true;
        tray.Visible = false;
        tray.Dispose();
        popup?.Close();
        Application.Exit();
    }

    // MARK: Tray

    void BuildTray()
    {
        tray.Icon = Icon;
        tray.Text = AppInfo.Name;
        tray.Visible = true;
        tray.MouseClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            if (TrayMode && Visible) Hide(); else ShowWindow();
        };
        tray.BalloonTipClicked += (_, _) => ShowWindow();

        var context = new ContextMenuStrip();
        context.Items.Add("Show Timbre", null, (_, _) => ShowWindow());
        context.Items.Add("Voice Home", null, (_, _) => GoHome());
        context.Items.Add(new ToolStripSeparator());
        context.Items.Add("Check for Updates…", null, async (_, _) => await updater.CheckAsync(manual: true));
        context.Items.Add(new ToolStripSeparator());
        context.Items.Add("Quit Timbre", null, (_, _) => Quit());
        tray.ContextMenuStrip = context;
    }

    // MARK: Menu

    static ToolStripMenuItem Item(string text, Action action, Keys shortcut = Keys.None)
    {
        var item = new ToolStripMenuItem(text) { ShortcutKeys = shortcut };
        item.Click += (_, _) => action();
        return item;
    }

    void BuildMenu()
    {
        trayModeItem = Item("Tray Mode", ToggleTrayMode);
        trayModeItem.CheckOnClick = false;
        startupItem = Item("Start with Windows", ToggleStartup);
        startupItem.Checked = IsStartupEnabled();

        var timbre = new ToolStripMenuItem("&Timbre");
        timbre.DropDownItems.AddRange(new ToolStripItem[]
        {
            trayModeItem,
            startupItem,
            new ToolStripSeparator(),
            Item("Sign Out / Switch Account…", () => _ = SignOutAsync()),
            Item("Check for Updates…", () => _ = updater.CheckAsync(manual: true)),
            new ToolStripSeparator(),
            Item("Quit", Quit, Keys.Control | Keys.Q),
        });

        var file = new ToolStripMenuItem("&File");
        file.DropDownItems.AddRange(new ToolStripItem[]
        {
            Item("Close Window", Hide, Keys.Control | Keys.W),
            Item("Open Voice in Browser", () => OpenExternal(AppInfo.Home), Keys.Control | Keys.Shift | Keys.O),
        });

        var edit = new ToolStripMenuItem("&Edit");
        edit.DropDownItems.AddRange(new ToolStripItem[]
        {
            Item("Undo", () => SendToPage("^z")),
            Item("Redo", () => SendToPage("^y")),
            new ToolStripSeparator(),
            Item("Cut", () => SendToPage("^x")),
            Item("Copy", () => SendToPage("^c")),
            Item("Paste", () => SendToPage("^v")),
            Item("Select All", () => SendToPage("^a")),
        });

        var view = new ToolStripMenuItem("&View");
        view.DropDownItems.AddRange(new ToolStripItem[]
        {
            Item("Back", () => { if (web.CanGoBack) web.GoBack(); }, Keys.Alt | Keys.Left),
            Item("Forward", () => { if (web.CanGoForward) web.GoForward(); }, Keys.Alt | Keys.Right),
            Item("Reload", () => web.Reload(), Keys.Control | Keys.R),
            new ToolStripSeparator(),
            Item("Actual Size", () => web.ZoomFactor = 1, Keys.Control | Keys.D0),
            Item("Zoom In", () => web.ZoomFactor = Math.Min(web.ZoomFactor + 0.1, 3), Keys.Control | Keys.Oemplus),
            Item("Zoom Out", () => web.ZoomFactor = Math.Max(web.ZoomFactor - 0.1, 0.5), Keys.Control | Keys.OemMinus),
            new ToolStripSeparator(),
            Item("Full Screen", ToggleFullScreen, Keys.F11),
        });

        var go = new ToolStripMenuItem("&Go");
        go.DropDownItems.Add(Item("Voice Home", GoHome, Keys.Control | Keys.Shift | Keys.H));
        go.DropDownItems.Add(new ToolStripSeparator());
        (string Title, string Path, Keys Key)[] sections =
        {
            ("Calls", "calls", Keys.Control | Keys.D1),
            ("Messages", "messages", Keys.Control | Keys.D2),
            ("Voicemail", "voicemail", Keys.Control | Keys.D3),
            ("Settings", "settings", Keys.Control | Keys.D4),
        };
        foreach (var s in sections)
            go.DropDownItems.Add(Item(s.Title, () => Navigate($"https://voice.google.com/u/0/{s.Path}"), s.Key));

        var help = new ToolStripMenuItem("&Help");
        help.DropDownItems.AddRange(new ToolStripItem[]
        {
            Item("Google Voice Help", () => OpenExternal("https://support.google.com/voice")),
            Item("Timbre on GitHub", () => OpenExternal($"https://github.com/{AppInfo.Repo}")),
            Item("Release Notes", () => OpenExternal($"https://github.com/{AppInfo.Repo}/releases")),
            Item("Report an Issue", () => OpenExternal($"https://github.com/{AppInfo.Repo}/issues/new")),
            new ToolStripSeparator(),
            Item("About Timbre", () => MessageBox.Show(this,
                $"Timbre {AppInfo.Version.ToString(3)}\nUnofficial Google Voice client, not affiliated with Google.\nMIT License, © 2026 Harold Menges.",
                "About Timbre", MessageBoxButtons.OK, MessageBoxIcon.Information)),
        });

        menu.Items.AddRange(new ToolStripItem[] { timbre, file, edit, view, go, help });
    }

    void SendToPage(string keys)
    {
        web.Focus();
        SendKeys.Send(keys);
    }

    void ToggleFullScreen()
    {
        if (FormBorderStyle == FormBorderStyle.None)
        {
            FormBorderStyle = FormBorderStyle.Sizable;
            WindowState = FormWindowState.Normal;
        }
        else
        {
            FormBorderStyle = FormBorderStyle.None;
            WindowState = FormWindowState.Maximized;
        }
    }

    // MARK: Start with Windows

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static bool IsStartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(AppInfo.Name) != null;
    }

    void ToggleStartup()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (key == null) return;
        if (IsStartupEnabled()) key.DeleteValue(AppInfo.Name, throwOnMissingValue: false);
        else key.SetValue(AppInfo.Name, $"\"{Environment.ProcessPath}\"");
        startupItem.Checked = IsStartupEnabled();
    }

    // MARK: WebView

    async Task InitWebViewAsync()
    {
        try
        {
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppInfo.DataDir, "WebView2"));
            await web.EnsureCoreWebView2Async(env);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            if (MessageBox.Show(this, "Timbre needs the Microsoft Edge WebView2 Runtime, which this PC doesn't have.\n\nOpen the download page?",
                    "WebView2 missing", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                OpenExternal("https://go.microsoft.com/fwlink/p/?LinkId=2124703");
            Quit();
            return;
        }

        Hook(web.CoreWebView2);
        web.CoreWebView2.DocumentTitleChanged += (_, _) =>
        {
            pageTitle = web.CoreWebView2.DocumentTitle ?? "";
            Text = string.IsNullOrEmpty(pageTitle) ? AppInfo.Name : $"{pageTitle} – {AppInfo.Name}";
            tray.Text = (pageTitle.Length > 60 ? pageTitle[..60] : pageTitle) is { Length: > 0 } t ? t : AppInfo.Name;
        };
        web.CoreWebView2.Navigate(AppInfo.Home);
        updater.Start();
    }

    /// Wires one web view (the main one or the pop-up) to the app's rules.
    public void Hook(CoreWebView2 core)
    {
        core.Settings.IsStatusBarEnabled = false;
        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindow;
        core.PermissionRequested += OnPermission;
        core.NotificationReceived += OnNotification;
    }

    bool IsMain(object sender) => web.CoreWebView2 != null && ReferenceEquals(sender, web.CoreWebView2);

    void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
    {
        var uri = e.Uri ?? "";
        if (Uri.TryCreate(uri, UriKind.Absolute, out var u))
        {
            // Google's sign-in ends on the Google Account page; go back to Voice instead.
            if (IsMain(sender) && u.Host == "myaccount.google.com" && u.Query.Contains("utm_source=sign_in_no_continue"))
            {
                e.Cancel = true;
                web.CoreWebView2.Navigate(AppInfo.Home);
                return;
            }
            if (u.Scheme is "about" or "data" or "blob" or "edge") return;
        }
        if (!AppInfo.IsAppUri(uri))
        {
            e.Cancel = true;
            OpenExternal(uri);
        }
    }

    void OnNewWindow(object sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        var uri = e.Uri ?? "";
        bool blank = uri.Length == 0 || uri == "about:blank";
        if (!blank && !AppInfo.IsAppUri(uri))
        {
            e.Handled = true;
            OpenExternal(uri);
            return;
        }

        // A link to Voice from another Google page (the app launcher) opens in the main view.
        bool onVoice = web.Source != null && web.Source.Host == "voice.google.com";
        if (!blank && IsMain(sender) && !onVoice && new Uri(uri).Host == "voice.google.com")
        {
            e.Handled = true;
            web.CoreWebView2.Navigate(uri);
            return;
        }

        // Only one pop-up at a time.
        if (popup != null && !popup.IsDisposed)
        {
            if (!blank)
            {
                e.Handled = true;
                popup.Web.CoreWebView2.Navigate(uri);
                popup.Activate();
                return;
            }
            popup.Close(); // a script-driven pop-up needs a fresh window it can talk to
        }

        e.Handled = true;
        _ = OpenPopupAsync(e, e.GetDeferral());
    }

    async Task OpenPopupAsync(CoreWebView2NewWindowRequestedEventArgs e, CoreWebView2Deferral deferral)
    {
        try
        {
            popup = new PopupForm(this);
            await popup.InitAsync(web.CoreWebView2.Environment);
            e.NewWindow = popup.Web.CoreWebView2;
            popup.Show(this);
            popup.Activate();
        }
        finally
        {
            deferral.Complete();
        }
    }

    void OnPermission(object sender, CoreWebView2PermissionRequestedEventArgs e)
    {
        switch (e.PermissionKind)
        {
            case CoreWebView2PermissionKind.Microphone:
                // Only a call needs it, and only while you are using this app. A page holding the
                // microphone in the background would disturb other softphones and audio.
                e.State = ActiveForm != null && AppInfo.IsAppUri(e.Uri)
                    ? CoreWebView2PermissionState.Allow : CoreWebView2PermissionState.Deny;
                break;
            case CoreWebView2PermissionKind.Notifications:
            case CoreWebView2PermissionKind.ClipboardRead:
                e.State = AppInfo.IsAppUri(e.Uri) ? CoreWebView2PermissionState.Allow : CoreWebView2PermissionState.Deny;
                break;
            case CoreWebView2PermissionKind.Camera:
                e.State = CoreWebView2PermissionState.Deny;
                break;
        }
    }

    void OnNotification(object sender, CoreWebView2NotificationReceivedEventArgs e)
    {
        e.Handled = true;
        var n = e.Notification;
        static string Cut(string s, int max) => string.IsNullOrEmpty(s) ? "" : (s.Length > max ? s[..max] : s);
        tray.BalloonTipTitle = Cut(n.Title, 60) is { Length: > 0 } title ? title : AppInfo.Name;
        tray.BalloonTipText = Cut(n.Body, 250) is { Length: > 0 } body ? body : " ";
        tray.BalloonTipIcon = ToolTipIcon.None;
        tray.ShowBalloonTip(6000);
    }

    // MARK: Navigation

    public void GoHome()
    {
        if (popup != null && !popup.IsDisposed) popup.Close();
        Navigate(AppInfo.Home);
    }

    void Navigate(string url)
    {
        web.CoreWebView2?.Navigate(url);
        ShowWindow();
    }

    async Task SignOutAsync()
    {
        if (MessageBox.Show(this, "This clears the saved login in Timbre. You can then sign in with a different account.",
                "Sign out of Google?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        popup?.Close();
        await web.CoreWebView2.Profile.ClearBrowsingDataAsync();
        web.CoreWebView2.Navigate(AppInfo.Home);
    }

    public static void OpenExternal(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https" or "mailto")) return;
        try { Process.Start(new ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true }); } catch { /* no handler */ }
    }
}
