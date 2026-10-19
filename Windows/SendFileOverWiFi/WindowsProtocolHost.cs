using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Org.BouncyCastle.Tls;

namespace SendFileOverWiFi;

/// <summary>Owns the Windows local-network listener, mDNS publication and TLS v1 handshakes.</summary>
internal sealed class WindowsProtocolHost
{
    internal static WindowsProtocolHost Instance { get; } = new();

    private readonly object gate = new();
    private TcpListener? listener;
    private DnsSdDiscovery? discovery;
    private CancellationTokenSource? cancellation;
    private BouncyTlsIdentity? identity;
    private ReceiverTransferStore? store;
    private readonly Timer expiryCleanup = new(_ => ReceiverTransferStore.CleanupExpiredTransfer(), null, TimeSpan.Zero, TimeSpan.FromMinutes(15));

    internal Task StartReceivingAsync(AppSettings settings, CancellationToken token, Action<string> status, Func<string, Task<bool>> confirmPairing, Func<string, Task<bool>> confirmOffer)
    {
        lock (gate)
        {
            if (listener is not null) return Task.CompletedTask;
            ReceiverTransferStore.CleanupExpiredTransfer();
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
            identity = new BouncyTlsIdentity(DeviceIdentity.LoadOrCreate());
            store = new ReceiverTransferStore(settings);
            listener = new TcpListener(IPAddress.Any, 0);
            listener.Start();
            var sessionToken = NewToken();
            discovery = new DnsSdDiscovery();
            discovery.Advertise(settings.DisplayName, ((IPEndPoint)listener.LocalEndpoint).Port, sessionToken);
            _ = AcceptLoopAsync(listener, cancellation.Token, sessionToken, settings, status, confirmPairing, confirmOffer);
        }
        return Task.CompletedTask;
    }

    internal void StopReceiving()
    {
        lock (gate)
        {
            cancellation?.Cancel(); cancellation?.Dispose(); cancellation = null;
            listener?.Stop(); listener = null;
            discovery?.Dispose(); discovery = null;
            store = null;
        }
    }

    internal async Task SendAsync(AppSettings settings, IReadOnlyList<string> paths, Action<string> status, Func<IReadOnlyList<DiscoveredRecipient>, Task<DiscoveredRecipient?>> chooseRecipient)
    {
        if (paths.Count == 0) throw new InvalidOperationException("Выберите файлы для отправки");
        using var finder = new DnsSdDiscovery();
        var recipients = await finder.BrowseAsync(CancellationToken.None);
        if (recipients.Count == 0) throw new ProtocolException(AppLocalization.T("recipientNotFound"));
        var recipient = await chooseRecipient(recipients) ?? throw new OperationCanceledException("Поиск получателя отменён");
        status($"Подключение к {recipient.Name}");
        using var client = new TcpClient(AddressFamily.InterNetwork);
        await client.ConnectAsync(recipient.Address, recipient.Port);
        var localIdentity = new BouncyTlsIdentity(DeviceIdentity.LoadOrCreate());
        var tls = new TlsClientProtocol(client.GetStream());
        var peer = new SendFileTlsClient(localIdentity);
        tls.Connect(peer);
        if (string.IsNullOrEmpty(peer.Sas)) throw new InvalidOperationException("Не удалось получить код сопряжения TLS");
        var known = !string.IsNullOrWhiteSpace(peer.PeerFingerprint) && settings.TrustedDevices.ContainsKey(peer.PeerFingerprint);
        status(known ? AppLocalization.T("waitingConsent") : AppLocalization.Format("pairing", peer.Sas) + "\n" + AppLocalization.T("waitingConsent"));
        var connection = new HttpConnection(tls.Stream);
        await new OutgoingTransferClient(settings, recipient, status).SendAsync(connection, paths, peer.PeerFingerprint ?? throw new InvalidOperationException("Не удалось подтвердить получателя"), CancellationToken.None);
        if (!string.IsNullOrWhiteSpace(peer.PeerFingerprint)) { settings.TrustedDevices[peer.PeerFingerprint] = recipient.Name; settings.Save(); }
        tls.Close();
    }

    internal async Task ResumeAsync(AppSettings settings, Action<string> status, Func<IReadOnlyList<DiscoveredRecipient>, Task<DiscoveredRecipient?>> chooseRecipient)
    {
        var pending = settings.PendingOutgoing ?? throw new InvalidOperationException("Нет передачи для докачки");
        using var finder = new DnsSdDiscovery();
        var recipients = await finder.BrowseAsync(CancellationToken.None);
        if (recipients.Count == 0) throw new ProtocolException(AppLocalization.T("recipientNotFound"));
        var recipient = await chooseRecipient(recipients) ?? throw new OperationCanceledException("Поиск получателя отменён");
        using var client = new TcpClient(AddressFamily.InterNetwork);
        await client.ConnectAsync(recipient.Address, recipient.Port);
        var tls = new TlsClientProtocol(client.GetStream());
        var peer = new SendFileTlsClient(new BouncyTlsIdentity(DeviceIdentity.LoadOrCreate()));
        tls.Connect(peer);
        if (!string.Equals(peer.PeerFingerprint, pending.ReceiverFingerprint, StringComparison.Ordinal)) throw new InvalidOperationException("Не удалось подтвердить доверенное устройство");
        status("Докачка");
        await new OutgoingTransferClient(settings, recipient, status).ResumeAsync(new HttpConnection(tls.Stream), pending, CancellationToken.None);
        tls.Close();
    }

    internal async Task CancelOutgoingAsync(AppSettings settings, Action<string> status, Func<IReadOnlyList<DiscoveredRecipient>, Task<DiscoveredRecipient?>> chooseRecipient)
    {
        var pending = settings.PendingOutgoing;
        if (pending is null) return;
        try
        {
            using var finder = new DnsSdDiscovery();
            var recipients = await finder.BrowseAsync(CancellationToken.None);
            var recipient = recipients.Count == 1 ? recipients[0] : await chooseRecipient(recipients);
            if (recipient is not null)
            {
                using var client = new TcpClient(AddressFamily.InterNetwork);
                await client.ConnectAsync(recipient.Address, recipient.Port);
                var tls = new TlsClientProtocol(client.GetStream());
                var peer = new SendFileTlsClient(new BouncyTlsIdentity(DeviceIdentity.LoadOrCreate()));
                tls.Connect(peer);
                if (string.Equals(peer.PeerFingerprint, pending.ReceiverFingerprint, StringComparison.Ordinal)) await new OutgoingTransferClient(settings, recipient, status).CancelAsync(new HttpConnection(tls.Stream), pending, CancellationToken.None);
                tls.Close();
            }
        }
        finally { settings.PendingOutgoing = null; settings.Save(); }
    }

    internal void ClearPausedTransfer()
    {
        lock (gate)
        {
            store?.Clear();
            ReceiverTransferStore.ClearPersistedTransfer();
        }
    }
    internal bool HasPausedIncoming() => ReceiverTransferStore.HasRecoverableTransfer();
    internal PausedIncomingTransferInfo? PausedIncomingInfo() => ReceiverTransferStore.GetRecoverableTransfer();

    private async Task AcceptLoopAsync(TcpListener activeListener, CancellationToken token, string sessionToken, AppSettings settings, Action<string> status, Func<string, Task<bool>> confirmPairing, Func<string, Task<bool>> confirmOffer)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await activeListener.AcceptTcpClientAsync(token);
                _ = HandleConnectionAsync(client, token, sessionToken, settings, status, confirmPairing, confirmOffer);
            }
        }
        catch (OperationCanceledException) { }
        catch (SocketException error) when (!token.IsCancellationRequested) { status(error.Message); }
    }

    private async Task HandleConnectionAsync(TcpClient client, CancellationToken token, string sessionToken, AppSettings settings, Action<string> status, Func<string, Task<bool>> confirmPairing, Func<string, Task<bool>> confirmOffer)
    {
        using (client)
        {
            try
            {
                var localIdentity = identity ?? throw new InvalidOperationException("TLS identity unavailable");
                var tls = new TlsServerProtocol(client.GetStream());
                var peer = new SendFileTlsServer(localIdentity);
                await Task.Run(() => tls.Accept(peer), token);
                if (string.IsNullOrEmpty(peer.Sas) || string.IsNullOrEmpty(peer.PeerFingerprint)) throw new InvalidOperationException("TLS peer не подтвердил сертификат");
                var known = settings.TrustedDevices.ContainsKey(peer.PeerFingerprint);
                status(known ? AppLocalization.T("waitingOffer") : AppLocalization.Format("pairing", peer.Sas));
                if (!known && !await confirmPairing(peer.Sas)) { tls.Close(); return; }
                status(AppLocalization.T("waitingOffer"));
                var connection = new HttpConnection(tls.Stream);
                await ServeAsync(connection, sessionToken, peer.PeerFingerprint, settings, status, confirmOffer, token);
                tls.Close();
            }
            catch (Exception error) when (!token.IsCancellationRequested)
            {
                DebugLog.Error("incoming TLS", error);
                status(ReceiverTransferStore.HasRecoverableTransfer() ? "Пауза\nСоединение потеряно. Можно продолжить передачу" : error.Message);
            }
        }
    }

    private async Task ServeAsync(HttpConnection connection, string sessionToken, string fingerprint, AppSettings settings, Action<string> status, Func<string, Task<bool>> confirmOffer, CancellationToken cancellationToken)
    {
        var receiverStore = store ?? throw new InvalidOperationException("Хранилище приёма недоступно");
        while (!cancellationToken.IsCancellationRequested)
        {
            var request = await connection.ReadRequestAsync(cancellationToken);
            if (!request.Headers.TryGetValue(SendFileProtocol.TokenHeader, out var token) || token != sessionToken)
            {
                await connection.WriteResponseAsync(HttpResponse.Empty(401, "Invalid Session Token"), cancellationToken);
                return;
            }
            HttpResponse response;
            try
            {
                if (request.Method == "POST" && request.Path == "/v1/offer")
                {
                    var manifest = System.Text.Json.JsonSerializer.Deserialize<TransferManifest>(request.Body) ?? throw new ReceiverException(400, "Bad Request");
                    var offer = receiverStore.PrepareOffer(manifest, fingerprint);
                    status(AppLocalization.Format("checkingSpace", offer.FileCount, offer.TotalSize));
                    if (request.Headers.TryGetValue("X-SendFile-Device-Name", out var name) && !string.IsNullOrWhiteSpace(name)) { settings.TrustedDevices[fingerprint] = name.Trim(); settings.Save(); }
                    if (!await confirmOffer($"Файлов: {offer.FileCount}\nРазмер: {offer.TotalSize:N0} байт")) { receiverStore.RejectOffer(offer.Id); response = HttpResponse.Empty(403, "Declined"); }
                    else
                    {
                        var accepted = receiverStore.AcceptOffer(offer.Id);
                        response = new HttpResponse(202, "Offer Accepted", new Dictionary<string, string> { ["X-Receive-File-Transfer"] = offer.Id, ["Content-Type"] = "application/json" }, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(accepted));
                    }
                }
                else if (request.Method == "GET" && TryTransferRoute(request.Path, out var stateId))
                {
                    var transferState = receiverStore.State(stateId, fingerprint);
                    response = new HttpResponse(200, "Transfer State", new Dictionary<string, string> { ["Content-Type"] = "application/json" }, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(transferState));
                }
                else if (request.Method == "DELETE" && TryTransferRoute(request.Path, out var cancelId))
                {
                    receiverStore.Clear(cancelId, fingerprint);
                    response = HttpResponse.Empty(204, "Transfer Cancelled");
                }
                else if (request.Method == "DELETE" && TryFileRoute(request.Path, out var skippedTransferId, out var skippedIndex))
                {
                    receiverStore.Skip(skippedTransferId, skippedIndex, fingerprint);
                    response = HttpResponse.Empty(204, "File Skipped");
                }
                else if (request.Method == "PATCH" && TryFileRoute(request.Path, out var transferId, out var index) && request.Headers.TryGetValue("X-Receive-File-Offset", out var offsetText) && long.TryParse(offsetText, out var offset))
                {
                    var next = receiverStore.AppendChunk(transferId, index, offset, request.Body);
                    var progress = receiverStore.Progress(transferId);
                    status(AppLocalization.Format("receiveProgress", progress.CurrentFile, progress.FileCount, progress.TransferredBytes, progress.TotalBytes, progress.TotalBytes == 0 ? 100 : progress.TransferredBytes * 100 / progress.TotalBytes));
                    response = HttpResponse.Empty(204, "Chunk Received", new Dictionary<string, string> { ["X-Receive-File-Next-Offset"] = next.ToString() });
                }
                else if (request.Method == "POST" && TryCompleteRoute(request.Path, out var completeId))
                {
                    var result = receiverStore.Complete(completeId);
                    status(result.SkippedFileCount == 0 ? AppLocalization.Format("successReceive", result.ReceivedFileCount, result.TotalSize) : AppLocalization.Format("receiveWarning", result.ReceivedFileCount, result.SkippedFileCount, string.Join(", ", result.SkippedFiles)));
                    response = HttpResponse.Empty(result.SkippedFileCount == 0 ? 201 : 207, result.SkippedFileCount == 0 ? "Received" : "Transfer Completed With Skipped Files");
                }
                else response = HttpResponse.Empty(400, "Bad Request");
            }
            catch (OffsetMismatchException mismatch) { response = HttpResponse.Empty(409, "Offset Mismatch", new Dictionary<string, string> { ["X-Receive-File-Next-Offset"] = mismatch.Next.ToString() }); }
            catch (ReceiverException error) { response = HttpResponse.Empty(error.Status, error.Reason); }
            await connection.WriteResponseAsync(response, cancellationToken);
            if (response.Status is 201 or 207) { _ = Task.Run(StopReceiving); return; }
        }
    }

    private static bool TryFileRoute(string path, out string transferId, out int index)
    {
        transferId = string.Empty; index = -1; var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 5 || parts[0] != "v1" || parts[1] != "transfers" || parts[3] != "files" || !int.TryParse(parts[4], out index)) return false;
        transferId = parts[2]; return true;
    }
    private static bool TryCompleteRoute(string path, out string transferId)
    {
        transferId = string.Empty; var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 4 || parts[0] != "v1" || parts[1] != "transfers" || parts[3] != "complete") return false;
        transferId = parts[2]; return true;
    }
    private static bool TryTransferRoute(string path, out string transferId)
    {
        transferId = string.Empty; var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || parts[0] != "v1" || parts[1] != "transfers") return false;
        transferId = parts[2]; return true;
    }

    private static string NewToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(8);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
