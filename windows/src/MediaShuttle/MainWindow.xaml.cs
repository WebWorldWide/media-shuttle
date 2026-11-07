using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using MediaShuttle.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Rectangle = Microsoft.UI.Xaml.Shapes.Rectangle;
using WinRT.Interop;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.UI;

namespace MediaShuttle;

public sealed partial class MainWindow : Window
{
    private const double ScanPulseWidthPercent = 16;
    private const double MinimumActivityHeight = 108;
    private const double MaximumActivityHeight = 460;
    private const double MinimumActivityRowHeight = 129;
    private const double SidebarWidth = 280;
    private const double ColumnGap = 1;
    private const double PanelPadding = 20;
    // Stacking the sidebar above the operations column costs it its shape: a panel designed for a
    // 240px column, drawn 700px wide, is mostly gaps. Two columns hold down to the point where the
    // operations side would be narrower than the sidebar itself.
    private const double NarrowLayoutWidth = 760;
    private const double StackedActionWidth = 650;
    private const int MaximumActivityLines = 200;

    /// <summary>
    /// A copy reports progress after every megabyte, which on a fast reader is hundreds of times a
    /// second. Redrawing the readouts that often costs more time than it reports on, so identical
    /// phases are coalesced to a rate a person can actually read.
    /// </summary>
    private static readonly TimeSpan ProgressRedrawInterval = TimeSpan.FromMilliseconds(66);

    private static readonly SolidColorBrush NeutralStatusBrush = new(Color.FromArgb(255, 124, 124, 124));
    private static readonly SolidColorBrush ActiveStatusBrush = new(Color.FromArgb(255, 255, 77, 68));
    private static readonly SolidColorBrush VerifiedStatusBrush = new(Color.FromArgb(255, 95, 208, 138));
    private static readonly SolidColorBrush WarningStatusBrush = new(Color.FromArgb(255, 202, 139, 39));
    private static readonly SolidColorBrush ErrorStatusBrush = new(Color.FromArgb(255, 196, 43, 43));

    private readonly bool _launchInBackground;
    private string _destinationRoot;
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;
    private readonly TransferService _transferService;
    private readonly WipeService _wipeService;
    private readonly ObservableCollection<string> _activity = [];
    private readonly List<Rectangle> _progressSegments = [];
    private CardPresenceTracker _cardPresence = new();
    private string? _selectedSourceRoot;
    private bool _sourceAllowsErase = true;
    private int _sourceVersion;
    private readonly DispatcherQueueTimer _scanTimer;
    private readonly DispatcherQueueTimer _scanPulseTimer;
    private double _scanPulsePosition;
    private int _scanPulseDirection = 1;
    private readonly TrayIconService _trayIcon;
    private readonly AppWindow _appWindow;
    private AppSettings _settings = new();
    private CardInfo? _currentCard;
    private TransferSession? _verifiedSession;
    private CancellationTokenSource? _operationCancellation;
    private DateTimeOffset? _operationStartedUtc;
    private DateTimeOffset? _operationEndedUtc;
    private double _appliedLayoutWidth;
    private DateTimeOffset _lastProgressRedraw;
    private OperationPhase _lastProgressPhase = OperationPhase.Idle;
    private string _lastProgressItem = string.Empty;
    private string? _lastSessionFilePath;
    private bool _settingsReady;
    private bool _scanInProgress;
    private bool _busy;
    private bool _destinationAvailable = true;
    private bool _currentCardEjectable;
    private int _lastScannedMediaCount = -1;
    private int _unverifiableFileCount;
    private string? _lastScanSignature;
    private bool _allowClose;
    private bool _initialActivationHandled;
    private bool _placementPending;
    private readonly IntPtr _windowHandle;

    public MainWindow(bool launchInBackground)
    {
        _launchInBackground = launchInBackground;
        _destinationRoot = DefaultDestinationRoot();
        string stateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Media Shuttle");
        if (IsVisualPreview) stateRoot = Path.Combine(Path.GetTempPath(), "MediaShuttle-VisualPreview");
        _stateStore = new StateStore(stateRoot);
        _logger = new AppLogger(stateRoot);
        _transferService = new TransferService(_stateStore, _logger);
        _wipeService = new WipeService(_stateStore, _logger);

        InitializeComponent();
        Title = IsVisualPreview ? "Media Shuttle — Visual Preview" : "Media Shuttle";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppHeader);
        try
        {
            SystemBackdrop = new MicaBackdrop();
        }
        catch
        {
            SystemBackdrop = new DesktopAcrylicBackdrop();
        }

        IntPtr windowHandle = WindowNative.GetWindowHandle(this);
        _windowHandle = windowHandle;
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(windowHandle));
        _appWindow.Title = Title;
        if (_appWindow.Presenter is OverlappedPresenter windowPresenter)
            windowPresenter.SetBorderAndTitleBar(true, true);
        InitializeProgressSegments();
        StatusInfoBar.RegisterPropertyChangedCallback(InfoBar.IsOpenProperty, (_, _) =>
            StatusBanner.Visibility = StatusInfoBar.IsOpen ? Visibility.Visible : Visibility.Collapsed);
        DismissBannerButton.Click += (_, _) => StatusInfoBar.IsOpen = false;
        SizeAndCenterWindow(windowHandle);
        if (_launchInBackground)
        {
            // Activate() below shows the window, and the earliest we can hide it again is the
            // Activated handler one message-pump turn later — long enough for Windows to paint a
            // centred window and animate it in. Park it off the virtual screen until something
            // actually asks for it, so a boot launch shows nothing at all. ShowWindow() centres it
            // before the first real reveal.
            _placementPending = true;
            _appWindow.Move(new PointInt32(-30000, -30000));
        }
        // The ScrollViewer is the one thing that knows how much room the layout really has.
        // AppWindow.Size counts the window frame as well, announces a resize before the content is
        // laid out again, and is in physical pixels, so every reader of it had to undo the display
        // scale first. This fires once the ScrollViewer has been given its new size, already in the
        // units the layout is written in.
        RootScrollViewer.SizeChanged += (_, args) =>
        {
            UpdateResponsiveLayout();
            ApplyActivityListHeight(args.NewSize.Height);
        };

        // A vertical scroll bar appearing takes its width out of the viewport without changing the
        // ScrollViewer's own size, so SizeChanged alone left the layout a scroll bar wider than the
        // room it had and clipped its right-hand edge. Following the viewport itself covers both.
        RootScrollViewer.RegisterPropertyChangedCallback(
            ScrollViewer.ViewportWidthProperty,
            (_, _) => UpdateResponsiveLayout());
        Root.ActualThemeChanged += (_, _) => UpdateTitleBarColors();
        UpdateTitleBarColors();
        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "MediaShuttle.ico");
        if (File.Exists(iconPath))
        {
            _appWindow.SetIcon(iconPath);
        }

        _appWindow.Closing += OnAppWindowClosing;

        // A background launch (the Windows startup shortcut passes --background) still needs
        // Activate() called once — without it the root element never loads, so InitializeAsync
        // never runs and the app never scans for cards. Hiding only after InitializeAsync
        // finishes its awaits (settings load, destination checks, the first card scan) let the
        // window sit on screen for that whole stretch on every automatic boot launch. Hide it on
        // the very first Activated instead, which together with the off-screen parking above means
        // a background launch never puts anything on screen. Later activations (the user reopening
        // from the tray icon) are intentionally left alone.
        Activated += (_, _) =>
        {
            if (_initialActivationHandled)
            {
                return;
            }
            _initialActivationHandled = true;
            if (_launchInBackground)
            {
                _appWindow.Hide();
            }
        };

        DestinationText.Text = _destinationRoot;
        DestinationText.SetValue(ToolTipService.ToolTipProperty, _destinationRoot);
        ActivityList.ItemsSource = _activity;

        OpenFolderButton.Click += (_, _) => OpenDestinationFolder();
        ChangeDestinationButton.Click += async (_, _) => await ChooseDestinationAsync();
        ChooseSourceButton.Click += async (_, _) => await ChooseSourceAsync();
        AutomaticSourceButton.Click += async (_, _) => await UseAutomaticSourceAsync();
        CancelButton.Click += (_, _) => CancelOperation();
        WipeButton.Click += async (_, _) => await ConfirmAndWipeAsync();
        ReportButton.Click += (_, _) => OpenSessionReport();
        SessionTransferAgainButton.Click += async (_, _) =>
        {
            if (_destinationAvailable) await StartTransferAsync();
            else await ChooseDestinationAsync();
        };
        AutoTransferToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        GroupByDateToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        NotificationsToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        ActivityToggle.Toggled += async (_, _) =>
        {
            ActivitySection.Visibility = ActivityToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
            ScheduleActivityListHeightUpdate();
            await SaveSettingsFromControlsAsync();
        };
        StartupToggle.Toggled += async (_, _) => await UpdateStartupAsync();
        foreach (RadioButton themeButton in ThemeButtons)
        {
            themeButton.Checked += async (_, _) => await UpdateThemeAsync();
        }
        EjectButton.Click += async (_, _) => await EjectCardAsync();

        _scanTimer = DispatcherQueue.CreateTimer();
        _scanTimer.Interval = TimeSpan.FromSeconds(2);
        _scanTimer.Tick += async (_, _) => await ScanCardsAsync();

        _scanPulseTimer = DispatcherQueue.CreateTimer();
        _scanPulseTimer.Interval = TimeSpan.FromMilliseconds(80);
        _scanPulseTimer.Tick += (_, _) => AdvanceScanPulse();

        _trayIcon = new TrayIconService(
            windowHandle,
            iconPath,
            () => DispatcherQueue.TryEnqueue(ShowWindow),
            BuildTrayMenu);
        Root.Loaded += async (_, _) =>
        {
#if DEBUG
            if (IsVisualPreview) { ConfigureVisualPreview(); return; }
#endif
            await InitializeAsync();
        };
    }

    /// <summary>
    /// The tray menu, built fresh each time it opens. It carries what the macOS menu bar panel
    /// does: where things stand, the next action, the card and destination actions, and the
    /// automatic-transfer switch.
    /// </summary>
    private IReadOnlyList<TrayMenuItem> BuildTrayMenu()
    {
        void Run(Func<Task> action) => DispatcherQueue.TryEnqueue(async () => await action());
        void RunWithWindow(Func<Task> action) => DispatcherQueue.TryEnqueue(async () => { ShowWindow(); await action(); });

        var items = new List<TrayMenuItem>
        {
            new(TrayStatus()),
            TrayMenuItem.Separator,
            new("Open Media Shuttle", () => DispatcherQueue.TryEnqueue(ShowWindow), IsDefault: true),
            TrayMenuItem.Separator
        };

        if (_busy)
        {
            if (_operationCancellation is not null)
                items.Add(new("Cancel transfer", () => DispatcherQueue.TryEnqueue(CancelOperation)));
        }
        else if (!_destinationAvailable)
        {
            items.Add(new("Choose destination…", () => RunWithWindow(ChooseDestinationAsync)));
        }
        else
        {
            items.Add(new(_verifiedSession is null ? "Transfer and verify" : "Transfer again",
                () => Run(StartTransferAsync), Enabled: _currentCard is not null && _lastScannedMediaCount > 0));
        }
        items.Add(new("Scan for media", () => Run(() => ScanCardsAsync(force: true)), Enabled: !_busy));
        items.Add(new("Choose source…", () => RunWithWindow(ChooseSourceAsync), Enabled: !_busy));
        if (_selectedSourceRoot is not null)
            items.Add(new("Use auto-detect", () => Run(UseAutomaticSourceAsync), Enabled: !_busy));
        if (_currentCardEjectable && _currentCard is not null)
            items.Add(new($"Eject {_currentCard.VolumeLabel}", () => Run(EjectCardAsync), Enabled: CanEject));
        items.Add(TrayMenuItem.Separator);
        items.Add(new("Open destination folder", () => DispatcherQueue.TryEnqueue(OpenDestinationFolder), Enabled: _destinationAvailable));
        items.Add(new("Show transfer report", () => DispatcherQueue.TryEnqueue(OpenSessionReport), Enabled: !_busy && _lastSessionFilePath is not null));
        items.Add(new("Erase card…", () => RunWithWindow(ConfirmAndWipeAsync), Enabled: WipeButton.IsEnabled));
        items.Add(TrayMenuItem.Separator);
        items.Add(new("Transfer new cards automatically",
            () => DispatcherQueue.TryEnqueue(() => AutoTransferToggle.IsOn = !AutoTransferToggle.IsOn),
            Enabled: !_busy, Checked: _settings.AutoTransfer));
        items.Add(TrayMenuItem.Separator);
        items.Add(new("Quit Media Shuttle", () => DispatcherQueue.TryEnqueue(ExitApplication)));
        return items;
    }

    private string TrayStatus()
    {
        string status = TopStatusText.Text;
        if (_busy && PercentText.Text is { Length: > 0 } percent && PhaseText.Text is { Length: > 0 } phase)
        {
            status = $"{phase} · {percent}";
        }
        return string.IsNullOrWhiteSpace(status) ? "Media Shuttle" : status;
    }

    private void CancelOperation()
    {
        if (_operationCancellation is null) return;
        _operationCancellation.Cancel();
        CancelButton.IsEnabled = false;
        AddActivity("Stopping the transfer.");
    }

    private void SizeAndCenterWindow(IntPtr windowHandle)
    {
        uint dpi = NativeMethods.GetDpiForWindow(windowHandle);
        double scale = Math.Max(1.0, dpi / 96.0);
        DisplayArea displayArea = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Primary);
        if (IsVisualPreview)
        {
            var displays = DisplayArea.FindAll();
            for (int index = 0; index < displays.Count; index++)
                if (!displays[index].IsPrimary) { displayArea = displays[index]; break; }
        }
        RectInt32 workArea = displayArea.WorkArea;

        // Windows otherwise lets the window be dragged down to a few dozen pixels, which no layout
        // survives. This is the narrowest the single-column arrangement still renders cleanly.
        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)Math.Round(420 * scale);
            presenter.PreferredMinimumHeight = (int)Math.Round(420 * scale);
        }

        int edgeMargin = (int)Math.Round(24 * scale);
        int maximumWidth = Math.Max(720, workArea.Width - edgeMargin * 2);
        int maximumHeight = Math.Max(560, workArea.Height - edgeMargin * 2);
        int width = Math.Min((int)Math.Round(1060 * scale), maximumWidth);
        int height = Math.Min((int)Math.Round(530 * scale), maximumHeight);
        int x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        int y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);

        _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private void InitializeProgressSegments()
    {
        for (int index = 0; index < 32; index++)
        {
            SegmentedProgressGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var segment = new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)) };
            Grid.SetColumn(segment, index);
            SegmentedProgressGrid.Children.Add(segment);
            _progressSegments.Add(segment);
        }
    }

    private void UpdateResponsiveLayout()
    {
        // ViewportWidth rather than ActualWidth: the difference between them is a vertical scroll
        // bar's worth of room the content cannot use, and with horizontal scrolling disabled
        // anything wider than the viewport is clipped rather than reachable.
        double contentWidth = RootScrollViewer.ViewportWidth > 0
            ? RootScrollViewer.ViewportWidth
            : RootScrollViewer.ActualWidth;
        if (contentWidth <= 0 || Math.Abs(contentWidth - _appliedLayoutWidth) < 0.5)
        {
            return;
        }
        _appliedLayoutWidth = contentWidth;

        // The ScrollViewer leaves its content width unconstrained, so give the layout the
        // viewport width explicitly to make every section reflow with the window.
        MainLayout.Width = contentWidth;

        // Measure breakpoints against the full width on large displays.
        double width = contentWidth;
        bool narrow = width < NarrowLayoutWidth;
        double sidebarWidth = width >= 1600 ? 320 : SidebarWidth;

        SourceColumn.Width = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(sidebarWidth);
        DividerColumn.Width = narrow ? new GridLength(0) : new GridLength(1);
        OperationsColumn.Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        SourceDivider.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        Grid.SetColumn(SourcePanel, 0);
        Grid.SetRow(SourcePanel, 0);
        Grid.SetColumn(OperationsPanel, narrow ? 0 : 2);
        Grid.SetRow(OperationsPanel, narrow ? 1 : 0);
        MainLayoutTopRow.Height = narrow ? GridLength.Auto : new GridLength(1, GridUnitType.Star);
        MainLayoutBottomRow.Height = narrow ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        MainLayout.ColumnSpacing = 0;
        Thickness padding = narrow ? new Thickness(16, 14, 16, 22) : new Thickness(0);
        MainLayout.Padding = padding;

        bool compactTitleBar = width < 760;
        bool iconOnlyTitleBar = width < 520;
        StatusPill.Visibility = compactTitleBar ? Visibility.Collapsed : Visibility.Visible;
        AppNameText.Visibility = iconOnlyTitleBar ? Visibility.Collapsed : Visibility.Visible;
        AppLogo.Width = 20;
        AppLogo.Height = 12.5;
        AppNameText.FontSize = 13;
        SettingsButton.Width = 30;
        SettingsButton.Height = 30;
        SettingsButton.Margin = new Thickness(0);
        AppHeader.Margin = new Thickness(compactTitleBar ? 12 : 20, 0, 160, 0);

        // Width the operations column itself is drawn at: the layout less its padding, and less the
        // sidebar and the gap between the columns while the two sit side by side. Everything below
        // reflows against this rather than the window.
        double operationsWidth = width - padding.Left - padding.Right - (narrow ? 0 : sidebarWidth + ColumnGap);
        double panelWidth = operationsWidth - PanelPadding * 2;

        bool stackActions = operationsWidth < StackedActionWidth;
        SetActionPlacement(EraseGrid, EraseActionColumn, WipeButton, stackActions, 220, 10);


        SetSessionStatsColumns(panelWidth switch
        {
            < 480 => 2,
            < 800 => 3,
            _ => 5
        });

        ScheduleActivityListHeightUpdate();
    }

    /// <summary>
    /// Puts a panel's action control beside its text, or beneath it once the two side by side would
    /// leave the text narrower than the words in it.
    /// </summary>
    private static void SetActionPlacement(
        Grid grid,
        ColumnDefinition actionColumn,
        FrameworkElement action,
        bool stacked,
        double columnWidth,
        double columnGap)
    {
        actionColumn.Width = stacked ? new GridLength(0) : new GridLength(columnWidth);
        Grid.SetColumn(action, stacked ? 0 : 1);
        Grid.SetRow(action, stacked ? 1 : 0);

        // Stacked, the action keeps the width it has beside the text rather than stretching the
        // whole way across: a 440px-wide primary button reads as a banner, not as a button.
        action.HorizontalAlignment = stacked ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        action.Width = stacked ? columnWidth : double.NaN;

        // Column spacing is reserved either side of a zero-width column too, which would leave the
        // stacked layout a dead strip down its right edge.
        grid.ColumnSpacing = stacked ? 0 : columnGap;
        grid.RowSpacing = stacked ? 14 : 0;
    }

    /// <summary>
    /// Reflows the five session statistics across the given number of columns. Five across a narrow
    /// window leaves each one narrower than its own label, which clips rather than wraps.
    /// </summary>
    private void SetSessionStatsColumns(int columns)
    {
        StackPanel[] stats = [CopiedStat, SkippedStat, ProcessedStat, ThroughputStat, ElapsedStat];
        if (SessionStatsGrid.ColumnDefinitions.Count == columns)
        {
            return;
        }

        int rows = (int)Math.Ceiling((double)stats.Length / columns);
        SessionStatsGrid.ColumnDefinitions.Clear();
        for (int column = 0; column < columns; column++)
        {
            SessionStatsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        SessionStatsGrid.RowDefinitions.Clear();
        for (int row = 0; row < rows; row++)
        {
            SessionStatsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }

        for (int index = 0; index < stats.Length; index++)
        {
            Grid.SetColumn(stats[index], index % columns);
            Grid.SetRow(stats[index], index / columns);
        }

        SessionStatsGrid.RowSpacing = rows > 1 ? 13 : 0;
        Rectangle[] dividers = [MetricDivider1, MetricDivider2, MetricDivider3, MetricDivider4];
        for (int index = 0; index < dividers.Length; index++)
        {
            int metricIndex = index + 1;
            Grid.SetColumn(dividers[index], metricIndex % columns);
            Grid.SetRow(dividers[index], metricIndex / columns);
            dividers[index].Visibility = metricIndex % columns == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    /// <summary>
    /// The sizing below measures a laid-out window, so it has to run after the layout pass a resize
    /// triggers rather than inside the event that announces the resize.
    /// </summary>
    private void ScheduleActivityListHeightUpdate() =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, UpdateActivityListHeight);

    /// <summary>
    /// Every row of the layout is Auto-sized inside a ScrollViewer, so a window taller than the
    /// content leaves dead space below the erase panel. The activity list is the one element that
    /// can usefully absorb it. Measuring the rest of the layout, rather than hard-coding its
    /// height, keeps this correct as the panels above it grow and shrink.
    /// </summary>
    private void UpdateActivityListHeight() => ApplyActivityListHeight(RootScrollViewer.ViewportHeight);

    private void ApplyActivityListHeight(double viewportHeight)
    {
        // The star row only needs to reserve room while there is a log in it. Left at a minimum
        // with the log switched off, it would hold a gap open above the erase bar for nothing.
        ActivityRow.MinHeight = ActivitySection.Visibility == Visibility.Visible ? MinimumActivityRowHeight : 0;
        if (ActivitySection.Visibility != Visibility.Visible)
        {
            return;
        }

        // DesiredSize, not ActualHeight: a ScrollViewer stretches content shorter than its viewport,
        // so ActualHeight reports the viewport back and the arithmetic below cancels out. DesiredSize
        // is what the content asked for. Subtracting the list leaves a figure that does not move when
        // the list is resized, so this converges in one pass rather than oscillating.
        double everythingElse = MainLayout.DesiredSize.Height - ActivityList.ActualHeight;
        if (viewportHeight <= 0 || everythingElse <= 0)
        {
            return;
        }

        // Capped: the erase bar is held on the bottom edge by the star row this sits in, not by the
        // log growing to fill it, so past the cap the spare height shows as room below the log
        // rather than as a very large empty box with one line in it.
        ActivityList.Height = Math.Clamp(
            viewportHeight - everythingElse,
            MinimumActivityHeight,
            MaximumActivityHeight);
    }

    private void SetProgressFill(double startPercent, double widthPercent, bool complete)
    {
        startPercent = Math.Clamp(startPercent, 0, 100);
        widthPercent = Math.Clamp(widthPercent, 0, 100 - startPercent);
        for (int index = 0; index < _progressSegments.Count; index++)
        {
            double position = index * 100.0 / _progressSegments.Count;
            _progressSegments[index].Fill = position >= startPercent && position < startPercent + widthPercent
                ? (complete ? VerifiedStatusBrush : ActiveStatusBrush)
                : new SolidColorBrush(Color.FromArgb(18, 255, 255, 255));
        }
    }

    private void UpdateSegmentedProgress(double percent, bool complete)
    {
        _scanPulseTimer.Stop();
        SetProgressFill(0, percent, complete);
    }

    private void StartScanPulse()
    {
        if (_scanPulseTimer.IsRunning)
        {
            return;
        }
        _scanPulsePosition = 0;
        _scanPulseDirection = 1;
        _scanPulseTimer.Start();
    }

    private void AdvanceScanPulse()
    {
        double travel = 100 - ScanPulseWidthPercent;
        _scanPulsePosition += _scanPulseDirection * 2.5;
        if (_scanPulsePosition >= travel)
        {
            _scanPulsePosition = travel;
            _scanPulseDirection = -1;
        }
        else if (_scanPulsePosition <= 0)
        {
            _scanPulsePosition = 0;
            _scanPulseDirection = 1;
        }
        SetProgressFill(_scanPulsePosition, ScanPulseWidthPercent, complete: false);
    }

    private async Task InitializeAsync()
    {
        _settings = await _stateStore.LoadSettingsAsync();
        bool hasSavedDestination = !string.IsNullOrWhiteSpace(_settings.DestinationRoot);
        if (hasSavedDestination)
        {
            try
            {
                _destinationRoot = Path.GetFullPath(_settings.DestinationRoot);
            }
            catch
            {
                _destinationRoot = DefaultDestinationRoot();
            }
        }

        Exception? destinationError = null;
        try
        {
            if (hasSavedDestination)
            {
                if (!Directory.Exists(_destinationRoot))
                {
                    throw new DirectoryNotFoundException($"Saved destination is missing: {_destinationRoot}");
                }
            }
            else
            {
                EnsureDestinationRoot(_destinationRoot);
            }
        }
        catch (Exception exception) when (IsDestinationException(exception))
        {
            _destinationAvailable = false;
            destinationError = exception;
        }

        UpdateDestinationDisplay();
        OpenFolderButton.IsEnabled = _destinationAvailable;
        AutoTransferToggle.IsOn = _settings.AutoTransfer;
        GroupByDateToggle.IsOn = _settings.GroupByDate;
        NotificationsToggle.IsOn = _settings.ShowNotifications;
        ActivityToggle.IsOn = _settings.ShowActivityLog;
        ActivitySection.Visibility = _settings.ShowActivityLog ? Visibility.Visible : Visibility.Collapsed;
        ScheduleActivityListHeightUpdate();
        StartupToggle.IsOn = StartupService.IsEnabled;
        SelectThemeButton(_settings.Theme);
        ApplyTheme(_settings.Theme);
        if (_destinationAvailable)
        {
            _settings.DestinationRoot = _destinationRoot;
            await _stateStore.SaveSettingsAsync(_settings);
        }
        _settingsReady = true;
        AddActivity("Watching for camera cards.");
        _scanTimer.Start();
        await ScanCardsAsync();

        if (destinationError is not null)
        {
            ShowError(
                "Destination unavailable",
                "The saved destination folder can't be opened. Choose a folder before transferring.");
            AddActivity("Destination unavailable: " + destinationError.Message);
            SetTopStatus("Choose a destination", ErrorStatusBrush);

            // The window was already hidden immediately on launch (see the Activated handler
            // above) so a bad saved destination isn't silently invisible in the tray — surface
            // the window so the error is actually seen.
            if (_launchInBackground)
            {
                ShowWindow();
            }
        }
    }

    private async Task ScanCardsAsync(bool force = false)
    {
        if (_busy || _scanInProgress)
        {
            return;
        }

        _scanInProgress = true;
        string destination = _destinationRoot;
        string? selectedSource = _selectedSourceRoot;
        int sourceVersion = _sourceVersion;
        try
        {
            IReadOnlyList<CardInfo> cards = await Task.Run(() => selectedSource is null
                ? CardDetector.GetCandidates(destination)
                : new[] { CardDetector.GetSelectedSource(selectedSource) });
            if (_busy || sourceVersion != _sourceVersion || destination != _destinationRoot) return;
            var activeRoots = cards.Select(card => card.RootPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
            string? selectedRoot = cards.Count > 0 ? cards[0].RootPath : null;
            bool isNew = selectedSource is null && _cardPresence.Observe(selectedRoot, activeRoots);
            if (cards.Count == 0)
            {
                _currentCard = null;
                _verifiedSession = null;
                _lastScannedMediaCount = -1;
                _unverifiableFileCount = 0;
                _lastScanSignature = null;
                UpdateDisconnectedState();
                return;
            }

            CardInfo card = cards[0];
            bool cardChanged = _currentCard is null ||
                               !_currentCard.RootPath.Equals(card.RootPath, StringComparison.OrdinalIgnoreCase);
            TransferSession? previousSession = _verifiedSession;
            int previousMediaCount = _lastScannedMediaCount;
            int previousUnverifiableCount = _unverifiableFileCount;

            _currentCard = card;

            // This runs every two seconds for as long as a card stays connected. Walking the whole
            // card and re-reading the session reports each time is minutes of pointless reader and
            // disk traffic on a full card, so skip it while the card looks untouched. Adding or
            // removing anything on a camera card moves the free-space figure, which is read fresh by
            // GetCandidates above.
            string scanSignature = $"{card.RootPath}|{card.VolumeSerial}|{card.FreeBytes}";
            if (!force && !isNew && !cardChanged && scanSignature == _lastScanSignature)
            {
                return;
            }
            _lastScanSignature = scanSignature;
            CardScan scan = await Task.Run(() => MediaClassifier.ScanCard(card.RootPath));
            if (_busy || sourceVersion != _sourceVersion || destination != _destinationRoot) return;
            IReadOnlyList<MediaItem> media = scan.Media;
            _unverifiableFileCount = scan.UnverifiableFiles.Count;
            _lastScannedMediaCount = media.Count;
            CardStatsText.Text = $"{media.Count:N0} assets · {FormatBytes(media.Sum(item => item.Size))}";
            UpdateCapacity(card);
            UpdateCardContents(media);
            TransferSession? storedSession = await _stateStore.LoadLatestVerifiedForCardAsync(card);
            if (_busy || sourceVersion != _sourceVersion || destination != _destinationRoot) return;
            _verifiedSession = storedSession?.IsEligibleForErase(card, media) == true ? storedSession : null;
            _sourceAllowsErase = selectedSource is null || CardDetector.IsCameraCardVolume(card.RootPath);

            // WipeService refuses a card holding content no transfer could have copied. Reflect that
            // here so erase reads as locked, rather than accepting the typed confirmation and only
            // then refusing.
            bool canWipe = _sourceAllowsErase && _verifiedSession is { Files.Count: > 0 } && _unverifiableFileCount == 0;
            bool verificationChanged = previousSession?.SessionId != _verifiedSession?.SessionId;
            WipeButton.IsEnabled = canWipe;
            if (cardChanged || previousMediaCount != media.Count || verificationChanged ||
                previousUnverifiableCount != _unverifiableFileCount)
            {
                if (media.Count == 0)
                {
                    UpdateEmptyCardState(card, canWipe);
                }
                else if (_verifiedSession is not null)
                {
                    UpdateVerifiedState(card, _verifiedSession!);
                }
                else
                {
                    UpdateDetectedState(card);
                }
            }

            if (isNew)
            {
                AddActivity($"Detected {card.VolumeLabel} at {card.RootPath}");

                // The in-app activity list holds six lines and is gone when the app restarts. This
                // app spends most of its life in the tray, so card arrivals belong in the log too —
                // it is the only record available when diagnosing a transfer that ran unattended.
                await _logger.WriteAsync(
                    $"Detected {card.VolumeLabel} at {card.RootPath}: {media.Count:N0} media file(s), " +
                    $"{_unverifiableFileCount:N0} unverifiable");
                if (_unverifiableFileCount > 0)
                {
                    AddActivity(
                        $"{_unverifiableFileCount:N0} file(s) on this card aren't camera media, so they can't be verified. Erase stays locked.");
                }

                // A freshly inserted card is the one moment this app has something to say, so
                // surface the window whenever it is hidden — not only when the process happened to
                // be launched with --background. Closing the window sends it to the tray, and
                // without this an auto-transfer would otherwise run entirely out of sight.
                if (!_appWindow.IsVisible)
                {
                    ShowWindow();
                }
                if (_settings.AutoTransfer && media.Count > 0)
                {
                    if (_destinationAvailable)
                    {
                        await StartTransferAsync();
                    }
                    else
                    {
                        // Unattended, this used to do nothing at all: no transfer, and nothing to
                        // say why when the reader came back to a card they expected to find copied.
                        AddActivity("Automatic transfer skipped: the destination folder is unavailable.");
                        ShowNotification(
                            "Automatic transfer skipped",
                            $"{card.VolumeLabel} was not copied because the destination folder is unavailable.");
                    }
                }
            }
        }
        catch (Exception exception)
        {
            if (_busy || sourceVersion != _sourceVersion || destination != _destinationRoot) return;
            ResetSourceState();
            ShowError("Source scan failed", exception.Message);
            SetTopStatus("Source unavailable", ErrorStatusBrush);
            await _logger.WriteAsync("Card scan failed: " + exception);
        }
        finally
        {
            _scanInProgress = false;
            UpdateDestinationAction();
        }
    }

    private async Task StartTransferAsync()
    {
        if (IsVisualPreview) return;
        if (_busy)
        {
            return;
        }
        if (_destinationAvailable && !Directory.Exists(_destinationRoot))
        {
            _destinationAvailable = false;
            UpdateDestinationDisplay();
        }
        if (!_destinationAvailable)
        {
            await ChooseDestinationAsync();
            return;
        }
        if (_currentCard is null)
        {
            await ScanCardsAsync(force: true);
            if (_currentCard is null)
            {
                ShowMessage(
                    "No media source found",
                    "Choose a source folder or connect a card containing DCIM, M4ROOT, or PRIVATE folders.",
                    InfoBarSeverity.Informational);
                return;
            }
        }
        if (_lastScannedMediaCount == 0)
        {
            ShowMessage(
                "No supported media found",
                "This card does not currently contain supported photos or videos.",
                InfoBarSeverity.Informational);
            return;
        }

        _busy = true;
        _operationStartedUtc = DateTimeOffset.UtcNow;
        _operationEndedUtc = null;
        ResetProgressThrottle();
        _operationCancellation = new CancellationTokenSource();
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: true);
        SessionTransferAgainButton.Content = "Scanning media…";
        SetTopStatus("Transfer active", ActiveStatusBrush);
        AddActivity($"Transfer started from {_currentCard.RootPath}");

        try
        {
            var progress = new Progress<OperationProgress>(UpdateProgress);
            TransferResult result = await _transferService.TransferAsync(
                _currentCard,
                _destinationRoot,
                _settings.GroupByDate,
                progress,
                _operationCancellation.Token);
            _verifiedSession = result.Session;
            UpdateVerifiedState(_currentCard, result.Session);
            AddActivity(
                $"Verified {result.Session.TotalFiles:N0} files: " +
                $"{result.Session.CopiedCount:N0} copied, {result.Session.SkippedCount:N0} already at the destination.");
            ShowMessage(
                "Transfer verified",
                $"{result.Session.TotalFiles:N0} files copied and checked with SHA-256.",
                InfoBarSeverity.Success);
            ShowNotification(
                "Transfer verified",
                $"{result.Session.TotalFiles:N0} files copied and checked with SHA-256.");
        }
        catch (OperationCanceledException)
        {
            PhaseText.Text = "CANCELLED";
            AddActivity("Transfer cancelled.");
            SetTopStatus("Transfer cancelled", WarningStatusBrush);
            ShowMessage(
                "Transfer cancelled",
                "Files already copied were kept. Unfinished copies were removed.",
                InfoBarSeverity.Warning);
        }
        catch (Exception exception)
        {
            PhaseText.Text = "NEEDS ATTENTION";
            ShowError("Transfer stopped", exception.Message);
            AddActivity("Transfer stopped: " + exception.Message);
            await _logger.WriteAsync("Transfer stopped: " + exception);
            SetTopStatus("Needs attention", ErrorStatusBrush);

            // Automatic transfers run with the window closed, so a failure needs to reach the
            // reader the same way a success does.
            ShowNotification("Transfer stopped", exception.Message);
        }
        finally
        {
            _scanPulseTimer.Stop();
            if (_lastScannedMediaCount > 0)
            {
                SessionTransferAgainButton.Content = _verifiedSession is null ? "Transfer + verify" : "Transfer again";
            }
            _operationCancellation.Dispose();
            _operationCancellation = null;
            _busy = false;
            SetOperationControls(false, allowCancel: false);

            // Reading the card does not move its free space, so let the next tick re-derive state
            // rather than have the skip-unchanged check hold on to what was true before the transfer.
            _lastScanSignature = null;
        }
    }

    private async Task ConfirmAndWipeAsync()
    {
        if (IsVisualPreview)
        {
            if (_currentCard is not null)
                await CreateEraseConfirmationDialog(_currentCard).ShowAsync();
            return;
        }
        if (_busy || !_sourceAllowsErase || _unverifiableFileCount > 0 || _currentCard is null || _verifiedSession is null)
        {
            return;
        }

        // Captured so the erase that actually runs is the card and session shown in this dialog,
        // not whatever _currentCard/_verifiedSession happen to be once the user responds. The scan
        // timer keeps running while this dialog awaits input, and can reassign both fields (e.g. the
        // card is pulled, or swapped for a different already-verified card) before the user answers.
        CardInfo targetCard = _currentCard;
        TransferSession targetSession = _verifiedSession;

        if (await CreateEraseConfirmationDialog(targetCard).ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        await WipeConfirmedCardAsync(targetCard, targetSession);
    }

    private ContentDialog CreateEraseConfirmationDialog(CardInfo targetCard)
    {
        var palette = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
            Root.ActualTheme == ElementTheme.Light ? "Light" : "Default"];

        var phrase = new TextBox
        {
            Style = (Style)Application.Current.Resources["ShuttleTextBoxStyle"],
            Header = new TextBlock
            {
                Text = "TYPE ERASE EVERYTHING TO CONFIRM",
                Style = (Style)Application.Current.Resources["SectionLabelStyle"]
            },
            PlaceholderText = "ERASE EVERYTHING"
        };
        var acknowledge = new CheckBox
        {
            Style = (Style)Application.Current.Resources["ShuttleCheckBoxStyle"],
            Content = new TextBlock
            {
                Text = $"I understand this permanently deletes all files and folders on {targetCard.RootPath}.",
                FontFamily = new FontFamily("Cascadia Mono"),
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap
            }
        };
        phrase.Resources["TextControlBorderBrushFocused"] = (Brush)palette["TextBrightBrush"];
        var content = new StackPanel { Spacing = 14 };
        content.Children.Add(new TextBlock
        {
            Text =
                "Every media file is checked against its copy again before anything is deleted. " +
                "Everything else on the card is deleted too, including camera databases and sidecar files.",
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Cascadia Mono"),
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.Normal
        });
        content.Children.Add(phrase);
        content.Children.Add(acknowledge);

        var dialog = new ContentDialog
        {
            Style = (Style)Application.Current.Resources["ShuttleDialogStyle"],
            RequestedTheme = Root.ActualTheme,
            XamlRoot = Root.XamlRoot,
            Title = $"Erase {targetCard.VolumeLabel}",
            Content = content,
            PrimaryButtonText = "Erase card",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false
        };
        dialog.Resources["ContentDialogTopOverlay"] = palette["PanelBackgroundBrush"];
        dialog.Resources["ContentDialogSeparatorBorderBrush"] = palette["HairlineBrush"];
        dialog.Opened += (_, _) =>
        {
            // WinUI replaces the default action's style when the dialog opens.
            // Keep Cancel as the safe default while restoring the app's button appearance.
            if (FindVisualChild<Button>(dialog, "CloseButton") is Button closeButton)
                closeButton.Style = (Style)Application.Current.Resources["ShuttleSecondaryButtonStyle"];
        };
        void Validate(object? sender, object args) =>
            dialog.IsPrimaryButtonEnabled =
                !IsVisualPreview && phrase.Text.Trim().Equals("ERASE EVERYTHING", StringComparison.Ordinal) &&
                acknowledge.IsChecked == true;
        phrase.TextChanged += Validate;
        acknowledge.Checked += Validate;
        acknowledge.Unchecked += Validate;
        return dialog;
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

    private async Task WipeConfirmedCardAsync(CardInfo targetCard, TransferSession targetSession)
    {
        // _busy was only false when this dialog opened. The scan timer keeps ticking while it waits
        // for input, and with auto-transfer on an inserted card starts a transfer from that tick —
        // so an erase confirmed now would delete the very files a transfer is still reading.
        if (_busy)
        {
            ShowError(
                "Transfer in progress",
                "A transfer started while the confirmation was open. Wait for it to finish, then erase the card.");
            AddActivity("Erase cancelled: a transfer started during confirmation.");
            return;
        }

        bool stillMatches = _sourceAllowsErase && _currentCard is not null &&
            _currentCard.RootPath.Equals(targetCard.RootPath, StringComparison.OrdinalIgnoreCase) &&
            _currentCard.VolumeSerial == targetCard.VolumeSerial &&
            _verifiedSession?.SessionId == targetSession.SessionId;
        if (!stillMatches)
        {
            ShowError(
                "Card changed",
                "The connected card changed while the confirmation was open. Reconnect the card and try erasing again.");
            AddActivity("Erase cancelled: the connected card changed during confirmation.");
            return;
        }

        _busy = true;
        _operationStartedUtc = DateTimeOffset.UtcNow;
        _operationEndedUtc = null;
        ResetProgressThrottle();
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: false);
        WipeButton.IsEnabled = false;
        SetTopStatus("Erase active", ActiveStatusBrush);
        AddActivity("Erasing. Checking every file against its copy first.");

        try
        {
            var progress = new Progress<OperationProgress>(UpdateProgress);
            WipeResult result = await _wipeService.WipeEverythingAsync(
                targetCard,
                targetSession,
                progress,
                CancellationToken.None);
            _verifiedSession = null;
            _lastScannedMediaCount = 0;
            _lastSessionFilePath = null;
            ReportButton.IsEnabled = false;
            SessionTransferAgainButton.IsEnabled = false;
            UpdateEraseBadge(unlocked: false);
            SessionTransferAgainButton.Content = "No media found";
            WipeDescriptionText.Text = "Card erased. Insert another card, or put this one back in your camera.";
            SetTopStatus("Card empty", VerifiedStatusBrush);
            AddActivity($"Erased {result.DeletedFiles:N0} files from the card.");
            ShowNotification("Card erased", $"{result.DeletedFiles:N0} files deleted from the card.");
            ShowMessage(
                "Card erased",
                $"{result.DeletedFiles:N0} files deleted from the card.",
                InfoBarSeverity.Success);
        }
        catch (Exception exception)
        {
            ShowError("Erase blocked", exception.Message);
            AddActivity("Erase blocked: " + exception.Message);
            await _logger.WriteAsync("Erase blocked: " + exception);
            SetTopStatus("Erase blocked", ErrorStatusBrush);
            WipeButton.IsEnabled = _sourceAllowsErase && _unverifiableFileCount == 0 && _verifiedSession is not null;
        }
        finally
        {
            _busy = false;
            SetOperationControls(false, allowCancel: false);
            _lastScanSignature = null;
        }
    }

    private void UpdateProgress(OperationProgress progress)
    {
        bool complete = progress.Phase == OperationPhase.Complete;

        // Every report that moves the operation on is drawn: a new phase, a new file, and the last
        // one of all. What is dropped is the stream of identical-looking megabyte reports in
        // between, which no one can read at that rate and which the layout pass cannot keep up with
        // on a fast card reader.
        DateTimeOffset now = DateTimeOffset.UtcNow;
        bool sameStep = progress.Phase == _lastProgressPhase &&
                        progress.CurrentItem == _lastProgressItem;
        bool continuous = progress.Phase is OperationPhase.Copying or OperationPhase.ReVerifying;
        if (continuous && sameStep && now - _lastProgressRedraw < ProgressRedrawInterval)
        {
            return;
        }
        _lastProgressPhase = progress.Phase;
        _lastProgressItem = progress.CurrentItem;
        _lastProgressRedraw = now;
        if (complete) _operationEndedUtc = now;

        if (progress.Phase == OperationPhase.Scanning)
        {
            StartScanPulse();
        }
        else
        {
            UpdateSegmentedProgress(progress.Percent, complete);
        }
        if (progress.Phase == OperationPhase.Scanning)
        {
            SessionTransferAgainButton.Content = "Scanning media…";
        }
        else if (progress.Phase is OperationPhase.CheckingDuplicate or OperationPhase.Copying or OperationPhase.Verifying)
        {
            SessionTransferAgainButton.Content = "Transfer in progress";
        }
        PhaseText.Text = progress.Phase switch
        {
            OperationPhase.Idle => "STANDBY",
            OperationPhase.CheckingDuplicate => "CHECKING",
            OperationPhase.Complete => "VERIFIED",
            OperationPhase.ReVerifying => "RE-VERIFYING",
            OperationPhase.Erasing => "ERASING CONTENTS",
            _ => progress.Phase.ToString().ToUpperInvariant()
        };
        PhaseText.Foreground = complete ? VerifiedStatusBrush : ActiveStatusBrush;
        if (!complete)
        {
            CurrentFileText.Text = FormatCurrentActivity(progress);
        }
        PercentText.Text = $"{progress.Percent:0}%";
        if (!complete)
        {
            // Like the percentage the macOS menu bar shows, so progress is visible from the tray.
            _trayIcon?.SetTooltip($"Media Shuttle · {PhaseText.Text.ToLowerInvariant()} {PercentText.Text}");
        }

        // An erase is measured in entries deleted, not bytes moved, and reports no byte total. Its
        // own progress is in the phase, percentage and current entry above; the copy figures do not
        // apply to it, and reporting the entry count through them showed "12 B" at "0 MB/s avg".
        bool measuredInBytes = progress.TotalBytes > 0;
        CopiedText.Text = measuredInBytes ? $"{progress.CopiedFiles:N0}" : "—";
        SkippedText.Text = measuredInBytes ? $"{progress.SkippedFiles:N0}" : "—";
        var processed = SplitBytes(progress.ProcessedBytes);
        ProcessedText.Text = measuredInBytes ? processed.Value : "—";
        ProcessedCaption.Text = measuredInBytes ? $"{processed.Unit} of {FormatBytes(progress.TotalBytes)}" : "not counted in bytes";

        TimeSpan elapsed = _operationStartedUtc is { } startedAt ? (_operationEndedUtc ?? now) - startedAt : TimeSpan.Zero;
        ElapsedText.Text = FormatElapsed(elapsed);
        UpdateThroughput(measuredInBytes ? progress.ProcessedBytes : 0, elapsed);
    }

    private void ResetProgressThrottle()
    {
        _lastProgressRedraw = DateTimeOffset.MinValue;
        _lastProgressPhase = OperationPhase.Idle;
        _lastProgressItem = string.Empty;
    }

    private static string FormatCurrentActivity(OperationProgress progress)
    {
        const string Verb = "CURRENT";
        if (string.IsNullOrEmpty(progress.CurrentSourcePath))
        {
            return $"{Verb} · {progress.CurrentItem}";
        }
        return string.IsNullOrEmpty(progress.CurrentDestinationFolder)
            ? $"{Verb} · {progress.CurrentSourcePath}"
            : $"{Verb} · {progress.CurrentSourcePath} → {progress.CurrentDestinationFolder}";
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        int totalSeconds = Math.Max(0, (int)elapsed.TotalSeconds);
        return $"{totalSeconds / 60}:{totalSeconds % 60:00}";
    }

    private static (string Value, string Unit) SplitBytes(long bytes)
    {
        string formatted = FormatBytes(bytes);
        int separator = formatted.LastIndexOf(' ');
        return (formatted[..separator], formatted[(separator + 1)..]);
    }

    private void UpdateThroughput(long processedBytes, TimeSpan elapsed)
    {
        if (processedBytes <= 0 || elapsed.TotalSeconds <= 0)
        {
            ThroughputText.Text = "—";
            ThroughputCaption.Text = "idle";
            return;
        }
        var rate = SplitBytes((long)(processedBytes / elapsed.TotalSeconds));
        ThroughputText.Text = rate.Value;
        ThroughputCaption.Text = $"{rate.Unit}/s avg";
    }

    private async Task SaveSettingsFromControlsAsync()
    {
        if (!_settingsReady)
        {
            return;
        }
        _settings.AutoTransfer = AutoTransferToggle.IsOn;
        _settings.GroupByDate = GroupByDateToggle.IsOn;
        _settings.ShowNotifications = NotificationsToggle.IsOn;
        _settings.ShowActivityLog = ActivityToggle.IsOn;
        _settings.DestinationRoot = _destinationRoot;
        await _stateStore.SaveSettingsAsync(_settings);
    }

    private async Task UpdateStartupAsync()
    {
        if (IsVisualPreview) return;
        if (!_settingsReady)
        {
            return;
        }
        try
        {
            StartupService.SetEnabled(StartupToggle.IsOn);
            AddActivity(StartupToggle.IsOn ? "Media Shuttle will start with Windows." : "Media Shuttle won't start with Windows.");
        }
        catch (Exception exception)
        {
            _settingsReady = false;
            StartupToggle.IsOn = !StartupToggle.IsOn;
            _settingsReady = true;
            ShowError("Couldn't change the startup setting", exception.Message);
        }
        await SaveSettingsFromControlsAsync();
    }

    private void UpdateDetectedState(CardInfo card)
    {
        ResetSessionDisplay();
        UpdateCardSummary(card);
        SessionTransferAgainButton.Content = "Transfer + verify";
        SessionTransferAgainButton.IsEnabled = !_busy && _destinationAvailable;
        WipeDescriptionText.Text = LockedEraseDescription();
        UpdateEraseBadge(unlocked: false);
        SetTopStatus("Media detected", ActiveStatusBrush);
        ApplySessionFooter(null, "Ready to transfer");
    }

    private void UpdateVerifiedState(CardInfo card, TransferSession session)
    {
        bool canWipe = _sourceAllowsErase && _unverifiableFileCount == 0;
        if (!_busy)
        {
            _operationStartedUtc = session.StartedUtc;
            ResetProgressThrottle();
            UpdateProgress(new OperationProgress(OperationPhase.Complete, "Transfer verified",
                session.TotalFiles, session.TotalFiles, session.TotalBytes, session.TotalBytes,
                session.CopiedCount, session.SkippedCount));
            _operationEndedUtc = session.CompletedUtc ?? session.StartedUtc;
            TimeSpan elapsed = _operationEndedUtc.Value - session.StartedUtc;
            ElapsedText.Text = FormatElapsed(elapsed);
            UpdateThroughput(session.TotalBytes, elapsed);
        }
        UpdateCardSummary(card);
        SessionTransferAgainButton.Content = "Transfer again";
        SessionTransferAgainButton.IsEnabled = !_busy && _destinationAvailable;
        WipeButton.IsEnabled = canWipe && !_busy;
        WipeDescriptionText.Text = canWipe
            ? $"Every file on {card.RootPath} has a verified copy. You'll be asked to confirm."
            : LockedEraseDescription();
        UpdateEraseBadge(unlocked: canWipe);
        SetTopStatus($"{card.VolumeLabel} · TRANSFER VERIFIED", VerifiedStatusBrush);
        ApplySessionFooter(session);
    }

    private void UpdateEmptyCardState(CardInfo card, bool canWipe)
    {
        if (!canWipe) ResetSessionDisplay();
        UpdateCardSummary(card);
        SessionTransferAgainButton.Content = "No media found";
        SessionTransferAgainButton.IsEnabled = false;
        WipeDescriptionText.Text = canWipe
            ? "Unlocked. There are no photos or videos left to check."
            : _unverifiableFileCount > 0
                ? LockedEraseDescription()
                : "Nothing verified to erase yet.";
        UpdateEraseBadge(unlocked: canWipe);
        SetTopStatus(
            canWipe ? $"{card.VolumeLabel} CONNECTED" : "Card empty",
            canWipe ? VerifiedStatusBrush : NeutralStatusBrush);
        ApplySessionFooter(canWipe ? _verifiedSession : null, "No supported media on this card");
    }

    private string LockedEraseDescription() => !_sourceAllowsErase
        ? "Erase works on camera cards only. Folders you choose can be transferred but not erased."
        : _unverifiableFileCount switch
    {
        0 => "Locked until every file on the card has a verified copy.",
        1 => "Locked: one file on this card isn't camera media, so it can't be verified. Copy it off the card yourself.",
        _ => $"Locked: {_unverifiableFileCount:N0} files on this card aren't camera media, so they can't be verified. Copy them off the card yourself."
    };

    private void UpdateCardSummary(CardInfo card)
    {
        CardLabelText.Text = card.VolumeLabel;
        CardDetailText.Text = $"{card.RootPath} · {card.DriveType} media";
        UpdateCapacity(card);
        UpdateEjectButton();
    }

    private bool CanEject => !_busy && _currentCard is not null && _currentCardEjectable;

    private void UpdateEjectButton()
    {
        _currentCardEjectable = _currentCard is not null && CardEjector.IsEjectable(_currentCard.RootPath);
        EjectButton.Visibility = _currentCardEjectable ? Visibility.Visible : Visibility.Collapsed;
        EjectButton.IsEnabled = CanEject;
    }

    private async Task EjectCardAsync()
    {
        if (IsVisualPreview || !CanEject || _currentCard is not { } card)
        {
            return;
        }

        string label = card.VolumeLabel;
        _busy = true;
        SetOperationControls(true, allowCancel: false);
        AddActivity($"Ejecting {label}.");
        try
        {
            await Task.Run(() => CardEjector.Eject(card.RootPath));
            if (_selectedSourceRoot is not null &&
                Path.TrimEndingDirectorySeparator(_selectedSourceRoot).Equals(
                    Path.TrimEndingDirectorySeparator(card.RootPath), StringComparison.OrdinalIgnoreCase))
            {
                _selectedSourceRoot = null;
                _sourceAllowsErase = true;
                AutomaticSourceButton.Visibility = Visibility.Collapsed;
            }
            // The presence tracker is left alone on purpose: it sees the card go, so putting it
            // back counts as a new arrival, while a card Windows mounts again on its own does not
            // start an automatic transfer.
            ResetSourceState();
            ShowMessage($"{label} ejected", "It is safe to remove the card.", InfoBarSeverity.Success);
            AddActivity($"Ejected {label}. Safe to remove.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception)
        {
            ShowError($"{label} could not be ejected", exception.Message);
            AddActivity($"Eject failed: {exception.Message}");
            await _logger.WriteAsync("Eject failed: " + exception);
        }
        finally
        {
            _busy = false;
            SetOperationControls(false, allowCancel: false);
            _lastScanSignature = null;
        }
    }

    private void UpdateCapacity(CardInfo? card)
    {
        if (card is null || card.TotalBytes <= 0)
        {
            CapacityText.Text = "—";
            CapacityUsedColumn.Width = new GridLength(0, GridUnitType.Star);
            CapacityFreeColumn.Width = new GridLength(100, GridUnitType.Star);
            CapacityBar.Opacity = 0.35;
            return;
        }

        double usedFraction = Math.Clamp((double)card.UsedBytes / card.TotalBytes, 0, 1);
        CapacityText.Text = $"{FormatBytes(card.UsedBytes)} / {FormatBytes(card.TotalBytes)}";
        CapacityUsedColumn.Width = new GridLength(usedFraction, GridUnitType.Star);
        CapacityFreeColumn.Width = new GridLength(1 - usedFraction, GridUnitType.Star);
        CapacityBar.Opacity = 1.0;
    }

    private void UpdateDisconnectedState()
    {
        ResetSessionDisplay();
        CardLabelText.Text = _selectedSourceRoot is null ? "No card connected" : "Source unavailable";
        CardDetailText.Text = _selectedSourceRoot ?? "Insert a camera card, or choose a folder.";
        CardStatsText.Text = "—";
        UpdateCapacity(null);
        UpdateCardContents([]);
        SessionTransferAgainButton.Content = "Scan for media";
        SessionTransferAgainButton.IsEnabled = !_busy && _destinationAvailable;
        WipeButton.IsEnabled = false;
        UpdateEjectButton();
        WipeDescriptionText.Text = "Locked until every file on the card has a verified copy.";
        UpdateEraseBadge(unlocked: false);
        SetTopStatus("Waiting for media", NeutralStatusBrush);
        ApplySessionFooter(null);
    }

    private void ResetSessionDisplay()
    {
        _operationStartedUtc = null;
        _operationEndedUtc = null;
        ResetProgressThrottle();
        UpdateSegmentedProgress(0, complete: false);
        PhaseText.Text = "STANDBY";
        PhaseText.Foreground = NeutralStatusBrush;
        PercentText.Text = "0%";
        CopiedText.Text = "—";
        SkippedText.Text = "—";
        ProcessedText.Text = "—";
        ThroughputText.Text = "—";
        ProcessedCaption.Text = "idle";
        ThroughputCaption.Text = "idle";
        ElapsedText.Text = "0:00";
    }

    private void UpdateCardContents(IReadOnlyList<MediaItem> media)
    {
        int jpeg = 0, raw = 0, other = 0, video = 0;
        foreach (MediaItem item in media)
        {
            switch (item.Kind)
            {
                case MediaKind.Jpeg: jpeg++; break;
                case MediaKind.Raw: raw++; break;
                case MediaKind.OtherPhoto: other++; break;
                case MediaKind.Video: video++; break;
            }
        }
        int total = jpeg + raw + other + video;

        JpegCountText.Text = total == 0 ? "—" : jpeg.ToString("N0");
        RawCountText.Text = total == 0 ? "—" : raw.ToString("N0");
        OtherCountText.Text = total == 0 ? "—" : other.ToString("N0");
        VideoCountText.Text = total == 0 ? "—" : video.ToString("N0");

        JpegSegmentColumn.Width = new GridLength(total == 0 ? 1 : jpeg, GridUnitType.Star);
        RawSegmentColumn.Width = new GridLength(total == 0 ? 1 : raw, GridUnitType.Star);
        OtherSegmentColumn.Width = new GridLength(total == 0 ? 1 : other, GridUnitType.Star);
        VideoSegmentColumn.Width = new GridLength(total == 0 ? 1 : video, GridUnitType.Star);
        CardContentsBar.Opacity = total == 0 ? 0.35 : 1.0;
    }

    private void UpdateEraseBadge(bool unlocked)
    {
        EraseLockedBadge.Visibility = unlocked ? Visibility.Collapsed : Visibility.Visible;
        EraseUnlockedBadge.Visibility = unlocked ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ApplySessionFooter(TransferSession? session, string idleMessage = "Waiting for camera media")
    {
        bool hasSession = session is not null;
        ReportButton.IsEnabled = !_busy && hasSession;
        SessionTransferAgainButton.IsEnabled = !_busy && _destinationAvailable && (_currentCard is null || _lastScannedMediaCount > 0);
        if (hasSession) SessionTransferAgainButton.Content = "Transfer again";
        _lastSessionFilePath = hasSession ? _stateStore.SessionFilePath(session!) : null;

        TransferRecord? lastRecord = session?.Files.LastOrDefault();
        if (session is null || lastRecord is null)
        {
            CurrentFileText.Text = idleMessage;
            return;
        }

        string destinationFolder = PathUtilities.RelativeDestinationFolder(session.DestinationRoot, lastRecord.DestinationPath);
        CurrentFileText.Text = $"LAST · {lastRecord.SourcePath} → {destinationFolder}";
    }

    private void OpenSessionReport()
    {
        if (_lastSessionFilePath is null || !File.Exists(_lastSessionFilePath))
        {
            ShowError("Report unavailable", "The saved transfer report can't be found.");
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{_lastSessionFilePath}\"") { UseShellExecute = true });
        }
        catch (Exception exception) when (exception is Win32Exception or IOException)
        {
            ShowError("Report unavailable", exception.Message);
        }
    }

    private void SetOperationControls(bool active, bool allowCancel)
    {
        CancelButton.Visibility = active && allowCancel ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.IsEnabled = active && allowCancel;
        AutoTransferToggle.IsEnabled = !active;
        GroupByDateToggle.IsEnabled = !active;
        NotificationsToggle.IsEnabled = !active;
        ActivityToggle.IsEnabled = !active;
        StartupToggle.IsEnabled = !active;
        ChangeDestinationButton.IsEnabled = !active;
        ChooseSourceButton.IsEnabled = !active;
        AutomaticSourceButton.IsEnabled = !active;
        OpenFolderButton.IsEnabled = !active && _destinationAvailable;
        foreach (RadioButton themeButton in ThemeButtons) themeButton.IsEnabled = !active;
        EjectButton.IsEnabled = !active && CanEject;
        SettingsButton.IsEnabled = !active;
        WipeButton.IsEnabled = !active && _sourceAllowsErase && _unverifiableFileCount == 0 &&
            _verifiedSession is { Files.Count: > 0 };
        ReportButton.IsEnabled = !active && _lastSessionFilePath is not null;
        SessionTransferAgainButton.IsEnabled = !active && _destinationAvailable && (_currentCard is null || _lastScannedMediaCount > 0);
        if (active) SessionTransferAgainButton.Content = "Transfer in progress";
        else if (_verifiedSession is not null) SessionTransferAgainButton.Content = "Transfer again";
        UpdateDestinationAction();
    }

    private void SetTopStatus(string text, Brush brush)
    {
        TopStatusText.Text = text.ToUpperInvariant();
        StatusDot.Fill = brush;
        _trayIcon?.SetTooltip($"Media Shuttle · {text}");
    }

    private void ShowMessage(string title, string message, InfoBarSeverity severity)
    {
        BannerTitleText.Text = title;
        BannerMessageText.Text = message;
        Color color = (severity switch
        {
            InfoBarSeverity.Success => VerifiedStatusBrush,
            InfoBarSeverity.Warning => WarningStatusBrush,
            InfoBarSeverity.Error => ErrorStatusBrush,
            _ => NeutralStatusBrush
        }).Color;
        BannerIconBox.Background = new SolidColorBrush(color);
        BannerAccentStrip.Fill = new SolidColorBrush(color);
        StatusBanner.BorderBrush = new SolidColorBrush(Color.FromArgb(82, color.R, color.G, color.B));
        StatusBanner.Background = new SolidColorBrush(Color.FromArgb(18, color.R, color.G, color.B));
        BannerIcon.Glyph = severity switch { InfoBarSeverity.Success => "\uE73E", InfoBarSeverity.Error => "\uE711", _ => "\uE946" };
        StatusInfoBar.Title = title;
        StatusInfoBar.Message = message;
        StatusInfoBar.Severity = severity;
        StatusInfoBar.IsOpen = true;
    }

    private void ShowError(string title, string message) => ShowMessage(title, message, InfoBarSeverity.Error);

    private void AddActivity(string message)
    {
        // The list is sized to fill whatever height the window has spare, which on a tall window is
        // far more than the six lines this used to keep. It scrolls, so the cap is only here to
        // stop an app that lives in the tray for weeks growing without bound.
        _activity.Insert(0, $"{DateTime.Now:h:mm:ss tt}  {message}");
        while (_activity.Count > MaximumActivityLines)
        {
            _activity.RemoveAt(_activity.Count - 1);
        }
    }

    private async Task ChooseSourceAsync()
    {
        if (IsVisualPreview) return;
        if (_busy) return;
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        Windows.Storage.StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (_busy || folder is null || string.IsNullOrWhiteSpace(folder.Path)) return;
        try
        {
            CardInfo source = CardDetector.GetSelectedSource(folder.Path);
            PathUtilities.EnsureDestinationOutsideSource(_destinationRoot, source.RootPath);
            _selectedSourceRoot = source.RootPath;
            _sourceAllowsErase = CardDetector.IsCameraCardVolume(source.RootPath);
            ResetSourceState();
            AutomaticSourceButton.Visibility = Visibility.Visible;
            AddActivity($"Source selected: {source.RootPath}");
            await ScanCardsAsync(force: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            ShowError("Source unavailable", exception.Message);
        }
    }

    private async Task UseAutomaticSourceAsync()
    {
        if (IsVisualPreview) return;
        if (_busy) return;
        _selectedSourceRoot = null;
        _sourceAllowsErase = true;
        _cardPresence = new CardPresenceTracker();
        ResetSourceState();
        AutomaticSourceButton.Visibility = Visibility.Collapsed;
        AddActivity("Automatic card detection enabled.");
        await ScanCardsAsync(force: true);
    }

    private void ResetSourceState()
    {
        _sourceVersion++;
        _currentCard = null;
        _verifiedSession = null;
        _lastScannedMediaCount = -1;
        _unverifiableFileCount = 0;
        _lastScanSignature = null;
        _operationStartedUtc = null;
        _operationEndedUtc = null;
        StatusInfoBar.IsOpen = false;
        UpdateDisconnectedState();
    }

    private async Task ChooseDestinationAsync()
    {
        if (IsVisualPreview) return;
        if (_busy)
        {
            return;
        }

        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.Desktop
        };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        Windows.Storage.StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (_busy || folder is null || string.IsNullOrWhiteSpace(folder.Path))
        {
            return;
        }

        string selectedPath;
        try
        {
            selectedPath = Path.GetFullPath(folder.Path);
        }
        catch (Exception exception) when (IsDestinationException(exception) || exception is ArgumentException)
        {
            ShowError("Destination unavailable", exception.Message);
            return;
        }

        if (_currentCard is not null && IsSameOrChild(selectedPath, _currentCard.RootPath))
        {
            ShowError("Unsafe destination", "Choose a folder that is not on the connected camera card.");
            return;
        }

        if (Directory.Exists(Path.Combine(selectedPath, "DCIM")) ||
            Directory.Exists(Path.Combine(selectedPath, "M4ROOT")) ||
            Directory.Exists(Path.Combine(selectedPath, "PRIVATE")))
        {
            ShowError(
                "Unsafe destination",
                "That folder looks like the top of a camera card. Choose a folder on this computer.");
            return;
        }

        try
        {
            if (_currentCard is not null)
                PathUtilities.EnsureDestinationOutsideSource(selectedPath, _currentCard.RootPath);
            else
                PathUtilities.EnsureNoLinks(selectedPath);
            EnsureDestinationRoot(selectedPath);
            _destinationRoot = selectedPath;
            _destinationAvailable = true;
            UpdateDestinationDisplay();
            OpenFolderButton.IsEnabled = true;
            _settings.DestinationRoot = _destinationRoot;
            await _stateStore.SaveSettingsAsync(_settings);
            AddActivity($"Destination changed to {_destinationRoot}");
            ShowMessage(
                "Destination changed",
                "New transfers go to this folder.",
                InfoBarSeverity.Success);
            await ScanCardsAsync(force: true);
        }
        catch (Exception exception) when (IsDestinationException(exception) || exception is InvalidOperationException)
        {
            ShowError("Destination unavailable", exception.Message);
        }
    }

    private async Task UpdateThemeAsync()
    {
        if (!_settingsReady || ThemeButtons.FirstOrDefault(button => button.IsChecked == true) is not RadioButton selected)
        {
            return;
        }

        string theme = selected.Tag?.ToString() ?? "System";
        if (theme == _settings.Theme)
        {
            return;
        }
        _settings.Theme = theme;
        ApplyTheme(theme);
        await _stateStore.SaveSettingsAsync(_settings);
    }

    private RadioButton[] ThemeButtons => [ThemeSystemButton, ThemeLightButton, ThemeDarkButton];

    private void SelectThemeButton(string theme)
    {
        foreach (RadioButton button in ThemeButtons)
        {
            button.IsChecked = string.Equals(button.Tag?.ToString(), theme, StringComparison.Ordinal);
        }
        if (ThemeButtons.All(button => button.IsChecked != true))
        {
            ThemeSystemButton.IsChecked = true;
        }
    }

    private void ApplyTheme(string theme)
    {
        Root.RequestedTheme = theme switch
        {
            "Light" => ElementTheme.Light,
            "Dark" => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
        UpdateTitleBarColors();
    }

    private void UpdateTitleBarColors()
    {
        bool isLight = Root.ActualTheme == ElementTheme.Light;
        Color foreground = isLight
            ? Color.FromArgb(255, 31, 31, 31)
            : Color.FromArgb(255, 255, 255, 255);
        Color inactiveForeground = isLight
            ? Color.FromArgb(153, 31, 31, 31)
            : Color.FromArgb(166, 255, 255, 255);

        _appWindow.TitleBar.ButtonForegroundColor = foreground;
        _appWindow.TitleBar.ButtonHoverForegroundColor = foreground;
        _appWindow.TitleBar.ButtonPressedForegroundColor = foreground;
        _appWindow.TitleBar.ButtonInactiveForegroundColor = inactiveForeground;
        _appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonHoverBackgroundColor = isLight
            ? Color.FromArgb(20, 0, 0, 0)
            : Color.FromArgb(28, 255, 255, 255);
        _appWindow.TitleBar.ButtonPressedBackgroundColor = isLight
            ? Color.FromArgb(36, 0, 0, 0)
            : Color.FromArgb(48, 255, 255, 255);
    }

    /// <summary>
    /// Create the default destination on first use or a folder the user explicitly selected.
    /// Startup checks a saved destination without recreating one the user removed.
    /// </summary>
    private static void EnsureDestinationRoot(string destinationRoot) =>
        Directory.CreateDirectory(destinationRoot);

    private static bool IsDestinationException(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or NotSupportedException;

    private void UpdateDestinationDisplay()
    {
        DestinationText.Text = _destinationRoot;
        DestinationText.SetValue(ToolTipService.ToolTipProperty, _destinationRoot);
        DestinationWarningText.Visibility = _destinationAvailable ? Visibility.Collapsed : Visibility.Visible;
        ChangeDestinationButton.Content = _destinationAvailable ? "Change" : "Choose folder";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            SessionTransferAgainButton, _destinationAvailable
                ? "Transfer and verify media"
                : "Choose destination folder to enable transfer");
        UpdateDestinationAction();
    }

    private void UpdateDestinationAction()
    {
        if (_destinationAvailable || _busy) return;
        SessionTransferAgainButton.Content = "Choose destination";
        SessionTransferAgainButton.IsEnabled = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            SessionTransferAgainButton, "Choose destination folder to enable transfer");
    }

    private static string DefaultDestinationRoot() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Camera");

    private static bool IsSameOrChild(string candidate, string parent)
    {
        string normalizedCandidate = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar);
        string normalizedParent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar);
        return normalizedCandidate.Equals(normalizedParent, StringComparison.OrdinalIgnoreCase) ||
               normalizedCandidate.StartsWith(normalizedParent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private void OpenDestinationFolder()
    {
        if (!_destinationAvailable)
        {
            ShowError("Destination unavailable", "Choose a destination folder first.");
            return;
        }

        try
        {
            if (!Directory.Exists(_destinationRoot))
            {
                throw new DirectoryNotFoundException($"Destination is missing: {_destinationRoot}");
            }
            Process.Start(new ProcessStartInfo(_destinationRoot) { UseShellExecute = true });
        }
        catch (Exception exception) when (
            IsDestinationException(exception) || exception is Win32Exception)
        {
            _destinationAvailable = false;
            UpdateDestinationDisplay();
            SetOperationControls(false, allowCancel: false);
            ShowError("Destination unavailable", exception.Message);
            AddActivity("Destination unavailable: " + exception.Message);
            SetTopStatus("Choose a destination", ErrorStatusBrush);
        }
    }

    private void ShowWindow()
    {
        if (_placementPending)
        {
            _placementPending = false;
            SizeAndCenterWindow(_windowHandle);
        }
        _appWindow.Show();
        Activate();
        NativeMethods.ActivateWindow(_windowHandle);
    }

    private void ExitApplication()
    {
        if (_busy)
        {
            ShowWindow();
            ShowMessage(
                "Still working",
                "Wait for the transfer or erase to finish, or cancel the transfer, before quitting.",
                InfoBarSeverity.Warning);
            return;
        }

        _allowClose = true;
        _scanTimer.Stop();
        _trayIcon.Dispose();
        _appWindow.Destroy();
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose)
        {
            return;
        }
        args.Cancel = true;
        _appWindow.Hide();
        ShowNotification("Media Shuttle is still running", "It keeps watching for cards. Click the icon in the notification area to open it.");
    }

    private void ShowNotification(string title, string message)
    {
        if (!_settings.ShowNotifications)
        {
            return;
        }
        _trayIcon.ShowNotification(title, message);
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = Math.Max(0, bytes);
        int unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return unit == 0 ? $"{value:0} {units[unit]}" : $"{value:0.0} {units[unit]}";
    }
}
