using Microsoft.Web.WebView2.WinForms;

namespace Timbre;

/// A slim toolbar with Back, Forward, Home and Reload for a web view. (A WebView2 control cannot have
/// anything floating over it, so this sits above the page instead.)
static class NavigationBar
{
    public static ToolStrip Create(WebView2 web, Action home)
    {
        var strip = new ToolStrip
        {
            GripStyle = ToolStripGripStyle.Hidden,
            RenderMode = ToolStripRenderMode.System,
            Padding = new Padding(8, 2, 8, 2),
        };

        // Segoe Fluent Icons / MDL2 glyphs: back, forward, home, refresh.
        ToolStripButton Button(string glyph, string tip, Action action)
        {
            var button = new ToolStripButton(glyph)
            {
                ToolTipText = tip,
                Font = new Font("Segoe MDL2 Assets", 12f),
                DisplayStyle = ToolStripItemDisplayStyle.Text,
                AutoSize = false,
                Size = new Size(38, 30),
            };
            button.Click += (_, _) => action();
            return button;
        }

        var back = Button("", "Back", () => { if (web.CanGoBack) web.GoBack(); });
        var forward = Button("", "Forward", () => { if (web.CanGoForward) web.GoForward(); });
        strip.Items.AddRange(new ToolStripItem[]
        {
            back, forward,
            Button("", "Back to Voice", home),
            Button("", "Reload", () => web.Reload()),
        });

        // Back and Forward dim when there is nowhere to go.
        void Sync() { back.Enabled = web.CanGoBack; forward.Enabled = web.CanGoForward; }
        web.CoreWebView2InitializationCompleted += (_, _) =>
        {
            web.CoreWebView2.HistoryChanged += (_, _) => Sync();
            Sync();
        };
        Sync();
        return strip;
    }
}
