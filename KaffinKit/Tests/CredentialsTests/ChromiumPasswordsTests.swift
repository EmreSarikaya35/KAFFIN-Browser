import Foundation
import Testing
@testable import Credentials

/// The expected values come from Python's PBKDF2 and the openssl tool, not from this code.
struct ChromiumPasswordsTests {
    private static func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    private let key = hex("a2b53d31770eef94e94ed19844dc81a6")
    private let cipher = hex("9893ea8bad7cfad72845a706972c5a63629b935c3e8ce264eecc4205a9dd9d81")

    @Test func derivesTheSameKeyAsChromium() throws {
        #expect(try ChromiumPasswords.derivedKey(from: Data("test-safe-storage".utf8)) == key)
    }

    @Test(arguments: ["v10", "v11"]) func decryptsAValue(prefix: String) {
        #expect(ChromiumPasswords.decrypt(Data(prefix.utf8) + cipher, key: key) == "correct horse ünlü")
    }

    @Test func refusesUnknownFormats() {
        #expect(ChromiumPasswords.decrypt(cipher, key: key) == nil)
        #expect(ChromiumPasswords.decrypt(Data("v20".utf8) + cipher, key: key) == nil)
    }

    @Test func wrongKeyNeverReturnsThePassword() {
        let wrong = Data(repeating: 1, count: 16)
        #expect(ChromiumPasswords.decrypt(Data("v10".utf8) + cipher, key: wrong) != "correct horse ünlü")
    }
}
