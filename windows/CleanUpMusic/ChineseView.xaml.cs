using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CleanUpMusic;

public sealed partial class ChineseView : UserControl
{
    readonly Disclosure list = new();
    bool scanning, hasRoot, updating;
    int selectedCount;

    public ChineseView()
    {
        InitializeComponent();
        List.ItemsSource = list.Rows;
        Core.Watch("status", UpdateStatus);
        Core.Watch("chinese", Update);
        Core.Watch("chineseSelection", UpdateSelection);
    }

    void UpdateStatus()
    {
        var s = Core.Get<Status>("status");
        (scanning, hasRoot) = (s.Scanning, s.Root != null);
        UpdateButtons();
    }

    void Update()
    {
        var g = Core.Get<GroupList>("chinese");
        updating = true;
        if (Filter.Text != g.Filter) Filter.Text = g.Filter;
        updating = false;
        GroupCount.Text = $"{g.Groups.Count} 張專輯";
        list.SetGroups(g.Groups.Select(group => (
            new Row { Key = "g:" + group.Name, IsHeader = true, Title = group.Name, Detail = group.Summary, Ids = group.Changes.Select(c => c.Id).ToList() },
            group.Changes.Select(c => new Row { Key = c.Id, Label = c.Label, Old = c.Old, New = c.New, Path = Ui.Native(c.Path), Ids = new() { c.Id } }).ToList()
        )).ToList());
    }

    void UpdateSelection()
    {
        var s = Core.Get<Selection>("chineseSelection");
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

    void Scan(object sender, RoutedEventArgs e) => Core.Send("scanChinese");
    void Apply(object sender, RoutedEventArgs e) => Core.Send("applyChanges");
    void SelectAll(object sender, RoutedEventArgs e) => Core.Send("selectShownChanges", value: true);
    void SelectNone(object sender, RoutedEventArgs e) => Core.Send("selectShownChanges", value: false);
    void Toggle(object sender, RoutedEventArgs e) => list.Toggle((Row)((FrameworkElement)sender).DataContext);

    void Check(object sender, RoutedEventArgs e)
    {
        var box = (CheckBox)sender;
        Core.Send("selectChanges", value: box.IsChecked == true, ids: ((Row)box.DataContext).Ids);
    }

    void FilterChanged(object sender, TextChangedEventArgs e)
    {
        if (!updating) Core.Send("setChineseFilter", text: Filter.Text);
    }
}
