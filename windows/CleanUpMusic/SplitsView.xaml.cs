using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CleanUpMusic;

public sealed partial class SplitsView : UserControl
{
    readonly Disclosure list = new();

    public SplitsView()
    {
        InitializeComponent();
        List.ItemsSource = list.Rows;
        Core.Watch("status", () =>
        {
            var s = Core.Get<Status>("status");
            ScanButton.IsEnabled = s.Root != null && !s.Scanning;
        });
        Core.Watch("splits", Update);
    }

    void Update()
    {
        var splits = Core.Get<List<Split>>("splits");
        list.SetGroups(splits.Select(s => (
            new Row { Key = "g:" + s.Path, IsHeader = true, Title = s.Name, Detail = $"{s.Variants.Count} 種 ALBUM", Flag = s.Similar, Path = Ui.Native(s.Path) },
            s.Variants.Select(v => new Row
            {
                Key = "v:" + s.Path + "\n" + v.Album,
                Title = v.Album.Length == 0 ? "（無 ALBUM）" : $"「{v.Album}」",
                Label = $"  {v.Tracks.Count} 首",
                Detail = string.Join("、", v.Tracks),
            }).ToList()
        )).ToList());
    }

    void Scan(object sender, RoutedEventArgs e) => Core.Send("scanSplits");
    void Toggle(object sender, RoutedEventArgs e) => list.Toggle((Row)((FrameworkElement)sender).DataContext);

    void Reveal(object sender, RoutedEventArgs e)
    {
        var path = ((Row)((FrameworkElement)sender).DataContext).Path;
        Process.Start("explorer.exe", $"/select,\"{path}\"");
    }
}
