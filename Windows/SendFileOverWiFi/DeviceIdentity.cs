using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace SendFileOverWiFi;

/// <summary>App-local TLS identity independent from Windows Certificate Store/CNG.</summary>
internal static class DeviceIdentity
{
    private static readonly object gate = new();
    private static readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SendFile over WiFi");
    private static readonly string path = Path.Combine(directory, "tls-identity-v1.pfx");
    // The identity protects the TLS channel together with SAS confirmation;
    // this password only prevents accidental inspection of the local container.
    internal const string Password = "sendfile-over-wifi-local-v1";

    internal static byte[] LoadOrCreate()
    {
        lock (gate)
        {
            try
            {
                if (File.Exists(path))
                {
                    var loaded = File.ReadAllBytes(path);
                    using var storedCertificate = new X509Certificate2(loaded, Password, X509KeyStorageFlags.EphemeralKeySet);
                    if (storedCertificate.HasPrivateKey && storedCertificate.NotAfter > DateTimeOffset.UtcNow.AddDays(1)) return loaded;
                }
            }
            catch { try { File.Delete(path); } catch { } }

            Directory.CreateDirectory(directory);
            using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest("CN=SendFile over WiFi", key, HashAlgorithmName.SHA256);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
            request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
            using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(10));
            var bytes = certificate.Export(X509ContentType.Pfx, Password);
            var temporary = path + ".tmp";
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, true);
            return bytes;
        }
    }

}
