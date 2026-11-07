using System.Runtime.InteropServices.WindowsRuntime;
using MediaShuttle.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace MediaShuttle;

public sealed partial class MainWindow
{
    internal void ShowVisualPreview() => _appWindow.Show(activateWindow: false);

    internal static bool IsVisualPreview
    {
        get
        {
#if DEBUG
            return Environment.GetCommandLineArgs().Contains("--screenshot", StringComparer.OrdinalIgnoreCase);
#else
            return false;
#endif
        }
    }

#if DEBUG
    // A separate instance and temporary state directory let UI QA run beside the installed app.
    // No watcher, transfer or erase runs in this mode; the sample reproduces the macOS reference.
    private void ConfigureVisualPreview()
    {
        ApplyTheme("Dark");
        _currentCard = new CardInfo("F:\\", "LEXAR", 0, 64_000_000_000, 53_900_000_000, "Removable");
        var media = Enumerable.Range(0, 418).Select(index =>
            new MediaItem($"F:\\DCIM\\100MSDCF\\DSC{index:00000}.JPG", $"DSC{index:00000}.JPG", ".jpg", 22_000_000, DateTime.UtcNow, MediaKind.Jpeg))
            .Concat(Enumerable.Range(0, 39).Select(index =>
                new MediaItem($"F:\\DCIM\\100MSDCF\\DSC{index:00000}.ARW", $"DSC{index:00000}.ARW", ".arw", 24_000_000, DateTime.UtcNow, MediaKind.Raw))).ToArray();
        _verifiedSession = new TransferSession
        {
            Status = "Verified", SourceRoot = "F:\\", SourceLabel = "LEXAR", DestinationRoot = _destinationRoot,
            StartedUtc = DateTimeOffset.UtcNow.AddSeconds(-128), CompletedUtc = DateTimeOffset.UtcNow,
            TotalFiles = 457, TotalBytes = 10_100_000_000, CopiedCount = 442, SkippedCount = 15,
            Files = [new TransferRecord { SourcePath = "F:\\DCIM\\100MSDCF\\DSC00381.JPG",
                DestinationPath = Path.Combine(_destinationRoot, "Photos", "JPEGs", "DSC00381.JPG"), Size = 22_000_000 }]
        };
        _lastScannedMediaCount = 457;
        UpdateCardContents(media);
        UpdateVerifiedState(_currentCard, _verifiedSession);
        CardStatsText.Text = "457 assets · 10.13 GB";
        CardDetailText.Text = "/Volumes/LEXAR · Removable media";
        DestinationText.Text = "~/Desktop/Camera";
        CurrentFileText.Text = "LAST · /Volumes/LEXAR/DCIM/100MSDCF/DSC00381.JPG → Photos/JPEGs";
        WipeDescriptionText.Text = "Every file on /Volumes/LEXAR has a verified copy. You'll be asked to confirm.";
        ThroughputText.Text = "78.7";
        CopiedCaption.Text = "files";
        SkippedCaption.Text = "re-verified";
        SelectThemeButton("Dark");
        _settingsReady = true;
        _activity.Clear();
        _activity.Add("3:38:24 PM  Verified 457 files: 442 copied, 15 already at the destination.");
        _activity.Add("3:36:25 PM  Transfer started from /Volumes/LEXAR.");
        ShowMessage("Transfer verified", "457 files copied and checked with SHA-256.", InfoBarSeverity.Success);
        ReportButton.IsEnabled = false;
        ActivityToggle.IsOn = true;
        _settings.ShowActivityLog = true;
        _settings.Theme = "Dark";
        _settingsReady = true;
        UpdateResponsiveLayout();
        ScheduleActivityListHeightUpdate();
        if (PreviewOutputDirectory is { } directory)
        {
            DispatcherQueue.TryEnqueue(async () => await RenderPreviewAsync(directory));
        }
    }

    /// <summary>
    /// <c>--screenshot --render-preview DIR</c> saves the window, Settings and the erase dialog as
    /// PNGs in both themes, then quits. CI runs it so the controls can be checked without a PC.
    /// </summary>
    private static string? PreviewOutputDirectory
    {
        get
        {
            string[] arguments = Environment.GetCommandLineArgs();
            int index = Array.FindIndex(arguments, argument => argument.Equals("--render-preview", StringComparison.OrdinalIgnoreCase));
            return index >= 0 && index + 1 < arguments.Length ? arguments[index + 1] : null;
        }
    }

    private async Task RenderPreviewAsync(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            AutoTransferToggle.IsOn = true;
            GroupByDateToggle.IsOn = false;
            NotificationsToggle.IsOn = true;
            foreach (string theme in new[] { "Dark", "Light" })
            {
                ApplyTheme(theme);
                SelectThemeButton(theme);
                await Task.Delay(1200);
                await SaveElementAsync(Root, Path.Combine(directory, $"window-{theme.ToLowerInvariant()}.png"));

                var settings = (Flyout)SettingsButton.Flyout;
                settings.ShowAt(SettingsButton);
                await Task.Delay(900);
                await SaveElementAsync((UIElement)settings.Content, Path.Combine(directory, $"settings-{theme.ToLowerInvariant()}.png"));
                settings.Hide();
                await Task.Delay(400);

                ContentDialog dialog = CreateEraseConfirmationDialog(_currentCard!);
                _ = dialog.ShowAsync();
                await Task.Delay(900);
                if (dialog.Content is StackPanel content)
                {
                    foreach (UIElement child in content.Children)
                    {
                        if (child is TextBox phrase) phrase.Text = "ERASE EVERYTHING";
                        if (child is CheckBox acknowledge) acknowledge.IsChecked = true;
                    }
                }
                await Task.Delay(500);
                // The dialog's popup also holds the dimmed backdrop; render only the dialog panel.
                if (FindVisualChild<Border>(dialog, "BackgroundElement") is Border panel)
                {
                    await SaveElementAsync(panel, Path.Combine(directory, $"erase-{theme.ToLowerInvariant()}.png"));
                }
                dialog.Hide();
                await Task.Delay(400);
            }
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(Path.Combine(directory, "render-error.txt"), exception.ToString());
        }
        finally
        {
            _allowClose = true;
            Application.Current.Exit();
        }
    }

    private static T? FindVisualChild<T>(DependencyObject parent, string name) where T : FrameworkElement
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is T element && element.Name == name) return element;
            if (FindVisualChild<T>(child, name) is T descendant) return descendant;
        }
        return null;
    }

    private static async Task SaveElementAsync(UIElement element, string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(element);
        IBuffer pixels = await bitmap.GetPixelsAsync();
        using var stream = new InMemoryRandomAccessStream();
        BitmapEncoder encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray());
        await encoder.FlushAsync();
        stream.Seek(0);
        await using FileStream file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
    }
#endif
}
