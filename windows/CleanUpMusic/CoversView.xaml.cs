using System.Collections.ObjectModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace CleanUpMusic;

public sealed record AlbumRow(CoverItem A)
{
    public string Id => A.Id;
    public string Title => A.Title;
    public string Artist => A.Artist;
    public string Path => Ui.Native(A.Path);
    public Visibility OkVisibility => Ui.Shown(A.State == "ok");
    public Visibility UnreadableVisibility => Ui.Shown(A.State == "unreadable");
    public string UnreadableText => $"有 {A.Unreadable} 張圖但 MinimServer 讀不到";
    public override string ToString() => A.Title;
}

public sealed partial class CoversView : UserControl
{
    readonly ObservableCollection<AlbumRow> rows = new();
    bool updating;
    double? dragStart;
    double startWidth;

    public CoversView()
    {
        InitializeComponent();
        Albums.ItemsSource = rows;
        Core.Watch("status", UpdateStatus);
        Core.Watch("covers", Update);
        Core.Watch("picker", UpdatePicker);
    }

    void UpdateStatus()
    {
        var s = Core.Get<Status>("status");
        ScanButton.IsEnabled = s.Root != null && !s.Scanning;
    }

    void Update()
    {
        var c = Core.Get<Covers>("covers");
        updating = true;
        OnlyMissing.IsChecked = c.OnlyMissing;
        if (Filter.Text != c.Filter) Filter.Text = c.Filter;
        Ui.Sync(rows, c.Items.Select(a => new AlbumRow(a)).ToList(), r => r.Id);
        Albums.SelectedItem = rows.FirstOrDefault(r => r.Id == c.Selection);
        updating = false;
    }

    void UpdatePicker()
    {
        var shown = Core.Get<Picker?>("picker") != null;
        Picker.Visibility = Ui.Shown(shown);
        Placeholder.Visibility = Ui.Shown(!shown);
    }

    void Scan(object sender, RoutedEventArgs e) => Core.Send("scanCovers");

    void OnlyMissingClick(object sender, RoutedEventArgs e) => Core.Send("setOnlyMissing", value: OnlyMissing.IsChecked == true);

    void FilterChanged(object sender, TextChangedEventArgs e)
    {
        if (!updating) Core.Send("setCoverFilter", text: Filter.Text);
    }

    void AlbumSelected(object sender, SelectionChangedEventArgs e)
    {
        // A filtered-out selection stays selected in the core, as in SwiftUI's List.
        if (!updating && Albums.SelectedItem is AlbumRow r) Core.Send("selectAlbum", path: r.Id);
    }

    void SplitterPressed(object sender, PointerRoutedEventArgs e)
    {
        dragStart = e.GetCurrentPoint(this).Position.X;
        startWidth = ListColumn.ActualWidth;
        Splitter.CapturePointer(e.Pointer);
    }

    void SplitterMoved(object sender, PointerRoutedEventArgs e)
    {
        if (dragStart is { } x) ListColumn.Width = new GridLength(Math.Clamp(startWidth + e.GetCurrentPoint(this).Position.X - x, 280, 520));
    }

    void SplitterReleased(object sender, PointerRoutedEventArgs e)
    {
        dragStart = null;
        Splitter.ReleasePointerCapture(e.Pointer);
        ProtectedCursor = null;
    }

    void SplitterEntered(object sender, PointerRoutedEventArgs e) => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);

    void SplitterExited(object sender, PointerRoutedEventArgs e)
    {
        if (dragStart == null) ProtectedCursor = null;
    }
}
