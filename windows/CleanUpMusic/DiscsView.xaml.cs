using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CleanUpMusic;

public sealed partial class DiscsView : UserControl
{
    readonly Disclosure list = new();
    bool scanning, hasRoot;
    int selectedAlbums;

    public DiscsView()
    {
        InitializeComponent();
        ToolTipService.SetToolTip(Help, Help.Text);
        List.ItemsSource = list.Rows;
        Core.Watch("status", UpdateStatus);
        Core.Watch("discs", Update);
        Core.Watch("discsSelection", UpdateSelection);
    }

    void UpdateStatus()
    {
        var s = Core.Get<Status>("status");
        (scanning, hasRoot) = (s.Scanning, s.Root != null);
        UpdateButtons();
    }

    void Update()
    {
        var g = Core.Get<GroupList>("discs");
        list.SetGroups(g.Groups.Select(group => (
            new Row { Key = "g:" + group.Name, IsHeader = true, Title = group.Name, Detail = $"{group.Tracks} 首", Ids = group.Changes.Select(c => c.Id).ToList() },
            group.Changes.Select(c => new Row
            {
                Key = c.Id, Label = c.Label, Title = c.Folder + "/" + c.File, Old = c.Old.Length == 0 ? "（無）" : c.Old, New = c.New, Path = Ui.Native(c.Path),
            }).ToList()
        )).ToList());
    }

    void UpdateSelection()
    {
        var s = Core.Get<Selection>("discsSelection");
        selectedAlbums = s.Count;
        list.SetSelected(s.Ids);
        UpdateButtons();
    }

    void UpdateButtons()
    {
        ScanButton.IsEnabled = hasRoot && !scanning;
        ApplyButton.Content = $"套用勾選 ({selectedAlbums} 張專輯)";
        ApplyButton.IsEnabled = selectedAlbums > 0 && !scanning;
    }

    void Scan(object sender, RoutedEventArgs e) => Core.Send("scanDiscs");
    void Apply(object sender, RoutedEventArgs e) => Core.Send("applyDiscs");
    void SelectAll(object sender, RoutedEventArgs e) => Core.Send("selectAllDiscs", value: true);
    void SelectNone(object sender, RoutedEventArgs e) => Core.Send("selectAllDiscs", value: false);
    void Toggle(object sender, RoutedEventArgs e) => list.Toggle((Row)((FrameworkElement)sender).DataContext);

    void Check(object sender, RoutedEventArgs e)
    {
        var box = (CheckBox)sender;
        Core.Send("selectDiscs", value: box.IsChecked == true, ids: ((Row)box.DataContext).Ids);
    }
}
