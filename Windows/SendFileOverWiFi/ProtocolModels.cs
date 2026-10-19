using System.Text.Json.Serialization;

namespace SendFileOverWiFi;

internal static class SendFileProtocol
{
    internal const int ChunkSize = 4 * 1024 * 1024;
    internal const string ServiceType = "_sendfile._tcp";
    internal const string TokenHeader = "X-Receive-File-Token";
}

internal sealed record TransferManifest([property: JsonPropertyName("files")] List<TransferManifestFile> Files);
internal sealed record TransferManifestFile(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("size")] string Size,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("createdAt")] string? CreatedAt = null,
    [property: JsonPropertyName("modifiedAt")] string? ModifiedAt = null,
    [property: JsonPropertyName("mimeType")] string? MimeType = null);
internal sealed record OfferAcceptance([property: JsonPropertyName("files")] List<OfferAcceptanceFile> Files);
internal sealed record OfferAcceptanceFile(
    [property: JsonPropertyName("index")] int Index,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("state")] string State);
internal sealed record TransferState([property: JsonPropertyName("state")] string State, [property: JsonPropertyName("files")] List<TransferStateFile> Files);
internal sealed record TransferStateFile(
    [property: JsonPropertyName("index")] int Index,
    [property: JsonPropertyName("size")] string Size,
    [property: JsonPropertyName("nextOffset")] string NextOffset,
    [property: JsonPropertyName("state")] string State);
public sealed record PendingOutgoingFile(string Path, string Size, string Sha256, string DisplayName);
public sealed record PendingOutgoingTransfer(string Id, string ReceiverFingerprint, string ReceiverName, List<PendingOutgoingFile> Files);

internal sealed record HttpMessage(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);
internal sealed record HttpResponse(int Status, string Reason, Dictionary<string, string> Headers, byte[] Body)
{
    internal static HttpResponse Empty(int status, string reason, Dictionary<string, string>? headers = null) =>
        new(status, reason, headers ?? [], []);
}

internal sealed class ProtocolException(string message) : Exception(message);
