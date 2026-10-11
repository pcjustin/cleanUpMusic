using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CleanUpMusic;

public sealed partial class MojibakeView : UserControl
{
    readonly Disclosure list = new();
    bool scanning, hasRoot;
    int selectedCount;

    public MojibakeView()
    {
        InitializeComponent();
        ToolTipService.SetToolTip(Help, Help.Text);
        List.ItemsSource = list.Rows;
        Core.Watch("status", UpdateStatus);
        Core.Watch("mojibake", Update);
        Core.Watch("mojibakeSelection", UpdateSelection);
    }

    void UpdateStatus()
    {
        var s = Core.Get<Status>("status");
        (scanning, hasRoot) = (s.Scanning, s.Root != null);
        UpdateButtons();
    }

    void Update()
    {
        var g = Core.Get<GroupList>("mojibake");
        list.SetGroups(g.Groups.Select(group => (
            new Row { Key = "g:" + group.Name, IsHeader = true, Title = group.Name, Detail = $"{group.Changes.Count} 個", Ids = group.Changes.Select(c => c.Id).ToList() },
            group.Changes.Select(c => new Row
            {
                Key = c.Id, Label = c.Label, Detail = c.Note, Old = c.Old, New = c.New, Path = Ui.Native(c.Path), Ids = new() { c.Id },
            }).ToList()
        )).ToList());
    }

    void UpdateSelection()
    {
        var s = Core.Get<Selection>("mojibakeSelection");
        selectedCount = s.Count;
        list.SetSelected(s.Ids);
        UpdateButtons();
    }

    void UpdateButtons()
    {
        ScanButton.IsEnabled = hasRoot && !scanning;
        ApplyButton.Content = $"套用勾選 ({selectedCount})";
        ApplyButton.IsEnabled = selectedCount > 0 && !scanning;
    }

    void Scan(object sender, RoutedEventArgs e) => Core.Send("scanMojibake");
    void Apply(object sender, RoutedEventArgs e) => Core.Send("applyMojibake");
    void SelectAll(object sender, RoutedEventArgs e) => Core.Send("selectAllMojibake", value: true);
    void SelectNone(object sender, RoutedEventArgs e) => Core.Send("selectAllMojibake", value: false);
    void Toggle(object sender, RoutedEventArgs e) => list.Toggle((Row)((FrameworkElement)sender).DataContext);

    void Check(object sender, RoutedEventArgs e)
    {
        var box = (CheckBox)sender;
        Core.Send("selectMojibake", value: box.IsChecked == true, ids: ((Row)box.DataContext).Ids);
    }
}
