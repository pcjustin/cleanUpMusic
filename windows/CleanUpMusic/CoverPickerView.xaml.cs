using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace CleanUpMusic;

public sealed partial class CoverPickerView : UserControl
{
    bool updating;
    string? currentId, parentKey, unreadableKey, currentKey;

    public CoverPickerView()
    {
        InitializeComponent();
        Core.Watch("status", () => IsEnabled = !Core.Get<Status>("status").Scanning);
        Core.Watch("picker", Update);
        Core.Watch("pickerCurrent", UpdateCurrent);
    }

    void Update()
    {
        if (Core.Get<Picker?>("picker") is not { } p) return;
        updating = true;
        if (p.Id != currentId)
        {
            // A new album: like SwiftUI's .id(album.id), start from a clean pane.
            currentId = p.Id;
            UrlText.Text = "";
            parentKey = unreadableKey = null;
        }
        SplitNote.Visibility = Ui.Shown(p.Split);
        FolderCoversRow.Visibility = Ui.Shown(p.Split && p.FolderCovers.Count > 0);
        FolderCoversText.Text = $"資料夾裡的 {string.Join("、", p.FolderCovers)} 會顯示在這裡所有的單曲上";
        ImageRow(UnreadableSection, UnreadableImages, p.Unreadable, ref unreadableKey, "設為封面", "promote");
        ImageRow(ParentSection, ParentImages, p.ParentImages, ref parentKey, "複製為封面", "copyParent");
        ToFile.IsChecked = p.ToFile;
        ToFile.IsEnabled = !p.Split;
        ToEmbed.IsChecked = p.ToEmbed;
        if (Query.Text != p.Query) Query.Text = p.Query;
        Searching.IsActive = p.Searching;
        Searching.Visibility = Ui.Shown(p.Searching);
        NoResults.Visibility = Ui.Shown(!p.Searching && p.Results.Count == 0);
        if (!(Results.ItemsSource is List<CoverResult> old && old.SequenceEqual(p.Results))) Results.ItemsSource = p.Results;
        updating = false;
    }

    async void UpdateCurrent()
    {
        if (Core.Get<PickerCurrent?>("pickerCurrent") is not { } c) return;
        var key = c.Id + string.Join("|", c.Images.Select(i => i.Name + i.Data.Length));
        if (key == currentKey) return;
        currentKey = key;
        var items = new List<UIElement>();
        foreach (var i in c.Images)
        {
            if (await Ui.Load(i.Data) is not { } image) continue;
            items.Add(Tile(new Image { Source = image, Width = 170, Height = 170 }, i.Name, $"{image.PixelWidth}×{image.PixelHeight}"));
        }
        if (key != currentKey) return;
        CurrentImages.Children.Clear();
        foreach (var t in items) CurrentImages.Children.Add(t);
        CurrentSection.Visibility = Ui.Shown(items.Count > 0);
    }

    static StackPanel Tile(UIElement image, string name, string size)
    {
        var tile = new StackPanel { Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
        tile.Children.Add(image);
        tile.Children.Add(new TextBlock { Text = name, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        tile.Children.Add(new TextBlock { Text = size, FontSize = 10, Foreground = Ui.Secondary, HorizontalAlignment = HorizontalAlignment.Center });
        return tile;
    }

    /// A row of folder images, each with a button that sends `op` for it (SwiftUI's imageRow).
    void ImageRow(StackPanel section, StackPanel row, List<string> paths, ref string? key, string button, string op)
    {
        section.Visibility = Ui.Shown(paths.Count > 0);
        var k = string.Join("|", paths);
        if (k == key) return;
        key = k;
        row.Children.Clear();
        foreach (var path in paths)
        {
            var image = new Image { Width = 170, Height = 170 };
            var size = new TextBlock { FontSize = 10, Foreground = Ui.Secondary, HorizontalAlignment = HorizontalAlignment.Center };
            var ring = new ProgressRing { IsActive = true, Width = 24, Height = 24 };
            var cell = new Grid { Width = 170, Height = 170 };
            cell.Children.Add(ring);
            cell.Children.Add(image);
            var tile = new StackPanel { Width = 180, Spacing = 2 };
            tile.Children.Add(cell);
            tile.Children.Add(size);
            tile.Children.Add(new TextBlock { Text = System.IO.Path.GetFileName(path), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var b = new Button { Content = button, HorizontalAlignment = HorizontalAlignment.Center };
            b.Click += (_, _) => Core.Send(op, path: path);
            tile.Children.Add(b);
            row.Children.Add(tile);
            _ = LoadInto(path, image, ring, size);
        }
    }

    static async Task LoadInto(string path, Image image, ProgressRing ring, TextBlock size)
    {
        var bitmap = await Ui.Load(path);
        ring.IsActive = false;
        ring.Visibility = Visibility.Collapsed;
        if (bitmap == null) return;
        image.Source = bitmap;
        size.Text = $"{bitmap.PixelWidth}×{bitmap.PixelHeight}";
    }

    /// Like AsyncImage, the placeholder goes away once the thumbnail is in.
    void ThumbOpened(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).Parent is Grid g && g.Children[0] is ProgressRing ring) ring.Visibility = Visibility.Collapsed;
    }

    void ResultContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.ItemContainer.ContentTemplateRoot is StackPanel { Children: [Grid g, ..] } && g.Children[0] is ProgressRing ring)
            ring.Visibility = Visibility.Visible;
    }

    void DeleteFolderCovers(object sender, RoutedEventArgs e) => Core.Send("deleteFolderCovers");
    void ToFileClick(object sender, RoutedEventArgs e) => Core.Send("setToFile", value: ToFile.IsChecked == true);
    void ToEmbedClick(object sender, RoutedEventArgs e) => Core.Send("setToEmbed", value: ToEmbed.IsChecked == true);
    void Search(object sender, RoutedEventArgs e) => Core.Send("search");
    void ResultClick(object sender, ItemClickEventArgs e) => Core.Send("saveURL", text: ((CoverResult)e.ClickedItem).Full);
    void UseUrl(object sender, RoutedEventArgs e) => Core.Send("saveURL", text: UrlText.Text);

    void QueryChanged(object sender, TextChangedEventArgs e)
    {
        if (!updating) Core.Send("setQuery", text: Query.Text);
    }

    void QueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter) Core.Send("search");
    }

    async void PickFile(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        foreach (var ext in new[] { ".jpg", ".jpeg", ".png", ".webp" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Window));
        if (await picker.PickSingleFileAsync() is { } file) Core.Send("saveFile", path: file.Path);
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        var d = e.DataView;
        if (d.Contains(StandardDataFormats.StorageItems) || d.Contains(StandardDataFormats.WebLink) || d.Contains(StandardDataFormats.Uri) || d.Contains(StandardDataFormats.Text))
            e.AcceptedOperation = DataPackageOperation.Copy;
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        var d = e.DataView;
        if (d.Contains(StandardDataFormats.StorageItems))
        {
            if ((await d.GetStorageItemsAsync()).FirstOrDefault() is StorageFile f) Core.Send("saveFile", path: f.Path);
        }
        else if (d.Contains(StandardDataFormats.WebLink)) Core.Send("saveURL", text: (await d.GetWebLinkAsync()).AbsoluteUri);
        else if (d.Contains(StandardDataFormats.Uri)) Core.Send("saveURL", text: (await d.GetUriAsync()).AbsoluteUri);
        else if (d.Contains(StandardDataFormats.Text)) Core.Send("saveURL", text: await d.GetTextAsync());
    }
}
