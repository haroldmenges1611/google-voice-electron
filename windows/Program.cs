namespace Timbre;

static class Program
{
    [STAThread]
    static void Main()
    {
        // One copy at a time: a second launch just brings the first one forward.
        using var mutex = new Mutex(true, "Local\\Timbre.SingleInstance", out bool first);
        var show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\Timbre.Show");
        if (!first)
        {
            show.Set();
            return;
        }

        ApplicationConfiguration.Initialize();
        var form = new MainForm();
        var listener = new Thread(() =>
        {
            while (show.WaitOne())
            {
                try { form.BeginInvoke(new Action(form.ShowWindow)); } catch (ObjectDisposedException) { return; }
            }
        }) { IsBackground = true };
        listener.Start();
        Application.Run(form);
    }
}
