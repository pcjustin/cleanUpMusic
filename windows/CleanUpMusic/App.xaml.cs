using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace CleanUpMusic;

public partial class App : Application
{
    public static Window Window { get; private set; } = null!;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Core.Start(DispatcherQueue.GetForCurrentThread(), Path.Combine(AppContext.BaseDirectory, "opencc"));
        // A folder given on the command line (or dropped on the exe) is chosen as if picked.
        if (Environment.GetCommandLineArgs() is [_, var folder, ..] && Directory.Exists(folder)) Core.Send("choose", path: folder);
        Window = new MainWindow();
        Window.Activate();
    }
}
