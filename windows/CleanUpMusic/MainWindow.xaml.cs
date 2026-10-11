using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace CleanUpMusic;

public sealed partial class MainWindow : Window
{
    readonly List<(Button button, UIElement view)> tabs = new();
    int selectedTab;
    bool showingMessage;

    public MainWindow()
    {
        InitializeComponent();
        // AppWindow sizes are in pixels; SwiftUI's frame(minWidth: 1000, minHeight: 650) is in points.
        // Small or highly scaled screens get no more than their work area.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        int Fit(double points, int available) => Math.Min((int)(points * scale), available);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(Fit(1200, area.Width), Fit(800, area.Height)));
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + (area.Height - AppWindow.Size.Height) / 2));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "AppIcon.ico"));
        if (AppWindow.Presenter is OverlappedPresenter p)
            (p.PreferredMinimumWidth, p.PreferredMinimumHeight) = (Fit(1000, area.Width), Fit(650, area.Height));

        foreach (var view in new UIElement[] { Covers, Chinese, Splits, Discs })
        {
            var button = new Button { Padding = new Thickness(12, 3, 12, 3), MinWidth = 0, BorderThickness = new Thickness(0) };
            int index = tabs.Count;
            button.Click += (_, _) => SelectTab(index);
            tabs.Add((button, view));
            Tabs.Children.Add(button);
        }
        SelectTab(0);
        Core.Watch("status", Update);
    }

    void SelectTab(int index)
    {
        selectedTab = index;
        for (int i = 0; i < tabs.Count; i++)
        {
            var (button, view) = tabs[i];
            view.Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
            // The selected segment is raised, as in macOS's TabView.
            button.Background = i == index
                ? (Brush)Application.Current.Resources["ControlSolidFillColorDefaultBrush"]
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            button.BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"];
            button.BorderThickness = new Thickness(i == index ? 1 : 0);
        }
    }

    void Update()
    {
        var s = Core.Get<Status>("status");
        PickButton.IsEnabled = !s.Scanning;
        RootText.Text = s.Root is { } root ? Ui.Native(root) : "未選擇";
        Busy.Visibility = s.Scanning ? Visibility.Visible : Visibility.Collapsed;
        ProgressText.Text = $"處理中… {s.Progress}";
        string[] titles = { $"封面 ({s.Albums})", $"簡轉繁 ({s.Changes})", $"專輯分裂 ({s.Splits})", $"CD 編號 ({s.Discs})" };
        for (int i = 0; i < tabs.Count; i++) tabs[i].button.Content = titles[i];
        if (s.Message != null && !showingMessage) ShowMessage(s.Message);
    }

    async void ShowMessage(string message)
    {
        showingMessage = true;
        var dialog = new ContentDialog
        {
            Title = "訊息",
            Content = new ScrollViewer { Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } },
            CloseButtonText = "OK",
            XamlRoot = Root.XamlRoot,
        };
        await dialog.ShowAsync();
        showingMessage = false;
        Core.Send("dismissMessage");
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr hwnd);

    async void Pick(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) Core.Send("choose", path: folder.Path);
    }
}
