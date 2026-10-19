using System.Globalization;
using System.Text.Json;

namespace SendFileOverWiFi;

/// <summary>Uploads a v1 offer and keeps enough local state to resume it after reconnecting.</summary>
internal sealed class OutgoingTransferClient(AppSettings settings, DiscoveredRecipient recipient, Action<string> status)
{
    private sealed record Source(string Path, long Size, TransferManifestFile Manifest);
    private readonly AppSettings settings = settings;
    private readonly DiscoveredRecipient recipient = recipient;
    private readonly Action<string> status = status;

    internal async Task SendAsync(HttpConnection connection, IReadOnlyList<string> paths, string receiverFingerprint, CancellationToken cancellationToken)
    {
        var sourceRoot = CommonSourceRoot(paths);
        var files = paths.Select(path => Prepare(path, sourceRoot)).ToList();
        var manifest = new TransferManifest(files.Select(file => file.Manifest).ToList());
        var headers = Headers("application/json");
        headers["X-SendFile-Device-Name"] = settings.DisplayName.Replace("\r", " ").Replace("\n", " ").Trim();
        await connection.WriteRequestAsync("POST", "/v1/offer", headers, JsonSerializer.SerializeToUtf8Bytes(manifest), cancellationToken);
        var offer = await connection.ReadResponseAsync(cancellationToken);
        if (offer.Status != 202 || !offer.Headers.TryGetValue("X-Receive-File-Transfer", out var transferId)) throw ResponseError(offer.Status);
        var accepted = JsonSerializer.Deserialize<OfferAcceptance>(offer.Body) ?? throw new ProtocolException("Некорректный ответ получателя");
        settings.PendingOutgoing = new PendingOutgoingTransfer(transferId, receiverFingerprint, recipient.Name,
            files.Select(file => new PendingOutgoingFile(file.Path, file.Size.ToString(CultureInfo.InvariantCulture), file.Manifest.Sha256, Path.GetFileName(file.Path))).ToList());
        settings.Save();
        await UploadAndCompleteAsync(connection, transferId, files.Cast<Source?>().ToList(), accepted.Files.Select(file => new TransferStateFile(file.Index, "0", "0", file.State)).ToList(), cancellationToken);
    }

    internal async Task ResumeAsync(HttpConnection connection, PendingOutgoingTransfer pending, CancellationToken cancellationToken)
    {
        await connection.WriteRequestAsync("GET", $"/v1/transfers/{pending.Id}", Headers(null), [], cancellationToken);
        var reply = await connection.ReadResponseAsync(cancellationToken);
        if (reply.Status != 200) throw ResponseError(reply.Status);
        var transferState = JsonSerializer.Deserialize<TransferState>(reply.Body) ?? throw new ProtocolException("Некорректное состояние докачки");
        if (transferState.State != "uploading") throw new ProtocolException("Приём приостановлен: нет свободного места");
        await UploadAndCompleteAsync(connection, pending.Id, pending.Files.Select(PreparePending).ToList(), transferState.Files, cancellationToken);
    }

    internal async Task CancelAsync(HttpConnection connection, PendingOutgoingTransfer pending, CancellationToken cancellationToken)
    {
        await connection.WriteRequestAsync("DELETE", $"/v1/transfers/{pending.Id}", Headers(null), [], cancellationToken);
        var reply = await connection.ReadResponseAsync(cancellationToken);
        if (reply.Status != 204) throw ResponseError(reply.Status);
        settings.PendingOutgoing = null; settings.Save();
    }

    private async Task UploadAndCompleteAsync(HttpConnection connection, string transferId, IReadOnlyList<Source?> files, IReadOnlyList<TransferStateFile> state, CancellationToken cancellationToken)
    {
        var total = files.Where(file => file is not null).Sum(file => file!.Size);
        long completed = 0; var skipped = 0; var skippedFiles = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            var remote = state.FirstOrDefault(item => item.Index == index) ?? throw new ProtocolException("Получатель вернул неполное состояние передачи");
            var source = files[index];
            if (remote.State is "received" or "already-present") { if (source is not null) completed += source.Size; continue; }
            if (remote.State == "skipped") { skipped++; skippedFiles.Add(DisplayName(source, index)); continue; }
            if (source is null) { await SkipAsync(connection, transferId, index, cancellationToken); skipped++; skippedFiles.Add(DisplayName(source, index)); continue; }
            if (!long.TryParse(remote.NextOffset, NumberStyles.None, CultureInfo.InvariantCulture, out var offset) || offset < 0 || offset > source.Size) throw new ProtocolException("Некорректное смещение докачки");
            await using var stream = File.OpenRead(source.Path);
            stream.Position = offset;
            do
            {
                var length = (int)Math.Min(SendFileProtocol.ChunkSize, source.Size - offset);
                var chunk = new byte[length]; var read = 0;
                while (read < length)
                {
                    var count = await stream.ReadAsync(chunk.AsMemory(read, length - read), cancellationToken);
                    if (count == 0) { await SkipAsync(connection, transferId, index, cancellationToken); skipped++; skippedFiles.Add(DisplayName(source, index)); goto NextFile; }
                    read += count;
                }
                var chunkHeaders = Headers("application/octet-stream"); chunkHeaders["X-Receive-File-Offset"] = offset.ToString(CultureInfo.InvariantCulture);
                await connection.WriteRequestAsync("PATCH", $"/v1/transfers/{transferId}/files/{index}", chunkHeaders, chunk, cancellationToken);
                var response = await connection.ReadResponseAsync(cancellationToken);
                if (response.Status == 422) { skipped++; skippedFiles.Add(DisplayName(source, index)); goto NextFile; }
                if (response.Status != 204 || !response.Headers.TryGetValue("X-Receive-File-Next-Offset", out var nextText) || !long.TryParse(nextText, out var next) || next != offset + length) throw ResponseError(response.Status);
                offset = next;
                status(AppLocalization.Format("transferProgress", index + 1, files.Count, completed + offset, total, total == 0 ? 100 : (completed + offset) * 100 / total));
            } while (offset < source.Size);
            completed += source.Size;
        NextFile: ;
        }
        await connection.WriteRequestAsync("POST", $"/v1/transfers/{transferId}/complete", Headers(null), [], cancellationToken);
        var final = await connection.ReadResponseAsync(cancellationToken);
        if (final.Status is not (201 or 207)) throw ResponseError(final.Status);
        settings.PendingOutgoing = null; settings.Save();
        status(final.Status == 201 ? AppLocalization.Format("successSend", files.Count, total) : AppLocalization.Format("successWarning", files.Count - skipped, files.Count, total, string.Join(", ", skippedFiles)));
    }

    private async Task SkipAsync(HttpConnection connection, string transferId, int index, CancellationToken cancellationToken)
    {
        await connection.WriteRequestAsync("DELETE", $"/v1/transfers/{transferId}/files/{index}", Headers(null), [], cancellationToken);
        var response = await connection.ReadResponseAsync(cancellationToken);
        if (response.Status != 204) throw ResponseError(response.Status);
    }

    private Dictionary<string, string> Headers(string? contentType)
    {
        var headers = new Dictionary<string, string> { ["Host"] = recipient.Name, [SendFileProtocol.TokenHeader] = recipient.Token };
        if (contentType is not null) headers["Content-Type"] = contentType;
        return headers;
    }

    private static Source Prepare(string path, string sourceRoot)
    {
        var info = new FileInfo(path); if (!info.Exists) throw new ProtocolException($"Файл недоступен: {Path.GetFileName(path)}");
        var sourceVolume = Path.GetPathRoot(Path.GetFullPath(sourceRoot))!;
        var fileVolume = Path.GetPathRoot(info.FullName)!;
        var relative = string.Equals(sourceVolume, fileVolume, StringComparison.OrdinalIgnoreCase)
            ? Path.GetRelativePath(sourceRoot, info.FullName)
            : $"volume-{fileVolume.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(':', '-')}/{info.FullName[fileVolume.Length..]}";
        if (Path.IsPathRooted(relative) || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) || relative == "..") relative = info.Name;
        var encoded = string.Join('/', relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Select(Uri.EscapeDataString));
        return new Source(path, info.Length, new TransferManifestFile(encoded, info.Length.ToString(CultureInfo.InvariantCulture), ReceiverTransferStore.FileHash(path), info.CreationTimeUtc.ToString("O", CultureInfo.InvariantCulture), info.LastWriteTimeUtc.ToString("O", CultureInfo.InvariantCulture), MimeType(info.Extension)));
    }

    private static string CommonSourceRoot(IReadOnlyList<string> paths)
    {
        var directories = paths.Select(path => Path.GetDirectoryName(Path.GetFullPath(path)) ?? Path.GetPathRoot(path)!).ToList();
        var candidate = directories[0];
        while (directories.Any(directory => !directory.StartsWith(candidate + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && !string.Equals(directory, candidate, StringComparison.OrdinalIgnoreCase)))
        {
            var parent = Directory.GetParent(candidate)?.FullName;
            if (string.IsNullOrEmpty(parent)) break;
            candidate = parent;
        }
        return candidate;
    }

    private static Source? PreparePending(PendingOutgoingFile file)
    {
        try
        {
            var info = new FileInfo(file.Path);
            if (!info.Exists || !long.TryParse(file.Size, NumberStyles.None, CultureInfo.InvariantCulture, out var size) || info.Length != size || ReceiverTransferStore.FileHash(file.Path) != file.Sha256) return null;
            return new Source(file.Path, size, new TransferManifestFile(Uri.EscapeDataString(file.DisplayName), file.Size, file.Sha256));
        }
        catch { return null; }
    }

    private static string DisplayName(Source? source, int index) => source is null
        ? $"#{index + 1}"
        : string.Join('/', source.Manifest.Path.Split('/').Select(Uri.UnescapeDataString));

    private static string? MimeType(string extension) => extension.ToLowerInvariant() switch
    {
        ".txt" => "text/plain", ".pdf" => "application/pdf", ".json" => "application/json",
        ".jpg" or ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif",
        ".webp" => "image/webp", ".heic" => "image/heic", ".mp3" => "audio/mpeg",
        ".m4a" => "audio/mp4", ".wav" => "audio/wav", ".mp4" => "video/mp4",
        ".mov" => "video/quicktime", ".zip" => "application/zip", _ => null
    };

    private static ProtocolException ResponseError(int status) => new(status switch
    {
        400 => AppLocalization.T("error400"),
        401 => AppLocalization.T("error401"),
        403 => AppLocalization.T("error403"),
        409 => AppLocalization.T("error409"),
        410 => AppLocalization.T("error410"),
        422 => AppLocalization.T("error422"),
        507 => AppLocalization.T("error507"),
        _ => AppLocalization.T("transferError")
    });
}
