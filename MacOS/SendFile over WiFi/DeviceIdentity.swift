import CryptoKit
import Foundation
import Security

/// Постоянная TLS-личность установки. Закрытый ключ создаётся прямо в Keychain
/// и никогда не извлекается из него.
enum DeviceIdentity {
    private static let keyTag = Data("com.ao.sendfileoverwifi.device-identity".utf8)

    static func loadOrCreate() throws -> SecIdentity {
        if let certificate = existingCertificate(), let privateKey = existingPrivateKey(), let identity = identity(for: certificate, privateKey: privateKey) {
            return identity
        }

        let privateKey: SecKey
        if let existing = existingPrivateKey() {
            privateKey = existing
        } else {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecPrivateKeyAttrs: [
                    kSecAttrIsPermanent: true,
                    kSecAttrApplicationTag: keyTag,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ],
            ]
            var error: Unmanaged<CFError>?
            guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw error?.takeRetainedValue() ?? IdentityError.keyCreation
            }
            privateKey = generated
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw IdentityError.publicKey
        }

        let certificateData = try SelfSignedCertificate.make(publicKey: publicBytes, signingKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw IdentityError.certificate
        }
        let addStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: "SendFile over WiFi device identity",
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychain(addStatus)
        }
        guard let identity = identity(for: certificate, privateKey: privateKey) else { throw IdentityError.identity }
        return identity
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func existingCertificate() -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: "SendFile over WiFi device identity",
            kSecReturnRef: true,
        ] as CFDictionary, &result)
        return status == errSecSuccess ? (result as! SecCertificate) : nil
    }

    private static func existingPrivateKey() -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef: true,
        ] as CFDictionary, &result)
        return status == errSecSuccess ? (result as! SecKey) : nil
    }

    private static func identity(for certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
        SecIdentityCreate(nil, certificate, privateKey)
    }

    enum IdentityError: Error {
        case keyCreation, publicKey, certificate, identity
        case keychain(OSStatus)
    }
}

private enum SelfSignedCertificate {
    static func make(publicKey: Data, signingKey: SecKey) throws -> Data {
        let signatureAlgorithm = sequence(oid("1.2.840.10045.4.3.2"))
        let subject = name("SendFile over WiFi")
        let serial = Data((0..<16).map { _ in UInt8.random(in: 1...255) })
        let validity = sequence(utcTime(Date().addingTimeInterval(-60)), utcTime(Date().addingTimeInterval(60 * 60 * 24 * 3650)))
        let publicKeyInfo = sequence(
            sequence(oid("1.2.840.10045.2.1"), oid("1.2.840.10045.3.1.7")),
            bitString(publicKey)
        )
        let tbs = sequence(
            tagged(0xA0, integer(Data([2]))),
            integer(serial),
            signatureAlgorithm,
            subject,
            validity,
            subject,
            publicKeyInfo
        )
        var error: Unmanaged<CFError>?
        guard let rawSignature = SecKeyCreateSignature(signingKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? DeviceIdentity.IdentityError.certificate
        }
        // SecKey в варианте X9.62 возвращает DER-представление ECDSA-подписи.
        // Сертификат содержит его напрямую внутри BIT STRING.
        return sequence(tbs, signatureAlgorithm, bitString(rawSignature))
    }

    private static func name(_ value: String) -> Data {
        sequence(set(sequence(oid("2.5.4.3"), utf8String(value))))
    }

    private static func sequence(_ values: Data...) -> Data { tagged(0x30, values.reduce(Data(), +)) }
    private static func set(_ value: Data) -> Data { tagged(0x31, value) }
    private static func tagged(_ tag: UInt8, _ value: Data) -> Data { Data([tag]) + length(value.count) + value }
    private static func bitString(_ value: Data) -> Data { tagged(0x03, Data([0]) + value) }
    private static func utf8String(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }
    private static func integer(_ value: Data) -> Data {
        let normalized = value.first.map { $0 & 0x80 == 0 ? value : Data([0]) + value } ?? Data([0])
        return tagged(0x02, normalized)
    }
    private static func oid(_ value: String) -> Data {
        let parts = value.split(separator: ".").compactMap { UInt64($0) }
        var bytes = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) { bytes.append(contentsOf: base128(part)) }
        return tagged(0x06, bytes)
    }
    private static func base128(_ value: UInt64) -> [UInt8] {
        var result = [UInt8(value & 0x7f)]
        var remaining = value >> 7
        while remaining > 0 {
            result.insert(UInt8(remaining & 0x7f) | 0x80, at: 0)
            remaining >>= 7
        }
        return result
    }
    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }
}

