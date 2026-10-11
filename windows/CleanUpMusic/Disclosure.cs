using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CleanUpMusic;

/// A row of a SwiftUI-style `List { DisclosureGroup }`: a group header, or one of its rows when expanded.
/// Each view fills the fields its templates show.
public sealed class Row : INotifyPropertyChanged
{
    public string Key { get; init; } = "";
    public bool IsHeader { get; init; }
    public string Title { get; init; } = "";
    public string Detail { get; init; } = "";
    public string Label { get; init; } = "";
    public string Old { get; init; } = "";
    public string New { get; init; } = "";
    public string Path { get; init; } = "";
    public bool Flag { get; init; }
    /// Changes this row's box ticks: its own, or all of its group's.
    public List<string> Ids { get; init; } = new();

    public Visibility FlagVisibility => Ui.Shown(Flag);

    bool expanded;
    public bool Expanded
    {
        get => expanded;
        set { if (expanded != value) { expanded = value; Notify(); Notify(nameof(Chevron)); } }
    }
    public string Chevron => expanded ? "" : "";
    public string ExpandName => "展開 " + Title;

    bool isChecked;
    public bool IsChecked
    {
        get => isChecked;
        set { if (isChecked != value) { isChecked = value; Notify(); } }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));

    public override bool Equals(object? o) => o is Row r && r.Key == Key && r.IsHeader == IsHeader && r.Title == Title
        && r.Detail == Detail && r.Label == Label && r.Old == Old && r.New == New && r.Path == Path && r.Flag == Flag && r.Ids.SequenceEqual(Ids);
    public override int GetHashCode() => Key.GetHashCode();
    public override string ToString() => IsHeader ? Title : $"{Label} {Old} → {New}";
}

/// Groups shown as a flat, virtualized list; expanding a group inserts its rows after its header.
public sealed class Disclosure
{
    public ObservableCollection<Row> Rows { get; } = new();
    readonly HashSet<string> expanded = new();
    HashSet<string> selected = new();
    List<(Row header, List<Row> rows)> groups = new();

    public void SetGroups(List<(Row header, List<Row> rows)> g)
    {
        groups = g;
        Rebuild();
    }

    public void SetSelected(IEnumerable<string> ids)
    {
        selected = new(ids);
        Refresh();
    }

    public void Toggle(Row header)
    {
        if (!expanded.Remove(header.Key)) expanded.Add(header.Key);
        Rebuild();
    }

    void Rebuild()
    {
        var flat = new List<Row>();
        foreach (var (h, rows) in groups)
        {
            flat.Add(h);
            if (expanded.Contains(h.Key)) flat.AddRange(rows);
        }
        Ui.Sync(Rows, flat, r => r.Key);
        Refresh();
    }

    void Refresh()
    {
        foreach (var r in Rows)
        {
            r.Expanded = expanded.Contains(r.Key);
            r.IsChecked = r.Ids.Count > 0 && r.Ids.All(selected.Contains);
        }
    }
}

public sealed class RowTemplates : DataTemplateSelector
{
    public DataTemplate? Header { get; set; }
    public DataTemplate? Item { get; set; }
    protected override DataTemplate SelectTemplateCore(object item) => ((Row)item).IsHeader ? Header! : Item!;
    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
