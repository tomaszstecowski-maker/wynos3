import CryptoKit
import Foundation
import Security

/// Sparowane komputery: losowy klucz 256-bit na komputer, w pęku kluczy iPhone'a
/// (tylko na tym urządzeniu, dostępny po pierwszym odblokowaniu, nie trafia do kopii iCloud).
enum PairStore {
    private static let service = "pl.tomstec.wynos.pairs"

    struct Pair: Identifiable {
        let id: String          // identyfikator instalacji WynOs na komputerze
        let name: String
    }

    static func key(for pc: String) -> SymmetricKey? {
        guard !pc.isEmpty else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: pc,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func save(pc: String, name: String, key: Data) -> Bool {
        remove(pc)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: pc,
                                   kSecAttrLabel as String: name,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecValueData as String: key]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Komputer przedstawia się teraz zwykłą nazwą (z Windows) – aktualizujemy zapisaną nazwę pary.
    static func rename(pc: String, name: String) {
        guard !pc.isEmpty, !name.isEmpty else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: pc]
        let attrs: [String: Any] = [kSecAttrLabel as String: name]
        SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    }

    static func remove(_ pc: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: pc]
        SecItemDelete(query as CFDictionary)
    }

    static func all() -> [Pair] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row[kSecAttrAccount as String] as? String else { return nil }
            return Pair(id: id, name: (row[kSecAttrLabel as String] as? String) ?? "PC")
        }.sorted { $0.name < $1.name }
    }

    static func newKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }
}

enum Crypto {
    static func mac(_ key: SymmetricKey, _ label: String, _ parts: Data...) -> Data {
        var msg = Data(label.utf8)
        for p in parts { msg.append(p) }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
    }

    /// Porównanie w stałym czasie (HMAC weryfikuje sam CryptoKit).
    static func verify(_ key: SymmetricKey, _ label: String, _ proof: Data, _ parts: Data...) -> Bool {
        var msg = Data(label.utf8)
        for p in parts { msg.append(p) }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: msg, using: key)
    }
}

/// Szyfrowanie AES-256-GCM ruchu Wi-Fi. Rekord: długość(4, big-endian) | nonce(12) | szyfrogram | znacznik(16).
/// Nonce = kierunek(4) + licznik(8): powtórzony, przestawiony lub zmieniony rekord jest odrzucany.
final class SecureBox {
    static let recordMax = 1024 * 1024
    private let key: SymmetricKey
    private var txCounter: UInt64 = 0
    private var rxCounter: UInt64 = 0
    private let txPrefix = Data("WPH>".utf8)     // telefon -> komputer
    private let rxPrefix = Data("WPC>".utf8)     // komputer -> telefon

    init(sessionKey: Data) {
        key = SymmetricKey(data: sessionKey)
    }

    enum BoxError: Error { case badRecord, order, auth }

    /// Szyfruje dowolną ilość danych (dzieli na rekordy po maks. 1 MB).
    func seal(_ plain: Data) throws -> Data {
        var out = Data()
        var offset = plain.startIndex
        repeat {
            let end = plain.index(offset, offsetBy: min(SecureBox.recordMax, plain.endIndex - offset))
            var nonceBytes = txPrefix
            withUnsafeBytes(of: txCounter.bigEndian) { nonceBytes.append(contentsOf: $0) }
            txCounter += 1
            let box = try AES.GCM.seal(plain[offset..<end], using: key, nonce: AES.GCM.Nonce(data: nonceBytes))
            let body = nonceBytes + box.ciphertext + box.tag
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(body)
            offset = end
        } while offset < plain.endIndex
        return out
    }

    /// Odszyfrowuje jeden rekord (bez 4 bajtów długości).
    func open(_ record: Data) throws -> Data {
        guard record.count >= 28 else { throw BoxError.badRecord }
        let r = Data(record)                     // indeksy od zera
        let nonceBytes = r.prefix(12)
        guard nonceBytes.prefix(4) == rxPrefix else { throw BoxError.order }
        var counter: UInt64 = 0
        for b in nonceBytes.suffix(8) { counter = (counter << 8) | UInt64(b) }
        guard counter == rxCounter else { throw BoxError.order }
        let tag = r.suffix(16)
        let ct = r.subdata(in: 12..<(r.count - 16))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: ct, tag: tag)
        guard let plain = try? AES.GCM.open(box, using: key) else { throw BoxError.auth }
        rxCounter += 1
        return plain
    }
}
