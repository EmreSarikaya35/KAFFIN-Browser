import CommonCrypto
import Foundation
import Security

/// Opens the passwords Chromium browsers save on macOS, once the user allows access to their Keychain item.
public enum ChromiumPasswords {
    private static let prefixes = [Data("v10".utf8), Data("v11".utf8)]

    /// macOS asks the user before it hands this item to KAFFIN.
    public static func key(service: String, account: String) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let secret = result as? Data else { throw KeychainError(status: status) }
        return try derivedKey(from: secret)
    }

    static func derivedKey(from secret: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { output in
            secret.withUnsafeBytes { password in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: CChar.self).baseAddress,
                        secret.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw KeychainError(status: errSecDecode) }
        return key
    }

    /// Returns nil for anything that is not a value Chromium encrypted with this key.
    public static func decrypt(_ value: Data, key: Data) -> String? {
        guard prefixes.contains(where: value.starts(with:)) else { return nil }
        let cipher = value.dropFirst(3)
        let initialVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            cipher.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    initialVector.withUnsafeBytes { vector in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            vector.baseAddress,
                            cipherBytes.baseAddress,
                            cipher.count,
                            outputBytes.baseAddress,
                            capacity,
                            &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(length), encoding: .utf8)
    }
}
