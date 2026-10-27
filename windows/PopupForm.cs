using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Timbre;

/// The single extra window for Google sign-in, payments and the call window.
sealed class PopupForm : Form
{
    public WebView2 Web { get; } = new() { Dock = DockStyle.Fill };
    readonly MainForm main;

    public PopupForm(MainForm main)
    {
        this.main = main;
        Text = AppInfo.Name;
        Icon = main.Icon;
        Size = new Size(1000, 720);
        StartPosition = FormStartPosition.CenterParent;
        ShowInTaskbar = false;
        Controls.Add(Web);
        Controls.Add(NavigationBar.Create(Web, main.GoHome));
    }

    public async Task InitAsync(CoreWebView2Environment env)
    {
        await Web.EnsureCoreWebView2Async(env);
        main.Hook(Web.CoreWebView2);
        Web.CoreWebView2.DocumentTitleChanged += (_, _) =>
        {
            var title = Web.CoreWebView2.DocumentTitle;
            Text = string.IsNullOrEmpty(title) ? AppInfo.Name : title;
        };
        Web.CoreWebView2.WindowCloseRequested += (_, _) => Close();
    }
}
