using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Pkcs;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using Org.BouncyCastle.X509;

namespace SendFileOverWiFi;

/// <summary>Reads the app-local PKCS#12 identity without using Windows CNG.</summary>
internal sealed class BouncyTlsIdentity
{
    private readonly AsymmetricKeyParameter privateKey;
    private readonly X509Certificate certificate;

    internal BouncyTlsIdentity(byte[] container)
    {
        var store = new Pkcs12StoreBuilder().Build();
        using var input = new MemoryStream(container);
        store.Load(input, DeviceIdentity.Password.ToCharArray());
        string? alias = null;
        foreach (string candidate in store.Aliases) if (store.IsKeyEntry(candidate)) { alias = candidate; break; }
        if (alias is null) throw new InvalidOperationException("Локальная TLS-идентичность не содержит закрытый ключ");
        privateKey = store.GetKey(alias).Key;
        certificate = store.GetCertificate(alias).Certificate;
    }

    internal Certificate CertificateFor(TlsContext context)
    {
        var tlsCertificate = context.Crypto.CreateCertificate(certificate.GetEncoded());
        if (TlsUtilities.IsTlsV13(context))
            return new Certificate(TlsUtilities.EmptyBytes, [new CertificateEntry(tlsCertificate, null)]);
        return new Certificate([tlsCertificate]);
    }

    internal TlsCredentialedSigner SignerFor(TlsContext context, SignatureAndHashAlgorithm algorithm)
    {
        if (context.Crypto is not BcTlsCrypto crypto) throw new NotSupportedException("Требуется Bouncy Castle TLS crypto");
        return new BcDefaultTlsCredentialedSigner(new TlsCryptoParameters(context), crypto, privateKey, CertificateFor(context), algorithm);
    }

    internal static string Fingerprint(Certificate chain)
    {
        if (chain is null || chain.IsEmpty) throw new InvalidOperationException("TLS-партнёр не предоставил сертификат");
        var peer = new X509CertificateParser().ReadCertificate(chain.GetCertificateAt(0).GetEncoded());
        var publicKey = SubjectPublicKeyInfoFactory.CreateSubjectPublicKeyInfo(peer.GetPublicKey()).GetEncoded();
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(publicKey)).ToLowerInvariant();
    }
}
