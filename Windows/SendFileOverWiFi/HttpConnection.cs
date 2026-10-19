using System.Globalization;
using System.Text;

namespace SendFileOverWiFi;

/// <summary>Sequential HTTP/1.1 framing used by protocol v1 over one TLS stream.</summary>
internal sealed class HttpConnection(Stream stream)
{
    private const int MaximumHeaderBytes = 64 * 1024;
    // Protocol v1 permits UTF-8 values in its custom headers (notably the
    // sender display name).  Do not use ASCII here: it silently turns every
    // non-ASCII character into '?', which then becomes persisted trust data.
    private static readonly UTF8Encoding HeaderEncoding = new(false, true);
    private readonly Stream stream = stream;
    private readonly List<byte> buffered = [];

    internal async Task<HttpMessage> ReadRequestAsync(CancellationToken cancellationToken)
    {
        var lines = ParseHeader(await ReadHeaderAsync(cancellationToken));
        var first = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (first.Length != 3 || !string.Equals(first[2], "HTTP/1.1", StringComparison.Ordinal)) throw new ProtocolException("Некорректный HTTP-запрос");
        var headers = ParseHeaders(lines);
        return new HttpMessage(first[0], first[1], headers, await ReadExactlyAsync(ContentLength(headers), cancellationToken));
    }

    internal async Task<HttpResponse> ReadResponseAsync(CancellationToken cancellationToken)
    {
        var lines = ParseHeader(await ReadHeaderAsync(cancellationToken));
        var first = lines[0].Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        if (first.Length < 2 || !string.Equals(first[0], "HTTP/1.1", StringComparison.Ordinal) || !int.TryParse(first[1], NumberStyles.None, CultureInfo.InvariantCulture, out var status)) throw new ProtocolException("Некорректный HTTP-ответ");
        var headers = ParseHeaders(lines);
        return new HttpResponse(status, first.Length == 3 ? first[2] : string.Empty, headers, await ReadExactlyAsync(ContentLength(headers), cancellationToken));
    }

    internal Task WriteRequestAsync(string method, string path, IReadOnlyDictionary<string, string> headers, byte[] body, CancellationToken cancellationToken) =>
        WriteAsync($"{method} {path} HTTP/1.1", headers, body, cancellationToken);

    internal Task WriteResponseAsync(HttpResponse response, CancellationToken cancellationToken) =>
        WriteAsync($"HTTP/1.1 {response.Status} {response.Reason}", response.Headers, response.Body, cancellationToken);

    private async Task WriteAsync(string firstLine, IReadOnlyDictionary<string, string> supplied, byte[] body, CancellationToken cancellationToken)
    {
        var wire = new StringBuilder(firstLine).Append("\r\n");
        foreach (var (name, value) in supplied) wire.Append(name).Append(": ").Append(value.Replace("\r", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal)).Append("\r\n");
        wire.Append("Content-Length: ").Append(body.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\nConnection: keep-alive\r\n\r\n");
        await stream.WriteAsync(HeaderEncoding.GetBytes(wire.ToString()), cancellationToken);
        if (body.Length != 0) await stream.WriteAsync(body, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private async Task<byte[]> ReadHeaderAsync(CancellationToken cancellationToken)
    {
        while (IndexOfHeaderEnd() < 0)
        {
            if (buffered.Count > MaximumHeaderBytes) throw new ProtocolException("Слишком большой HTTP-заголовок");
            await ReadMoreAsync(cancellationToken);
        }
        var length = IndexOfHeaderEnd();
        var result = buffered.Take(length).ToArray();
        buffered.RemoveRange(0, length + 4);
        return result;
    }

    private async Task<byte[]> ReadExactlyAsync(int count, CancellationToken cancellationToken)
    {
        while (buffered.Count < count) await ReadMoreAsync(cancellationToken);
        var result = buffered.Take(count).ToArray();
        buffered.RemoveRange(0, count);
        return result;
    }

    private async Task ReadMoreAsync(CancellationToken cancellationToken)
    {
        var bytes = new byte[64 * 1024];
        var count = await stream.ReadAsync(bytes, cancellationToken);
        if (count == 0) throw new EndOfStreamException("Соединение закрыто");
        buffered.AddRange(bytes.AsSpan(0, count).ToArray());
    }

    private int IndexOfHeaderEnd()
    {
        for (var i = 0; i + 3 < buffered.Count; i++) if (buffered[i] == 13 && buffered[i + 1] == 10 && buffered[i + 2] == 13 && buffered[i + 3] == 10) return i;
        return -1;
    }

    private static string[] ParseHeader(byte[] raw)
    {
        string value;
        try { value = HeaderEncoding.GetString(raw); }
        catch (DecoderFallbackException) { throw new ProtocolException("HTTP-заголовок содержит некорректный UTF-8"); }
        var lines = value.Split("\r\n", StringSplitOptions.None);
        if (lines.Length == 0 || string.IsNullOrWhiteSpace(lines[0])) throw new ProtocolException("Пустой HTTP-заголовок");
        return lines;
    }

    private static Dictionary<string, string> ParseHeaders(IEnumerable<string> lines)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            if (line.Length == 0) continue;
            var index = line.IndexOf(':');
            if (index <= 0) throw new ProtocolException("Некорректный HTTP-заголовок");
            headers[line[..index]] = line[(index + 1)..].Trim();
        }
        return headers;
    }

    private static int ContentLength(IReadOnlyDictionary<string, string> headers)
    {
        if (!headers.TryGetValue("Content-Length", out var text) || !int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value < 0) throw new ProtocolException("Content-Length отсутствует или некорректен");
        return value;
    }
}
