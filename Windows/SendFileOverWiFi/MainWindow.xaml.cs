using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI;
using System.Diagnostics;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace SendFileOverWiFi;

public sealed partial class MainWindow : Window
{
    private readonly List<string> selectedFiles = [];
    private readonly AppSettings settings = AppSettings.Load();
    private readonly TransferCoordinator transfer;
    private bool receiverRunning;
    private bool? horizontalLayout;
    private string? lastReceiveError;
    private string? lastSendError;
    private bool hasSuccessfulSendResult;

    public MainWindow()
    {
        InitializeComponent();
        AppLocalization.Configure(settings.Language);
        transfer = new TransferCoordinator(settings, UpdateReceive, UpdateSend, ShowPairingAsync, ShowOfferAsync, ChooseRecipientAsync);
        Closed += (_, _) => transfer.StopReceiver();
        ApplyTheme();
        ApplyLocalization();
        if (transfer.HasPendingOutgoing) ShowPendingOutgoing();
        if (transfer.PausedIncomingInfo is { } paused) ShowPausedIncoming(paused);
    }

    private void ApplyTheme()
    {
        Root.RequestedTheme = settings.Theme switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };
    }

    private void ApplyLocalization()
    {
        VersionLabel.Text = "v" + (typeof(MainWindow).Assembly.GetName().Version?.ToString(2) ?? "1.0");
        ((TextBlock)((StackPanel)SettingsButton.Content).Children[1]).Text = AppLocalization.T("settings");
        ReceiveTitle.Text = AppLocalization.T("receive"); SendTitle.Text = AppLocalization.T("send");
        ReceiveButton.Content = AppLocalization.T("receiveButton"); FindButton.Content = AppLocalization.T("findRecipient");
        FilesButton.Content = AppLocalization.T("chooseFiles");
        ViewFilesButton.Content = AppLocalization.T("view"); ClearReceiveButton.Content = AppLocalization.T("clear");
        CopyReceiveErrorButton.Content = CopySendErrorButton.Content = AppLocalization.T("copyError");
        ResumeButton.Content = AppLocalization.T("resume"); CancelOutgoingButton.Content = AppLocalization.T("cancel");
        if (ReceiveStatus.Text == "Готово") ReceiveStatus.Text = AppLocalization.T("ready");
        if (SendStatus.Text == "Выберите файлы для отправки") SendStatus.Text = AppLocalization.T("selectFiles");
    }

    private async void Receive_Click(object sender, RoutedEventArgs e)
    {
        if (receiverRunning)
        {
            transfer.StopReceiver();
            if (transfer.PausedIncomingInfo is { } interrupted) ShowPausedIncoming(interrupted);
            else SetReceiver(false, AppLocalization.T("ready"));
            return;
        }
        if (!await EnsureDisplayNameAsync()) return;
        var pausedInfo = transfer.PausedIncomingInfo;
        var resumable = pausedInfo is not null;
        if (!resumable) ClearCompletedReceiveResult();
        try { await transfer.StartReceiverAsync(); SetReceiver(true, resumable ? PausedStatus(pausedInfo!) + "\n" + AppLocalization.T("wifiAvailable") : AppLocalization.T("wifiAvailable") + "\n" + AppLocalization.T("waitingSender")); }
        catch (Exception error) { SetReceiveError(error); SetReceiver(false, AppLocalization.T("error")); }
    }

    private void ClearCompletedReceiveResult()
    {
        ReceiveStatus.Text = AppLocalization.T("ready");
        ReceiveStatus.ClearValue(TextBlock.ForegroundProperty);
        ViewFilesButton.Visibility = Visibility.Collapsed;
        ClearReceiveButton.Visibility = Visibility.Collapsed;
        ReceiveCleanupInfoButton.Visibility = Visibility.Collapsed;
        CopyReceiveErrorButton.Visibility = Visibility.Collapsed;
        lastReceiveError = null;
    }

    private void SetReceiver(bool active, string status)
    {
        receiverRunning = active; ReceiveRadar.IsActive = active; ReceiveRadar.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        ReceiveButton.Content = active ? AppLocalization.T("stop") : AppLocalization.T("receiveButton"); ReceiveStatus.ClearValue(TextBlock.ForegroundProperty); ReceiveStatus.Text = status;
    }

    private async void Files_Click(object sender, RoutedEventArgs e) => await PickFilesAsync(["*"]);

    private async Task PickFilesAsync(IEnumerable<string> fileTypes)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        foreach (var type in fileTypes) picker.FileTypeFilter.Add(type);
        var files = await picker.PickMultipleFilesAsync();
        var oldCount = selectedFiles.Count;
        foreach (var file in files) if (!selectedFiles.Contains(file.Path)) selectedFiles.Add(file.Path);
        if (selectedFiles.Count > oldCount && hasSuccessfulSendResult) { hasSuccessfulSendResult = false; CopySendErrorButton.Visibility = Visibility.Collapsed; lastSendError = null; }
        RefreshSendSelection();
    }

    private void ClearSelected_Click(object sender, RoutedEventArgs e) { selectedFiles.Clear(); RefreshSendSelection(); }

    private void RefreshSendSelection(bool updateStatus = true)
    {
        var selected = selectedFiles.Count > 0;
        FindButton.IsEnabled = selected; PickerButtons.Visibility = selected ? Visibility.Collapsed : Visibility.Visible;
        SelectedActions.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        ClearSelectedButton.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        if (updateStatus) { SendStatus.ClearValue(TextBlock.ForegroundProperty); SendStatus.Text = selected ? AppLocalization.Format("selectedFiles", selectedFiles.Count) : AppLocalization.T("selectFiles"); }
    }

    private async void Find_Click(object sender, RoutedEventArgs e)
    {
        if (!await EnsureDisplayNameAsync()) return;
        SendRadar.Visibility = Visibility.Visible; SendRadar.IsActive = true; SendStatus.ClearValue(TextBlock.ForegroundProperty); SendStatus.Text = AppLocalization.T("searchRecipient");
        try { await transfer.SendAsync(selectedFiles); selectedFiles.Clear(); RefreshSendSelection(false); }
        catch (Exception error)
        {
            SetSendError(error);
            if (transfer.HasPendingOutgoing) ShowPendingOutgoing();
            else SendStatus.Text = error is ProtocolException ? error.Message : AppLocalization.T("transferError");
        }
        finally { SendRadar.IsActive = false; SendRadar.Visibility = Visibility.Collapsed; }
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = AppLocalization.T("settings"), PrimaryButtonText = AppLocalization.T("save"), CloseButtonText = AppLocalization.T("cancel") };
        var name = new TextBox { Header = AppLocalization.T("settingsDisplayName"), Text = settings.DisplayName };
        var folder = new TextBox { Header = AppLocalization.T("downloadFolder"), Text = settings.ReceiveDirectory };
        var theme = new ComboBox { Header = AppLocalization.T("theme"), ItemsSource = new[] { AppLocalization.T("systemTheme"), AppLocalization.T("darkTheme"), AppLocalization.T("lightTheme") }, SelectedIndex = settings.Theme is "dark" ? 1 : settings.Theme is "light" ? 2 : 0 };
        var language = new ComboBox { Header = AppLocalization.T("language"), ItemsSource = new[] { "en", "ru", "it", "es", "pt", "cn" }.Select(code => new KeyValuePair<string, string>(code, AppLocalization.LanguageName(code))).ToList(), DisplayMemberPath = "Value", SelectedValuePath = "Key", SelectedValue = settings.Language };
        var dates = new ToggleSwitch { Header = AppLocalization.T("saveDates"), IsOn = settings.PreserveDates };
        var trustedTitle = new TextBlock { Text = AppLocalization.T("trustedDevicesTitle"), FontSize = 18 };
        var trustedEntries = settings.TrustedDevices.ToList();
        var trustedList = new ListView { SelectionMode = ListViewSelectionMode.Single, MinHeight = 96, MaxHeight = 220 };
        trustedList.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        void RefreshTrustedList()
        {
            trustedEntries = settings.TrustedDevices.ToList();
            trustedList.ItemsSource = trustedEntries.Count == 0 ? new[] { AppLocalization.T("trustedDevicesEmpty") } : trustedEntries.Select(entry => entry.Value).ToList();
        }
        var deleteTrusted = new Button { Content = AppLocalization.T("delete"), IsEnabled = false };
        trustedList.SelectionChanged += (_, _) => deleteTrusted.IsEnabled = trustedEntries.Count > 0 && trustedList.SelectedIndex >= 0;
        deleteTrusted.Click += (_, _) =>
        {
            if (trustedList.SelectedIndex < 0 || trustedList.SelectedIndex >= trustedEntries.Count) return;
            settings.TrustedDevices.Remove(trustedEntries[trustedList.SelectedIndex].Key);
            settings.Save();
            RefreshTrustedList();
            deleteTrusted.IsEnabled = false;
        };
        RefreshTrustedList();
        var trustedSection = new StackPanel { Spacing = 8, Children = { trustedTitle, trustedList, deleteTrusted } };
        var settingsContent = new StackPanel { Spacing = 12, Children = { name, folder, theme, language, dates, trustedSection } };
        // Small windows must retain access to every setting and all trusted
        // device rows rather than clipping the bottom of the dialog.
        dialog.Content = new ScrollViewer
        {
            Content = settingsContent,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            MaxHeight = Math.Max(260, Content.XamlRoot.Size.Height - 180)
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            settings.DisplayName = name.Text.Trim(); settings.ReceiveDirectory = folder.Text.Trim(); settings.Theme = theme.SelectedIndex switch { 1 => "dark", 2 => "light", _ => "system" }; settings.Language = language.SelectedValue?.ToString() ?? ""; settings.PreserveDates = dates.IsOn; settings.Save(); AppLocalization.Configure(settings.Language); ApplyTheme(); ApplyLocalization();
        }
    }

    private async Task<bool> EnsureDisplayNameAsync()
    {
        if (!string.IsNullOrWhiteSpace(settings.DisplayName)) return true;
        var name = new TextBox { Header = AppLocalization.T("settingsDisplayName"), MinWidth = 280 };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = AppLocalization.T("deviceNameRequired"),
            Content = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = AppLocalization.T("deviceNamePrompt"), TextWrapping = TextWrapping.Wrap }, name } },
            PrimaryButtonText = AppLocalization.T("continue"),
            CloseButtonText = AppLocalization.T("cancel"),
            RequestedTheme = DialogTheme()
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text)) return false;
        settings.DisplayName = name.Text.Trim();
        settings.Save();
        return true;
    }

    private void YourFiles_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(settings.ReceiveDirectory);
        Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"\"{settings.ReceiveDirectory.Replace("\"", "\"\"")}\"", UseShellExecute = true });
    }

    private async Task ShowTrustedDevicesAsync()
    {
        var entries = settings.TrustedDevices.ToList();
        if (entries.Count == 0)
        {
            await new ContentDialog { XamlRoot = Content.XamlRoot, Title = AppLocalization.T("trustedDevicesTitle"), Content = AppLocalization.T("trustedDevicesEmpty"), CloseButtonText = AppLocalization.T("done"), RequestedTheme = DialogTheme() }.ShowAsync();
            return;
        }
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, ItemsSource = entries.Select(entry => entry.Value).ToList(), MinWidth = 280 };
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = AppLocalization.T("trustedDevicesTitle"), Content = list, PrimaryButtonText = AppLocalization.T("delete"), CloseButtonText = AppLocalization.T("done"), IsPrimaryButtonEnabled = false, RequestedTheme = DialogTheme() };
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedIndex >= 0;
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && list.SelectedIndex >= 0)
        {
            settings.TrustedDevices.Remove(entries[list.SelectedIndex].Key); settings.Save();
            await ShowTrustedDevicesAsync();
        }
    }

    private void ClearReceive_Click(object sender, RoutedEventArgs e)
    {
        transfer.ClearPausedTransfer();
        ClearCompletedReceiveResult();
    }
    private async void ReceiveCleanupInfo_Click(object sender, RoutedEventArgs e) => await new ContentDialog
    {
        XamlRoot = Content.XamlRoot,
        Title = AppLocalization.T("cleanupTitle"),
        Content = AppLocalization.T("cleanupInfo"),
        CloseButtonText = AppLocalization.T("understood"),
        RequestedTheme = DialogTheme()
    }.ShowAsync();
    private async void Resume_Click(object sender, RoutedEventArgs e)
    {
        try { PendingSendActions.Visibility = Visibility.Collapsed; SendStatus.Text = AppLocalization.T("resume") + ": " + AppLocalization.T("searchRecipient"); await transfer.ResumeAsync(); }
        catch (Exception error) { SetSendError(error); SendStatus.Text = transfer.HasPendingOutgoing ? AppLocalization.T("paused") + "\n" + AppLocalization.T("connectionLost") : error.Message; if (transfer.HasPendingOutgoing) ShowPendingOutgoing(); }
    }
    private async void CancelOutgoing_Click(object sender, RoutedEventArgs e)
    {
        try { await transfer.CancelOutgoingAsync(); PendingSendActions.Visibility = Visibility.Collapsed; SendStatus.Text = AppLocalization.T("cancel"); }
        catch (Exception error) { SetSendError(error); SendStatus.Text = AppLocalization.T("transferError"); if (transfer.HasPendingOutgoing) ShowPendingOutgoing(); }
    }
    private void ShowPendingOutgoing()
    {
        PendingSendActions.Visibility = Visibility.Visible;
        SendStatus.Text = AppLocalization.T("paused") + "\n" + AppLocalization.T("connectionLost");
    }
    private static string PausedStatus(PausedIncomingTransferInfo info) => AppLocalization.T("paused") + "\n" + AppLocalization.Format("resumeProgress", info.CurrentFile, info.FileCount, info.ConfirmedBytes, info.TotalBytes);
    private void ShowPausedIncoming(PausedIncomingTransferInfo info)
    {
        receiverRunning = false; ReceiveRadar.IsActive = false; ReceiveRadar.Visibility = Visibility.Collapsed;
        ReceiveButton.Content = AppLocalization.T("receiveButton");
        ReceiveStatus.ClearValue(TextBlock.ForegroundProperty); ReceiveStatus.Text = PausedStatus(info);
        ClearReceiveButton.Visibility = Visibility.Visible;
        ReceiveCleanupInfoButton.Visibility = Visibility.Visible;
    }
    private void UpdateReceive(string text) => DispatcherQueue.TryEnqueue(() =>
    {
        ReceiveStatus.Text = text;
        var success = text.StartsWith(AppLocalization.T("success"), StringComparison.Ordinal);
        if (success) ReceiveStatus.Foreground = new SolidColorBrush(Colors.ForestGreen);
        else ReceiveStatus.ClearValue(TextBlock.ForegroundProperty);
        if (text.StartsWith(AppLocalization.T("paused"), StringComparison.Ordinal) && transfer.PausedIncomingInfo is { } paused) ShowPausedIncoming(paused);
        if (success)
        {
            receiverRunning = false; ReceiveRadar.IsActive = false; ReceiveRadar.Visibility = Visibility.Collapsed;
            ReceiveButton.Content = AppLocalization.T("receiveAgain"); ViewFilesButton.Visibility = Visibility.Visible;
        }
    });
    private void UpdateSend(string text) => DispatcherQueue.TryEnqueue(() =>
    {
        hasSuccessfulSendResult = text.StartsWith(AppLocalization.T("success"), StringComparison.Ordinal);
        SendStatus.Text = text;
        if (hasSuccessfulSendResult) SendStatus.Foreground = new SolidColorBrush(Colors.ForestGreen);
        else SendStatus.ClearValue(TextBlock.ForegroundProperty);
    });
    private Task<bool> ShowPairingAsync(string code) => PromptAsync(AppLocalization.T("pairingCode"), $"{code}\n\n{AppLocalization.T("compareCode")}", AppLocalization.T("yes"), AppLocalization.T("no"));
    private Task<bool> ShowOfferAsync(string detail) => PromptAsync(AppLocalization.T("acceptFiles"), detail, AppLocalization.T("accept"), AppLocalization.T("decline"));
    private Task<DiscoveredRecipient?> ChooseRecipientAsync(IReadOnlyList<DiscoveredRecipient> recipients)
    {
        var completion = new TaskCompletionSource<DiscoveredRecipient?>();
        DispatcherQueue.TryEnqueue(async () =>
        {
            var list = new ListView { SelectionMode = ListViewSelectionMode.Single, ItemsSource = recipients.Select(item => item.Name).ToList(), MinWidth = 260 };
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = AppLocalization.T("foundDevices"), Content = list, PrimaryButtonText = AppLocalization.T("choose"), CloseButtonText = AppLocalization.T("cancel"), IsPrimaryButtonEnabled = false, RequestedTheme = DialogTheme() };
            list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedIndex >= 0;
            try { completion.TrySetResult(await dialog.ShowAsync() == ContentDialogResult.Primary && list.SelectedIndex >= 0 ? recipients[list.SelectedIndex] : null); }
            catch (Exception error) { completion.TrySetException(error); }
        });
        return completion.Task;
    }
    private Task<bool> PromptAsync(string title, string detail, string yes, string no)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        // The TLS listener runs off the UI thread. Do not leave that listener
        // waiting forever if the window's dispatcher is no longer available.
        if (!DispatcherQueue.TryEnqueue(() => ShowPromptOnUiAsync(title, detail, yes, no, completion)))
            completion.TrySetException(new InvalidOperationException("Окно подтверждения недоступно"));
        return completion.Task;
    }

    private async void ShowPromptOnUiAsync(string title, string detail, string yes, string no, TaskCompletionSource<bool> completion)
    {
        try
        {
            var accepted = false;
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = title, RequestedTheme = DialogTheme() };
            var noButton = new Button { Content = no, MinHeight = 48, MinWidth = 120, Background = new SolidColorBrush(Colors.IndianRed), Foreground = new SolidColorBrush(Colors.White) };
            var yesButton = new Button { Content = yes, MinHeight = 48, MinWidth = 120, Background = new SolidColorBrush(Colors.ForestGreen), Foreground = new SolidColorBrush(Colors.White) };
            noButton.Click += (_, _) => dialog.Hide();
            yesButton.Click += (_, _) => { accepted = true; dialog.Hide(); };
            dialog.Content = new StackPanel { Spacing = 20, Children = { new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap }, new Grid { ColumnDefinitions = { new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }, new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) } }, Children = { noButton, yesButton } } } };
            var actions = ((Grid)((StackPanel)dialog.Content).Children[1]);
            Grid.SetColumn(yesButton, 1);
            noButton.HorizontalAlignment = HorizontalAlignment.Left;
            yesButton.HorizontalAlignment = HorizontalAlignment.Right;
            await dialog.ShowAsync();
            completion.TrySetResult(accepted);
        }
        catch (Exception error) { completion.TrySetException(error); }
    }

    private ElementTheme DialogTheme() => settings.Theme switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };

    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var horizontal = e.NewSize.Width > e.NewSize.Height;
        if (horizontalLayout == horizontal) return;
        horizontalLayout = horizontal;
        WorkLayout.RowDefinitions.Clear(); WorkLayout.ColumnDefinitions.Clear();
        if (horizontal)
        {
            WorkLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            WorkLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            WorkLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(ReceiveCard, 0); Grid.SetColumn(ReceiveCard, 0); Grid.SetRow(SendCard, 0); Grid.SetColumn(SendCard, 1);
            WorkScroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto; WorkScroller.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        }
        else
        {
            WorkLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); WorkLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            WorkLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(ReceiveCard, 0); Grid.SetColumn(ReceiveCard, 0); Grid.SetRow(SendCard, 1); Grid.SetColumn(SendCard, 0);
            WorkScroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled; WorkScroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        }
    }

    private void SetReceiveError(Exception error)
    {
        lastReceiveError = TechnicalError(error); CopyReceiveErrorButton.Visibility = Visibility.Visible;
    }

    private void SetSendError(Exception error)
    {
        lastSendError = TechnicalError(error); CopySendErrorButton.Visibility = Visibility.Visible;
    }

    private static string TechnicalError(Exception error) => $"{error.GetType().Name}; HRESULT=0x{error.HResult:X8}";

    private void CopyReceiveError_Click(object sender, RoutedEventArgs e) => CopyToClipboard(lastReceiveError);
    private void CopySendError_Click(object sender, RoutedEventArgs e) => CopyToClipboard(lastSendError);
    private static void CopyToClipboard(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package);
    }
}
