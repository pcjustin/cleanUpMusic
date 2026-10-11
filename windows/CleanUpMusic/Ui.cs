using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace CleanUpMusic;

static class Ui
{
    /// Makes `list` equal `items` with the fewest edits, so lists keep their scroll position and expanded rows.
    public static void Sync<T>(ObservableCollection<T> list, IReadOnlyList<T> items, Func<T, string> key)
    {
        var keep = new HashSet<string>(items.Select(key));
        for (int i = list.Count - 1; i >= 0; i--)
            if (!keep.Contains(key(list[i]))) list.RemoveAt(i);
        for (int i = 0; i < items.Count; i++)
        {
            var k = key(items[i]);
            if (i < list.Count && key(list[i]) == k)
            {
                if (!Equals(list[i], items[i])) list[i] = items[i];
                continue;
            }
            int j = i + 1;
            while (j < list.Count && key(list[j]) != k) j++;
            if (j < list.Count)
            {
                list.Move(j, i);
                if (!Equals(list[i], items[i])) list[i] = items[i];
            }
            else list.Insert(i, items[i]);
        }
    }

    /// The core's paths use `/`; show them the Windows way.
    public static string Native(string path) => path.Replace('/', '\\');

    public static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    public static Brush Secondary => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

    public static async Task<BitmapImage?> Load(byte[] data)
    {
        try
        {
            using var stream = new MemoryStream(data);
            var image = new BitmapImage();
            await image.SetSourceAsync(stream.AsRandomAccessStream());
            return image;
        }
        catch { return null; }
    }

    /// Reads off the UI thread: the file may be on a slow NAS.
    public static async Task<BitmapImage?> Load(string path)
    {
        try { return await Load(await File.ReadAllBytesAsync(path)); }
        catch { return null; }
    }
}
