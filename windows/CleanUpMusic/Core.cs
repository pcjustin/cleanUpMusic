using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Dispatching;

namespace CleanUpMusic;

/// The shared Swift core (CleanUpMusicBridge.dll): models and controllers live there, this app only draws them.
/// Each window section is a JSON document the core pushes when it changes; user actions go back as commands.
public static unsafe class Core
{
    const string Dll = "CleanUpMusicBridge.dll";

    [DllImport(Dll)] static extern void cum_start(delegate* unmanaged<IntPtr, void> post, delegate* unmanaged<IntPtr, void> changed, byte* dataDir);
    [DllImport(Dll)] static extern void cum_run(IntPtr job);
    [DllImport(Dll)] static extern IntPtr cum_get(byte* section);
    [DllImport(Dll)] static extern void cum_free(IntPtr p);
    [DllImport(Dll)] static extern void cum_send(byte* json);

    static DispatcherQueue? queue;
    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    static readonly Dictionary<string, List<Action>> handlers = new();

    /// Calls `action` on the UI thread whenever the section changes, and once now.
    public static void Watch(string section, Action action)
    {
        if (!handlers.TryGetValue(section, out var list)) handlers[section] = list = new();
        list.Add(action);
        if (queue != null) action();
    }

    public static void Start(DispatcherQueue q, string dataDir)
    {
        queue = q;
        fixed (byte* d = Utf8(dataDir)) cum_start(&Post, &Changed, d);
    }

    public static T Get<T>(string section)
    {
        IntPtr p;
        fixed (byte* s = Utf8(section)) p = cum_get(s);
        if (p == IntPtr.Zero) return default!;
        try { return JsonSerializer.Deserialize<T>(Marshal.PtrToStringUTF8(p)!, Json)!; }
        finally { cum_free(p); }
    }

    /// Sends a command, e.g. `Send("scanCovers")` or `Send("setOnlyMissing", value: true)`.
    public static void Send(string op, bool? value = null, string? text = null, string? path = null, IEnumerable<string>? ids = null)
    {
        var json = JsonSerializer.Serialize(new Command(op, value, text, path, ids), Json);
        fixed (byte* j = Utf8(json)) cum_send(j);
    }

    record Command(string Op, bool? Value, string? Text, string? Path, IEnumerable<string>? Ids);

    static byte[] Utf8(string s) => System.Text.Encoding.UTF8.GetBytes(s + "\0");

    [UnmanagedCallersOnly]
    static void Post(IntPtr job) => queue!.TryEnqueue(() => cum_run(job));

    [UnmanagedCallersOnly]
    static void Changed(IntPtr section)
    {
        var name = Marshal.PtrToStringUTF8(section)!;
        // Handlers may send commands, which must not run inside the core's change notification.
        queue!.TryEnqueue(() =>
        {
            if (handlers.TryGetValue(name, out var list)) foreach (var a in list) a();
        });
    }
}

// Section documents (see Sources/CleanUpMusicBridge/Bridge.swift).

public record Status(string? Root, bool Scanning, int Progress, string? Message, int Albums, int Changes, int Splits, int Discs);

public record CoverItem(string Id, string Title, string Artist, string Path, string State, int Unreadable);
public record Covers(bool OnlyMissing, string Filter, string? Selection, List<CoverItem> Items);

public record CoverResult(string Full, string Thumb, string Title, string Source)
{
    public override string ToString() => Title;
}
public record Picker(string Id, bool Split, string Query, bool Searching, bool ToFile, bool ToEmbed,
    List<string> FolderCovers, List<string> Unreadable, List<string> ParentImages, List<CoverResult> Results);
public record CurrentImage(string Name, byte[] Data);
public record PickerCurrent(string Id, List<CurrentImage> Images);

public record ChangeItem(string Id, string Label, string Old, string New, string Path, string Folder, string File);
public record ChangeGroup(string Name, string Summary, int Tracks, List<ChangeItem> Changes);
public record GroupList(List<ChangeGroup> Groups, string Filter);
public record Selection(List<string> Ids, int Count);

public record SplitVariant(string Album, List<string> Tracks);
public record Split(string Name, string Path, bool Similar, List<SplitVariant> Variants);
