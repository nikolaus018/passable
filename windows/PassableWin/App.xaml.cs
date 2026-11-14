using Microsoft.UI.Xaml;

namespace PassableWin;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Window = new MainWindow();
        Window.Activate();
        // Double-clicking a .passablemix (or "Open with") passes its path on the command line.
        var files = Environment.GetCommandLineArgs().Skip(1)
            .Where(a => a.EndsWith(".passablemix", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
        Window.OpenAtLaunch(files);
    }
}
