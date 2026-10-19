using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace SendFileOverWiFi;

internal sealed record PendingIncomingOffer(string Id, int FileCount, long TotalSize);
internal sealed record IncomingTransferProgress(int CurrentFile, int FileCount, long TransferredBytes, long TotalBytes);
internal sealed record IncomingTransferResult(int ReceivedFileCount, long TotalSize, IReadOnlyList<string> SkippedFiles)
{
    internal int SkippedFileCount => SkippedFiles.Count;
}
internal sealed record PausedIncomingTransferInfo(int CurrentFile, int FileCount, long ConfirmedBytes, long TotalBytes);

/// <summary>Durable on-disk staging area for the one incoming v1 transfer.</summary>
internal sealed class ReceiverTransferStore
{
    private sealed class Item(TransferManifestFile manifest, string destination, string staging)
    {
        internal readonly TransferManifestFile Manifest = manifest;
        internal readonly string Destination = destination;
        internal readonly string Staging = staging;
        internal long Offset;
        internal string State = "uploading";
    }

    private sealed class Transfer(string id, string root, long total, string senderFingerprint, DateTimeOffset updatedAt, List<Item> files)
    {
        internal readonly string Id = id;
        internal readonly string Root = root;
        internal readonly long Total = total;
        internal readonly string SenderFingerprint = senderFingerprint;
        internal DateTimeOffset UpdatedAt = updatedAt;
        internal readonly List<Item> Files = files;
    }

    private sealed record PersistedItem(TransferManifestFile Manifest, string Destination, string Staging, long Offset, string State);
    private sealed record PersistedTransfer(string Id, string Root, long Total, string SenderFingerprint, DateTimeOffset UpdatedAt, List<PersistedItem> Files);

    private readonly object gate = new();
    private Transfer? active;
    private readonly AppSettings settings;
    private static string StagingRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SendFile over WiFi", "staging");
    private static string StatePath => Path.Combine(StagingRoot, "active-transfer.json");

    internal static PausedIncomingTransferInfo? GetRecoverableTransfer()
    {
        try
        {
            if (!File.Exists(StatePath)) return null;
            using var state = JsonDocument.Parse(File.ReadAllText(StatePath));
            var root = state.RootElement;
            if (!root.TryGetProperty("UpdatedAt", out var updatedAt) || !updatedAt.TryGetDateTimeOffset(out var updated)) return null;
            if (DateTimeOffset.UtcNow - updated > TimeSpan.FromHours(24)) { ClearPersistedTransfer(); return null; }
            if (!root.TryGetProperty("Files", out var files) || files.ValueKind != JsonValueKind.Array) return null;
            var fileCount = files.GetArrayLength(); long confirmed = 0; long total = 0; var current = fileCount;
            var index = 0;
            foreach (var file in files.EnumerateArray())
            {
                index++;
                if (file.TryGetProperty("Offset", out var offset) && offset.TryGetInt64(out var bytes)) confirmed += bytes;
                if (file.TryGetProperty("Manifest", out var manifest) && manifest.TryGetProperty("Size", out var size) && long.TryParse(size.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, out var expected)) total += expected;
                if (current == fileCount && file.TryGetProperty("State", out var fileState) && fileState.GetString() == "uploading") current = index;
            }
            return new PausedIncomingTransferInfo(current, fileCount, confirmed, total);
        }
        catch { return null; }
    }

    internal static bool HasRecoverableTransfer() => GetRecoverableTransfer() is not null;
    internal static void CleanupExpiredTransfer() => _ = GetRecoverableTransfer();

    internal static void ClearPersistedTransfer()
    {
        try
        {
            string? root = null;
            if (File.Exists(StatePath))
            {
                using var state = JsonDocument.Parse(File.ReadAllText(StatePath));
                if (state.RootElement.TryGetProperty("Root", out var rootValue)) root = rootValue.GetString();
            }
            if (IsStagingPath(root) && Directory.Exists(root!)) Directory.Delete(root!, true);
        }
        catch { }
        try { if (File.Exists(StatePath)) File.Delete(StatePath); } catch { }
    }

    internal ReceiverTransferStore(AppSettings settings)
    {
        this.settings = settings;
        LoadPersisted();
    }

    internal PendingIncomingOffer PrepareOffer(TransferManifest manifest, string senderFingerprint)
    {
        lock (gate)
        {
            if (active is not null || manifest.Files.Count == 0) throw new ReceiverException(409, "Another Offer Is Pending");
            var id = Guid.NewGuid().ToString("N");
            var root = Path.Combine(StagingRoot, id);
            var destinationRoot = settings.ReceiveDirectory;
            long total = 0;
            long reservation = 0;
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var files = new List<Item>();
            try
            {
                Directory.CreateDirectory(destinationRoot);
                foreach (var entry in manifest.Files)
                {
                    if (!long.TryParse(entry.Size, NumberStyles.None, CultureInfo.InvariantCulture, out var size) || size < 0 || !IsDigest(entry.Sha256)) throw new ReceiverException(400, "Bad Request");
                    var relative = DecodePath(entry.Path);
                    if (!paths.Add(relative)) relative = MakeUniqueRelative(relative, paths);
                    total = checked(total + size);
                    var destination = UniqueDestination(destinationRoot, relative, entry.Sha256);
                    var staging = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
                    var item = new Item(entry with { Path = relative }, destination, staging);
                    // A matching destination is already complete and must neither be uploaded nor reserved again.
                    if (File.Exists(destination) && FileHash(destination) == entry.Sha256) item.State = "already-present";
                    else reservation = checked(reservation + size);
                    files.Add(item);
                }
                EnsureReservation(destinationRoot, root, reservation);
                Directory.CreateDirectory(root);
                foreach (var item in files.Where(item => item.State == "uploading"))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(item.Staging)!);
                    // Preallocation is the reservation: another process cannot consume this accepted capacity.
                    using var stream = new FileStream(item.Staging, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    stream.SetLength(long.Parse(item.Manifest.Size, CultureInfo.InvariantCulture));
                    stream.Flush(true);
                }
                active = new Transfer(id, root, total, senderFingerprint, DateTimeOffset.UtcNow, files);
                PersistUnsafe();
                return new PendingIncomingOffer(id, files.Count, total);
            }
            catch
            {
                try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { }
                throw;
            }
        }
    }

    internal OfferAcceptance AcceptOffer(string id)
    {
        lock (gate)
        {
            var transfer = Require(id);
            return new OfferAcceptance(transfer.Files.Select((file, index) => new OfferAcceptanceFile(index, file.Manifest.Path, file.State)).ToList());
        }
    }

    internal void RejectOffer(string id) { lock (gate) { if (active?.Id == id) ClearUnsafe(); } }

    internal long AppendChunk(string id, int index, long offset, byte[] data)
    {
        lock (gate)
        {
            var transfer = Require(id);
            if (index < 0 || index >= transfer.Files.Count) throw new ReceiverException(410, "Transfer Expired");
            var file = transfer.Files[index];
            var expected = long.Parse(file.Manifest.Size, CultureInfo.InvariantCulture);
            if (file.State != "uploading" || offset != file.Offset || data.LongLength > expected - offset) throw new OffsetMismatchException(file.Offset);
            if (offset + data.LongLength < expected && data.Length != SendFileProtocol.ChunkSize) throw new ReceiverException(400, "Bad Request");
            using (var stream = new FileStream(file.Staging, FileMode.Open, FileAccess.Write, FileShare.None))
            {
                stream.Position = offset;
                stream.Write(data);
                stream.Flush(true);
            }
            file.Offset += data.LongLength;
            if (file.Offset == expected)
            {
                if (FileHash(file.Staging) == file.Manifest.Sha256)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(file.Destination)!);
                    var finalized = !File.Exists(file.Destination);
                    if (finalized) File.Move(file.Staging, file.Destination);
                    else File.Delete(file.Staging); // identical digest was already present.
                    if (finalized && settings.PreserveDates) ApplyDates(file.Manifest, file.Destination);
                    file.State = "received";
                }
                else { File.Delete(file.Staging); file.State = "skipped"; }
            }
            transfer.UpdatedAt = DateTimeOffset.UtcNow;
            PersistUnsafe();
            return file.Offset;
        }
    }

    internal IncomingTransferProgress Progress(string id)
    {
        lock (gate)
        {
            var transfer = Require(id);
            var current = transfer.Files.FindIndex(file => file.State == "uploading");
            var confirmed = transfer.Files.Sum(file => file.State == "already-present" ? long.Parse(file.Manifest.Size, CultureInfo.InvariantCulture) : file.Offset);
            return new IncomingTransferProgress((current < 0 ? transfer.Files.Count - 1 : current) + 1, transfer.Files.Count, confirmed, transfer.Total);
        }
    }

    internal IncomingTransferResult Complete(string id)
    {
        lock (gate)
        {
            var transfer = Require(id);
            if (transfer.Files.Any(file => file.State == "uploading")) throw new ReceiverException(409, "Transfer Incomplete");
            var skipped = transfer.Files.Where(file => file.State == "skipped").Select(DisplayPath).ToList();
            var result = new IncomingTransferResult(transfer.Files.Count - skipped.Count, transfer.Total, skipped);
            ClearUnsafe();
            return result;
        }
    }

    internal void Clear() { lock (gate) { ClearUnsafe(); } }

    private static void ApplyDates(TransferManifestFile manifest, string path)
    {
        // A filesystem can reject creation time while still accepting modified
        // time, so these writes intentionally are independent.
        if (DateTimeOffset.TryParse(manifest.CreatedAt, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var created))
        {
            try { File.SetCreationTimeUtc(path, created.UtcDateTime); } catch { }
        }
        if (DateTimeOffset.TryParse(manifest.ModifiedAt, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var modified))
        {
            try { File.SetLastWriteTimeUtc(path, modified.UtcDateTime); } catch { }
        }
    }

    internal TransferState State(string id, string senderFingerprint)
    {
        lock (gate)
        {
            var transfer = Require(id);
            if (!CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(transfer.SenderFingerprint), System.Text.Encoding.UTF8.GetBytes(senderFingerprint))) throw new ReceiverException(403, "Declined");
            transfer.UpdatedAt = DateTimeOffset.UtcNow;
            PersistUnsafe();
            return new TransferState("uploading", transfer.Files.Select((file, index) => new TransferStateFile(index, file.Manifest.Size, file.Offset.ToString(CultureInfo.InvariantCulture), file.State)).ToList());
        }
    }

    internal void Clear(string id, string senderFingerprint)
    {
        lock (gate)
        {
            var transfer = Require(id);
            if (!CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(transfer.SenderFingerprint), System.Text.Encoding.UTF8.GetBytes(senderFingerprint))) throw new ReceiverException(403, "Declined");
            ClearUnsafe();
        }
    }

    internal void Skip(string id, int index, string senderFingerprint)
    {
        lock (gate)
        {
            var transfer = Require(id);
            if (!CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(transfer.SenderFingerprint), System.Text.Encoding.UTF8.GetBytes(senderFingerprint))) throw new ReceiverException(403, "Declined");
            if (index < 0 || index >= transfer.Files.Count) throw new ReceiverException(410, "Transfer Expired");
            var file = transfer.Files[index];
            if (file.State == "uploading") { try { File.Delete(file.Staging); } catch { } file.State = "skipped"; file.Offset = 0; transfer.UpdatedAt = DateTimeOffset.UtcNow; PersistUnsafe(); }
        }
    }

    private Transfer Require(string id)
    {
        ExpireUnsafe();
        return active?.Id == id ? active : throw new ReceiverException(410, "Transfer Expired");
    }

    private void LoadPersisted()
    {
        lock (gate)
        {
            try
            {
                if (!File.Exists(StatePath)) return;
                var persisted = JsonSerializer.Deserialize<PersistedTransfer>(File.ReadAllText(StatePath));
                if (persisted is null || DateTimeOffset.UtcNow - persisted.UpdatedAt > TimeSpan.FromHours(24))
                {
                    try { if (persisted is not null && Directory.Exists(persisted.Root)) Directory.Delete(persisted.Root, true); } catch { }
                    ClearUnsafe(); return;
                }
                var files = persisted.Files.Select(item =>
                {
                    var restored = new Item(item.Manifest, item.Destination, item.Staging) { Offset = item.Offset, State = item.State };
                    if (restored.State == "uploading" && (!File.Exists(restored.Staging) || new FileInfo(restored.Staging).Length != long.Parse(restored.Manifest.Size, CultureInfo.InvariantCulture))) throw new InvalidDataException("Incomplete staging data");
                    return restored;
                }).ToList();
                active = new Transfer(persisted.Id, persisted.Root, persisted.Total, persisted.SenderFingerprint, persisted.UpdatedAt, files);
            }
            catch { ClearUnsafe(); }
        }
    }

    private void PersistUnsafe()
    {
        if (active is null) return;
        Directory.CreateDirectory(StagingRoot);
        var saved = new PersistedTransfer(active.Id, active.Root, active.Total, active.SenderFingerprint, active.UpdatedAt,
            active.Files.Select(file => new PersistedItem(file.Manifest, file.Destination, file.Staging, file.Offset, file.State)).ToList());
        var temporary = StatePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(saved));
        File.Move(temporary, StatePath, true);
    }

    private void ExpireUnsafe()
    {
        if (active is not null && DateTimeOffset.UtcNow - active.UpdatedAt > TimeSpan.FromHours(24)) ClearUnsafe();
    }

    private void ClearUnsafe()
    {
        if (active is null) { ClearPersistedTransfer(); return; }
        try { if (IsStagingPath(active.Root) && Directory.Exists(active.Root)) Directory.Delete(active.Root, true); } catch { }
        try { if (File.Exists(StatePath)) File.Delete(StatePath); } catch { }
        active = null;
    }

    private static bool IsStagingPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            var staging = Path.GetFullPath(StagingRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return Path.GetFullPath(path).StartsWith(staging, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private static bool IsDigest(string digest) => digest.Length == 64 && digest.All(Uri.IsHexDigit) && digest.All(c => !char.IsUpper(c));
    private static string DisplayPath(Item item) => string.Join('/', item.Manifest.Path.Split('/').Select(Uri.UnescapeDataString));
    private static void EnsureReservation(string destinationRoot, string stagingRoot, long reservation)
    {
        var destinationVolume = Path.GetPathRoot(Path.GetFullPath(destinationRoot))!;
        var stagingVolume = Path.GetPathRoot(Path.GetFullPath(stagingRoot))!;
        if (new DriveInfo(destinationVolume).AvailableFreeSpace < reservation) throw new ReceiverException(507, "Insufficient Storage");
        // A cross-volume final move copies before deleting staging, so both volumes need the reservation.
        if (!string.Equals(destinationVolume, stagingVolume, StringComparison.OrdinalIgnoreCase) && new DriveInfo(stagingVolume).AvailableFreeSpace < reservation) throw new ReceiverException(507, "Insufficient Storage");
    }
    private static string DecodePath(string encoded)
    {
        if (string.IsNullOrWhiteSpace(encoded) || encoded.StartsWith('/') || encoded.Contains('\\')) throw new ReceiverException(400, "Bad Request");
        var parts = encoded.Split('/').Select(Uri.UnescapeDataString).ToArray();
        if (parts.Any(part => string.IsNullOrWhiteSpace(part) || part is "." or ".." || part.Contains('/') || part.Contains('\\'))) throw new ReceiverException(400, "Bad Request");
        return string.Join('/', parts);
    }
    private static string MakeUniqueRelative(string value, HashSet<string> existing)
    {
        var directory = Path.GetDirectoryName(value)?.Replace('\\', '/') ?? "";
        var extension = Path.GetExtension(value); var stem = Path.GetFileNameWithoutExtension(value);
        for (var i = 2; ; i++) { var candidate = string.IsNullOrEmpty(directory) ? $"{stem} ({i}){extension}" : $"{directory}/{stem} ({i}){extension}"; if (existing.Add(candidate)) return candidate; }
    }
    private static string UniqueDestination(string root, string relative, string digest)
    {
        var candidate = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(candidate) || FileHash(candidate) == digest) return candidate;
        var directory = Path.GetDirectoryName(candidate)!; var extension = Path.GetExtension(candidate); var stem = Path.GetFileNameWithoutExtension(candidate);
        for (var i = 2; ; i++) { var alternate = Path.Combine(directory, $"{stem} ({i}){extension}"); if (!File.Exists(alternate)) return alternate; }
    }
    internal static string FileHash(string path)
    {
        using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();
    }
}

internal sealed class ReceiverException(int status, string reason) : Exception(reason) { internal int Status { get; } = status; internal string Reason { get; } = reason; }
internal sealed class OffsetMismatchException(long next) : Exception { internal long Next { get; } = next; }
