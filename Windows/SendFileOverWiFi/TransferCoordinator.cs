using System.Security.Cryptography;

namespace SendFileOverWiFi;

/// <summary>Coordinates UI state with the protocol transport. One instance owns at most one receive or send session.</summary>
internal sealed class TransferCoordinator
{
    private readonly AppSettings settings;
    private readonly Action<string> receiveStatus;
    private readonly Action<string> sendStatus;
    private readonly Func<string, Task<bool>> confirmPairing;
    private readonly Func<string, Task<bool>> confirmOffer;
    private readonly Func<IReadOnlyList<DiscoveredRecipient>, Task<DiscoveredRecipient?>> chooseRecipient;
    private CancellationTokenSource? receiverCancellation;

    public TransferCoordinator(AppSettings settings, Action<string> receiveStatus, Action<string> sendStatus, Func<string, Task<bool>> confirmPairing, Func<string, Task<bool>> confirmOffer, Func<IReadOnlyList<DiscoveredRecipient>, Task<DiscoveredRecipient?>> chooseRecipient)
    {
        this.settings = settings; this.receiveStatus = receiveStatus; this.sendStatus = sendStatus; this.confirmPairing = confirmPairing; this.confirmOffer = confirmOffer; this.chooseRecipient = chooseRecipient;
    }

    public Task StartReceiverAsync()
    {
        if (receiverCancellation is not null) return Task.CompletedTask;
        receiverCancellation = new CancellationTokenSource();
        // The listener and DNS-SD registration are owned by WindowsProtocolHost.
        // It publishes a new eight-byte token for every receiver session.
        return WindowsProtocolHost.Instance.StartReceivingAsync(settings, receiverCancellation.Token, receiveStatus, confirmPairing, confirmOffer);
    }

    public void StopReceiver()
    {
        receiverCancellation?.Cancel(); receiverCancellation?.Dispose(); receiverCancellation = null;
        WindowsProtocolHost.Instance.StopReceiving();
    }

    public async Task SendAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) throw new InvalidOperationException("Выберите файлы для отправки");
        sendStatus("Поиск получателя");
        try { await WindowsProtocolHost.Instance.SendAsync(settings, paths, sendStatus, chooseRecipient); }
        catch (Exception error) { DebugLog.Error("outgoing TLS or transfer", error); throw; }
    }

    public void ClearPausedTransfer() => WindowsProtocolHost.Instance.ClearPausedTransfer();

    public bool HasPendingOutgoing => settings.PendingOutgoing is not null;
    public bool HasPausedIncoming => WindowsProtocolHost.Instance.HasPausedIncoming();
    public PausedIncomingTransferInfo? PausedIncomingInfo => WindowsProtocolHost.Instance.PausedIncomingInfo();
    public Task ResumeAsync() => WindowsProtocolHost.Instance.ResumeAsync(settings, sendStatus, chooseRecipient);
    public Task CancelOutgoingAsync() => WindowsProtocolHost.Instance.CancelOutgoingAsync(settings, sendStatus, chooseRecipient);
}
