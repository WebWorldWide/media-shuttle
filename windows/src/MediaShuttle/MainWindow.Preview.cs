using MediaShuttle.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

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
    }
#endif
}
