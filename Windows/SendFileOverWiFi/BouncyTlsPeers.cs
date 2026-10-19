using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace SendFileOverWiFi;

internal sealed class SendFileTlsClient(BouncyTlsIdentity identity) : DefaultTlsClient(new BcTlsCrypto()), TlsAuthentication
{
    private readonly BouncyTlsIdentity identity = identity;
    internal string? PeerFingerprint { get; private set; }
    internal string? Sas { get; private set; }

    protected override ProtocolVersion[] GetSupportedVersions() => [ProtocolVersion.TLSv13];
    protected override int[] GetSupportedCipherSuites() => TlsUtilities.GetSupportedCipherSuites(Crypto, [CipherSuite.TLS_AES_128_GCM_SHA256, CipherSuite.TLS_CHACHA20_POLY1305_SHA256]);
    public override TlsAuthentication GetAuthentication() => this;
    public void NotifyServerCertificate(TlsServerCertificate certificate) => PeerFingerprint = BouncyTlsIdentity.Fingerprint(certificate.Certificate);
    public TlsCredentials GetClientCredentials(CertificateRequest request) => identity.SignerFor(m_context, new SignatureAndHashAlgorithm(HashAlgorithm.sha256, SignatureAlgorithm.ecdsa));
    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        var material = m_context.ExportKeyingMaterial("EXPORTER-SendFile-v1-SAS", [], 32);
        var value = (material[0] << 12) | (material[1] << 4) | (material[2] >> 4);
        const string alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        Sas = string.Concat(alphabet[(value >> 15) & 31], alphabet[(value >> 10) & 31], alphabet[(value >> 5) & 31], alphabet[value & 31]);
    }
}

internal sealed class SendFileTlsServer(BouncyTlsIdentity identity) : DefaultTlsServer(new BcTlsCrypto())
{
    private readonly BouncyTlsIdentity identity = identity;
    internal string? PeerFingerprint { get; private set; }
    internal string? Sas { get; private set; }
    protected override ProtocolVersion[] GetSupportedVersions() => [ProtocolVersion.TLSv13];
    protected override int[] GetSupportedCipherSuites() => TlsUtilities.GetSupportedCipherSuites(Crypto, [CipherSuite.TLS_AES_128_GCM_SHA256, CipherSuite.TLS_CHACHA20_POLY1305_SHA256]);
    public override CertificateRequest GetCertificateRequest() => new(TlsUtilities.EmptyBytes, TlsUtilities.GetDefaultSupportedSignatureAlgorithms(m_context), null, null);
    public override void NotifyClientCertificate(Certificate certificate) => PeerFingerprint = BouncyTlsIdentity.Fingerprint(certificate);
    public override TlsCredentials GetCredentials() => identity.SignerFor(m_context, new SignatureAndHashAlgorithm(HashAlgorithm.sha256, SignatureAlgorithm.ecdsa));
    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        var material = m_context.ExportKeyingMaterial("EXPORTER-SendFile-v1-SAS", [], 32);
        var value = (material[0] << 12) | (material[1] << 4) | (material[2] >> 4);
        const string alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        Sas = string.Concat(alphabet[(value >> 15) & 31], alphabet[(value >> 10) & 31], alphabet[(value >> 5) & 31], alphabet[value & 31]);
    }
}
