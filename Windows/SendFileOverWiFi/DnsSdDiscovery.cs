using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Makaretu.Dns;

namespace SendFileOverWiFi;

internal sealed record DiscoveredRecipient(string Name, IPAddress Address, int Port, string Token);

/// <summary>mDNS/DNS-SD adapter for the v1 `_sendfile._tcp.local.` contract.</summary>
internal sealed class DnsSdDiscovery : IDisposable
{
    private readonly MulticastService mdns = new();
    private readonly ServiceDiscovery discovery;
    private ServiceProfile? advertised;
    private bool started;

    internal DnsSdDiscovery()
    {
        discovery = new ServiceDiscovery(mdns);
    }

    internal void Advertise(string name, int port, string token)
    {
        StopAdvertising();
        advertised = new ServiceProfile(string.IsNullOrWhiteSpace(name) ? "SendFile" : name.Trim(), SendFileProtocol.ServiceType, checked((ushort)port));
        advertised.AddProperty("v", "1");
        advertised.AddProperty("t", token);
        EnsureStarted();
        discovery.Advertise(advertised);
        discovery.Announce(advertised);
    }

    internal async Task<IReadOnlyList<DiscoveredRecipient>> BrowseAsync(CancellationToken cancellationToken)
    {
        EnsureStarted();
        var candidates = new ConcurrentDictionary<string, RecipientParts>(StringComparer.OrdinalIgnoreCase);
        var firstRecipient = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Answered(object? _, MessageEventArgs args)
        {
            var records = args.Message.Answers.Concat(args.Message.AdditionalRecords).ToList();
            foreach (var srv in records.OfType<SRVRecord>())
            {
                var instance = srv.Name.ToString();
                var txt = records.OfType<TXTRecord>().FirstOrDefault(x => x.Name == srv.Name);
                var props = txt?.Strings.Select(x => x.Split('=', 2)).Where(x => x.Length == 2).ToDictionary(x => x[0], x => x[1], StringComparer.OrdinalIgnoreCase);
                if (props is null || !props.TryGetValue("t", out var token) || string.IsNullOrWhiteSpace(token)) continue;
                var addresses = records.OfType<AddressRecord>().Where(x => x.Name == srv.Target).Select(x => x.Address).Where(x => x.AddressFamily == AddressFamily.InterNetwork);
                foreach (var address in addresses)
                {
                    candidates[instance + "/" + address] = new RecipientParts(instance, address, srv.Port, token);
                    // Unlike the initial implementation, this is a discovery
                    // signal rather than merely data collected until timeout.
                    firstRecipient.TrySetResult();
                }
            }
        }

        mdns.AnswerReceived += Answered;
        try
        {
            // Eight seconds is the timeout only. As soon as DNS-SD provides
            // a complete IPv4 SRV/TXT/A response, return it to the UI; the
            // recipient picker is then shown immediately just as on Apple and
            // Android implementations. Until then, repeat queries so an
            // announcement arriving during the window is still discovered.
            var deadline = DateTimeOffset.UtcNow.AddSeconds(8);
            while (!firstRecipient.Task.IsCompleted && DateTimeOffset.UtcNow < deadline)
            {
                discovery.QueryServiceInstances(SendFileProtocol.ServiceType);
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero) break;
                await Task.WhenAny(firstRecipient.Task, Task.Delay(remaining < TimeSpan.FromSeconds(1) ? remaining : TimeSpan.FromSeconds(1), cancellationToken));
                cancellationToken.ThrowIfCancellationRequested();
            }
            return candidates.Values.Select(x => new DiscoveredRecipient(InstanceLabel(x.Instance), x.Address, x.Port, x.Token)).OrderBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }
        finally { mdns.AnswerReceived -= Answered; }
    }

    internal void StopAdvertising()
    {
        if (advertised is null) return;
        discovery.Unadvertise(advertised);
        advertised = null;
    }

    private void EnsureStarted()
    {
        if (started) return;
        mdns.Start();
        started = true;
    }

    private static string InstanceLabel(string fullName)
    {
        var suffix = "." + SendFileProtocol.ServiceType + ".local";
        return fullName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? fullName[..^suffix.Length] : fullName;
    }

    public void Dispose()
    {
        StopAdvertising();
        discovery.Dispose();
        mdns.Dispose();
    }

    private sealed record RecipientParts(string Instance, IPAddress Address, int Port, string Token);
}
