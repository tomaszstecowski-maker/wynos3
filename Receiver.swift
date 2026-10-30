import Foundation
import Network
import Photos

/// Nasłuch na porcie 47820. Po kablu połączenie przychodzi przez usługę USB Apple (usbmux)
/// jako połączenie lokalne (127.0.0.1 / ::1), przez Wi-Fi – z adresu komputera w sieci.
/// Zasada „domyślnie odmawiaj”: kabel = zaufany; sieć = tylko sparowany komputer, po uwierzytelnieniu,
/// cały ruch szyfrowany (AES-256-GCM).
final class Receiver {
    static let port: UInt16 = 47820
    static let serviceType = "_wynos._tcp"
    static let maxSessions = 8

    private let model: AppModel
    private let saver: PhotoSaver
    private let queue = DispatchQueue(label: "pl.tomstec.wynos.listener")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let exporter = LibraryExporter()
    private var restartScheduled = false
    private var authFailures: [String: (count: Int, since: Date)] = [:]
    // zgoda na kopię pamiętana chwilę dla tego samego komputera (podgląd → pobieranie bez drugiego pytania)
    private let consentLock = NSLock()
    private var consents: [String: Date] = [:]
    static let consentWindow: TimeInterval = 15 * 60

    func rememberPull(_ pc: String) {
        guard !pc.isEmpty else { return }
        consentLock.lock(); consents[pc] = Date(); consentLock.unlock()
    }

    func recentPull(_ pc: String) -> Bool {
        guard !pc.isEmpty else { return false }
        consentLock.lock(); defer { consentLock.unlock() }
        guard let d = consents[pc] else { return false }
        return Date().timeIntervalSince(d) < Receiver.consentWindow
    }

    func forgetPulls() {
        consentLock.lock(); consents.removeAll(); consentLock.unlock()
    }

    init(model: AppModel, saver: PhotoSaver) {
        self.model = model
        self.saver = saver
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Zmiana nazwy / trybu / pytania o zgodę – nowe ogłoszenie w sieci (Bonjour);
    /// połączenia niedozwolone w nowym trybie są zamykane.
    func settingsChanged() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            let mode = self.model.shared.mode
            for s in self.sessions.values where (s.viaUSB && !mode.allowsCable) || (!s.viaUSB && !mode.allowsWifi) {
                s.closeFromOutside()
            }
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.startOnQueue() }
        }
    }

    /// „Odśwież połączenie”: nasłuch i ogłoszenie w sieci od nowa, zerwane / wiszące połączenia zamykane.
    func restart(closeAll: Bool) {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.authFailures.removeAll()
            if closeAll { for s in self.sessions.values { s.closeFromOutside() } }
            self.queue.asyncAfter(deadline: .now() + 0.4) { self.startOnQueue() }
        }
    }

    func stopPulls() {
        forgetPulls()                     // „Zatrzymaj” na telefonie = następnym razem znów zapytaj
        queue.async { for s in self.sessions.values { s.stopPull() } }
    }

    func closeSessions(pc: String) {
        queue.async { for s in self.sessions.values where s.pcID == pc { s.closeFromOutside() } }
    }

    /// Nieudane uwierzytelnienia z jednego adresu: po 5 w ciągu 10 minut – blokada na 10 minut.
    func noteAuthFailure(_ host: String) {
        queue.async {
            let now = Date()
            var e = self.authFailures[host] ?? (0, now)
            if now.timeIntervalSince(e.since) > 600 { e = (0, now) }
            e.count += 1
            self.authFailures[host] = e
        }
    }

    private func blocked(_ host: String) -> Bool {
        guard let e = authFailures[host] else { return false }
        if Date().timeIntervalSince(e.since) > 600 {
            authFailures.removeValue(forKey: host)
            return false
        }
        return e.count >= 5
    }

    /// Rekord TXT usługi Bonjour – tylko to, co potrzebne do listy urządzeń (bez identyfikatorów sprzętu).
    private func txtRecord() -> Data {
        let s = model.shared
        let pairs = ["name": String(s.name.prefix(40)), "model": model.device.model, "id": model.device.installID,
                     "ask": s.ask ? "1" : "0", "v": "3", "secure": "1"]
        var data = Data()
        for (key, value) in pairs {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = Array(entry.prefix(255)) }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    private func startOnQueue() {
        if let current = listener {
            switch current.state {
            case .ready, .setup, .waiting:
                return
            default:
                current.cancel()
                listener = nil
            }
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: Receiver.port) else { return }
            let l = try NWListener(using: params, on: port)
            if model.shared.mode.allowsWifi {
                // widoczność w sieci domowej (jak AirPrint) – WynOs na komputerze znajdzie telefon sam
                l.service = NWListener.Service(name: model.shared.name, type: Receiver.serviceType, domain: nil,
                                               txtRecord: txtRecord())
            }
            l.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            model.post { m in
                m.phase = .error
                m.listenerError = error.localizedDescription
            }
            scheduleRestart()
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            model.post { m in
                m.listenerError = ""
                if m.connections == 0 && m.phase != .finished { m.phase = .waiting }
            }
        case .failed(let error):
            model.post { m in
                m.phase = .error
                m.listenerError = error.localizedDescription
            }
            listener?.cancel()
            listener = nil
            scheduleRestart()
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.restartScheduled = false
            self.startOnQueue()
        }
    }

    private func accept(_ conn: NWConnection) {
        var usb = false
        var host = ""
        if case let .hostPort(h, _) = conn.endpoint {
            host = "\(h)".replacingOccurrences(of: "::ffff:", with: "")
            usb = host.hasPrefix("127.") || host == "::1" || host.hasPrefix("::1%") || host.contains("%lo0")
        }
        let mode = model.shared.mode
        // domyślnie odmawiamy: kabel tylko w trybie z kablem, sieć tylko w trybie z Wi-Fi
        if (usb && !mode.allowsCable) || (!usb && !mode.allowsWifi) || sessions.count >= Receiver.maxSessions
            || (!usb && blocked(host)) {
            conn.cancel()
            return
        }
        let session = Session(connection: conn, model: model, saver: saver, exporter: exporter, viaUSB: usb,
                              host: host, receiver: self)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in
            self?.queue.async { self?.sessions.removeValue(forKey: key) }
        }
        session.start()
    }
}

/// Jedno połączenie z komputerem. Protokół: 4 bajty długości (big-endian) + JSON;
/// po {"t":"file","size":N} przychodzi N bajtów pliku. Przez Wi-Fi wszystko w rekordach AES-GCM.
final class Session {
    private struct Incoming {
        let id: Int
        let name: String
        let kind: String
        let date: Date?
        let group: String?
        let last: Bool
        let url: URL
        let handle: FileHandle?
        var remaining: Int64
        var failed: Bool
        var reason: String
    }

    static let maxJSON = 1_000_000
    static let maxFile: Int64 = 200 * 1024 * 1024 * 1024
    static let reserve: Int64 = 300 * 1024 * 1024        // zostaw w telefonie co najmniej tyle miejsca
    static let idleLimit: TimeInterval = 300

    var onClose: (() -> Void)?
    let viaUSB: Bool
    private(set) var pcID = ""

    private let conn: NWConnection
    private let model: AppModel
    private let saver: PhotoSaver
    private let exporter: LibraryExporter
    private let host: String
    private weak var receiver: Receiver?
    private let q = DispatchQueue(label: "pl.tomstec.wynos.session")
    private let sessionID = String(UUID().uuidString.prefix(8))
    // strumień: surowe (zaszyfrowane) bajty i odszyfrowany tekst z wskaźnikiem odczytu (bez kopiowania)
    private var raw = Data()
    private var buf = Data()
    private var pos = 0
    private var box: SecureBox?
    private var authed = false
    private var nonceMe = Data()
    private var noncePC = Data()
    private var file: Incoming?
    private var sinkLeft: Int64 = 0          // test prędkości komputer → iPhone: dane odbierane i od razu wyrzucane
    private var closed = false
    private var counted = false
    private var accepted = false
    private var offerOpen = false
    private var peer = ""
    private var pendingAcks = 0
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    // kopia na komputer
    private var pullAllowed = false
    private var scanEnded = false
    private var deleteIDs: [String] = []          // oryginały do usunięcia (lista przychodzi w paczkach)
    private var didList = false
    private var getQueue: [(String, Bool)] = []        // (id, wolno z iCloud)
    private var exporting = false
    private var ready: [(String, LibraryExporter.Result)] = []
    private var streaming = false
    private var cancel = LibraryExporter.Cancel()
    private var totalBytes: Int64 = 0
    private var reportedBytes: Int64 = 0
    private var lastPost = Date.distantPast
    private var window: [(Date, Int64)] = []

    init(connection: NWConnection, model: AppModel, saver: PhotoSaver, exporter: LibraryExporter, viaUSB: Bool,
         host: String, receiver: Receiver) {
        self.conn = connection
        self.model = model
        self.saver = saver
        self.exporter = exporter
        self.viaUSB = viaUSB
        self.host = host
        self.receiver = receiver
    }

    private var trusted: Bool { viaUSB || authed }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.q.async { self?.close() }
            default:
                break
            }
        }
        conn.start(queue: q)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.checkIdle() }
        t.resume()
        idleTimer = t
        receive()
    }

    func closeFromOutside() {
        q.async { self.close() }
    }

    func stopPull() {
        q.async { if self.pullAllowed { self.close() } }
    }

    /// Bezczynne połączenie (nic nie przychodzi, nic nie trwa) jest zamykane po 5 minutach.
    private func checkIdle() {
        let busy = file != nil || exporting || streaming || !ready.isEmpty || pendingAcks > 0 || offerOpen
        if !busy && Date().timeIntervalSince(lastActivity) > Session.idleLimit {
            close()
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lastActivity = Date()
                self.ingest(data)
                self.process()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.closed {
                self.receive()
            }
        }
    }

    /// Dane z sieci -> tekst protokołu (Wi-Fi: odszyfrowanie rekordów).
    private func ingest(_ data: Data) {
        guard let box = box else {
            buf.append(data)
            return
        }
        raw.append(data)
        decryptRecords(box)
    }

    private func decryptRecords(_ box: SecureBox) {
        var off = 0
        let r = raw
        let base = r.startIndex
        while r.count - off >= 4 {
            let len = Int(r[base + off]) << 24 | Int(r[base + off + 1]) << 16 | Int(r[base + off + 2]) << 8 | Int(r[base + off + 3])
            guard len >= 28, len <= SecureBox.recordMax + 64 else { close(); return }
            guard r.count - off >= 4 + len else { break }
            do {
                buf.append(try box.open(r.subdata(in: (base + off + 4)..<(base + off + 4 + len))))
            } catch {
                close()
                return
            }
            off += 4 + len
        }
        raw = off >= r.count ? Data() : r.subdata(in: (base + off)..<r.endIndex)
    }

    private var available: Int { buf.count - pos }

    private func compact() {
        if pos > 0 && (pos >= buf.count || pos > 4 * 1024 * 1024) {
            buf = pos >= buf.count ? Data() : buf.subdata(in: (buf.startIndex + pos)..<buf.endIndex)
            pos = 0
        }
    }

    // MARK: - przetwarzanie strumienia

    private func process() {
        defer { compact() }
        while !closed {
            if sinkLeft > 0 {
                if available == 0 { return }
                let n = Int(min(Int64(available), sinkLeft))
                pos += n
                sinkLeft -= Int64(n)
                lastActivity = Date()
                if sinkLeft == 0 { send(["t": "sunk"]) }
                continue
            }
            if var f = file {
                if available == 0 { return }
                let n = Int(min(Int64(available), f.remaining))
                let start = buf.startIndex + pos
                if let h = f.handle, !f.failed {
                    do {
                        try h.write(contentsOf: buf[start..<(start + n)])
                    } catch {
                        f.failed = true
                        f.reason = T("Brak miejsca w telefonie", "Out of space on the phone")
                    }
                }
                pos += n
                f.remaining -= Int64(n)
                addBytes(Int64(n))
                if f.remaining <= 0 {
                    file = nil
                    finishFile(f)
                } else {
                    file = f
                }
                continue
            }
            guard available >= 4 else { return }
            let s = buf.startIndex + pos
            let len = Int(buf[s]) << 24 | Int(buf[s + 1]) << 16 | Int(buf[s + 2]) << 8 | Int(buf[s + 3])
            guard len > 0, len < Session.maxJSON else {
                close()
                return
            }
            guard available >= 4 + len else { return }
            let json = buf.subdata(in: (s + 4)..<(s + 4 + len))
            pos += 4 + len
            guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let type = obj["t"] as? String else {
                close()
                return
            }
            handle(type, obj)
        }
    }

    private func handle(_ type: String, _ m: [String: Any]) {
        // przed uwierzytelnieniem w sieci wolno tylko się przywitać
        if !trusted && !["hello", "auth", "bye"].contains(type) {
            close()
            return
        }
        switch type {
        case "hello":
            handleHello(m)
        case "auth":
            handleAuth(m)
        case "pair":
            handlePair(m)
        case "album":
            guard accepted else { return }          // album dopiero po zgodzie na odbiór
            let album = String(((m["name"] as? String) ?? "").prefix(100))
            saver.setAlbum(album)
            model.post { mm in mm.albumName = album }
        case "ping":
            send(["t": "pong"])
        case "bye":
            send(["t": "bye"])
        case "offer":
            handleOffer(m)
        case "pull":
            handlePull(m)
        case "stats":
            let shared = model.shared
            exporter.stats(cancel: cancel) { [weak self] st in
                var out = st
                out["t"] = "stats"
                out["onWifi"] = shared.onWifi
                self?.q.async { self?.send(out) }
            }
        case "plan":
            guard pullAllowed else { return }
            model.post { mm in mm.scanning = false }
            let count = max(0, (m["count"] as? NSNumber)?.intValue ?? 0)
            let bytes = max(0, (m["bytes"] as? NSNumber)?.int64Value ?? 0)
            model.post { mm in
                mm.pullTotal = count
                mm.pullTotalBytes = bytes
            }
        case "speedtest":
            sendSpeedTest((m["bytes"] as? NSNumber)?.intValue ?? 8 * 1024 * 1024)
        case "sink":
            // komputer zaraz wyśle tyle bajtów próbnych danych – nic nie jest zapisywane
            let n = (m["size"] as? NSNumber)?.int64Value ?? 0
            guard n > 0, n <= 64 * 1024 * 1024, file == nil else { close(); return }
            sinkLeft = n
        case "icloudtest":
            let secs = min(max((m["seconds"] as? NSNumber)?.doubleValue ?? 15, 3), 30)
            exporter.cloudSpeed(seconds: secs, onWifi: model.shared.onWifi, cancel: cancel) { [weak self] r in
                var out: [String: Any] = ["t": "icloudtest"]
                switch r {
                case .allLocal: out["none"] = true
                case .noWifi: out["noWifi"] = true
                case .failed: out["failed"] = true
                case .bps(let b): out["bps"] = b
                }
                let reply = out
                self?.q.async { self?.send(reply) }
            }
        case "thumbs":
            guard pullAllowed else { close(); return }
            sendThumbs(m)
        case "list":
            guard pullAllowed else { close(); return }
            let photos = (m["photos"] as? Bool) ?? true
            let videos = (m["videos"] as? Bool) ?? true
            let albums = (m["albums"] as? Bool) ?? true
            model.post { mm in
                mm.scanning = true
                mm.scanListed = 0
                mm.scanTotal = 0
                mm.thumbsSent = 0
            }
            didList = true
            let mdl = self.model
            exporter.list(photos: photos, videos: videos, albums: albums, cancel: cancel, progress: { [weak self] n, total in
                mdl.post { mm in
                    mm.scanListed = n
                    mm.scanTotal = total
                }
                self?.q.async { self?.send(["t": "list-progress", "n": n, "total": total, "stage": total == 0 ? "albums" : "scan"]) }
            }) { [weak self] items, more, total in
                guard let self = self else { return }
                self.q.async {
                    self.send(["t": "list", "items": items, "more": more, "total": total])
                }
                if !more {
                    mdl.post { mm in
                        mm.scanListed = total
                        mm.scanTotal = total
                    }
                }
            }
        case "get":
            guard pullAllowed, let id = m["id"] as? String, getQueue.count < 64 else { close(); return }
            if !scanEnded {
                scanEnded = true
                model.post { mm in mm.scanning = false }
            }
            getQueue.append((id, (m["cloud"] as? Bool) ?? true))
            pumpExport()
        case "delete-ids":
            let ids = ((m["ids"] as? [Any]) ?? []).compactMap { $0 as? String }.map { String($0.prefix(200)) }
            guard deleteIDs.count + ids.count <= 500_000 else { close(); return }
            deleteIDs.append(contentsOf: ids)
        case "delete":
            handleDelete(m)
        case "file":
            if !accepted {
                close()          // bez przyjętej oferty nic nie zapisujemy
                return
            }
            startFile(m)
        default:
            break
        }
    }

    // MARK: - powitanie, uwierzytelnienie, parowanie

    private func fullHello() -> [String: Any] {
        let settings = model.shared
        return ["t": "hello",
                "v": 4,
                "secure": true,
                "name": settings.name,
                "ask": settings.ask,
                "cable": settings.mode.allowsCable,
                "wifi": settings.mode.allowsWifi,
                "pull": true,
                "model": model.device.model,
                "device": model.device.installID,
                "app": model.device.appVersion,
                "free": Session.freeSpace(),
                "onWifi": settings.onWifi,
                "photos": PhotoSaver.statusString()]
    }

    private func markActive(probe: Bool) {
        guard !probe, !counted else { return }
        counted = true
        let usb = viaUSB
        let from = peer
        model.post { mm in
            mm.connections += 1
            mm.viaUSB = usb
            mm.peerName = from
            if mm.phase == .finished || mm.phase == .waiting { mm.phase = .receiving }
        }
    }

    private var probeHello = false

    private func handleHello(_ m: [String: Any]) {
        guard nonceMe.isEmpty else { close(); return }        // jedno powitanie na połączenie
        probeHello = (m["probe"] as? Bool) ?? false
        peer = String(((m["name"] as? String) ?? "PC").prefix(40))
        pcID = String(((m["pc"] as? String) ?? "").prefix(64))
        nonceMe = PairStore.randomBytes(16)
        if viaUSB {
            markActive(probe: probeHello)
            send(fullHello())
            if !probeHello { refreshPairName() }
            return
        }
        guard let n64 = m["nonce"] as? String, let n = Data(base64Encoded: n64), n.count == 16 else {
            close()
            return
        }
        noncePC = n
        // niesparowany komputer w sieci dostaje tylko nazwę (do listy urządzeń)
        send(["t": "hello", "v": 4, "secure": true, "name": model.shared.name, "model": model.device.model,
              "device": model.device.installID, "paired": PairStore.key(for: pcID) != nil,
              "nonce": nonceMe.base64EncodedString()])
    }

    private func handleAuth(_ m: [String: Any]) {
        guard !viaUSB, !authed, noncePC.count == 16, let key = PairStore.key(for: pcID),
              let p64 = m["proof"] as? String, let proof = Data(base64Encoded: p64),
              Crypto.verify(key, "wynos-pc", proof, noncePC, nonceMe) else {
            receiver?.noteAuthFailure(host)
            close()
            return
        }
        let sessionKey = Crypto.mac(key, "wynos-session", noncePC, nonceMe)
        let b = SecureBox(sessionKey: sessionKey)
        // reszta bufora (jeśli już coś przyszło) to już rekordy szyfrowane
        if available > 0 {
            raw = buf.subdata(in: (buf.startIndex + pos)..<buf.endIndex)
        }
        buf = Data()
        pos = 0
        box = b
        authed = true
        markActive(probe: probeHello)
        send(fullHello())
        if !probeHello { refreshPairName() }
        if !raw.isEmpty { decryptRecords(b) }
    }

    /// Sparowany komputer mógł zmienić nazwę (np. dawna losowa -> nazwa z Windows) – zaktualizuj listę par.
    private func refreshPairName() {
        guard !pcID.isEmpty, !peer.isEmpty, PairStore.key(for: pcID) != nil else { return }
        let pc = pcID
        let name = peer
        if PairStore.all().first(where: { $0.id == pc })?.name == name { return }
        PairStore.rename(pc: pc, name: name)
        model.post { mm in mm.pairs = PairStore.all() }
    }

    private func handlePair(_ m: [String: Any]) {
        guard viaUSB, !pcID.isEmpty || (m["pc"] as? String) != nil else { close(); return }
        let pc = String(((m["pc"] as? String) ?? pcID).prefix(64))
        let name = String(((m["name"] as? String) ?? peer).prefix(40))
        guard !pc.isEmpty, !offerOpen else { return }
        offerOpen = true
        let offer = Offer(session: sessionID, kind: .pair, from: name, address: T("kabel USB", "USB cable"),
                          files: 0, bytes: 0, viaUSB: true) { [weak self] ok in
            guard let self = self else { return }
            self.q.async {
                self.offerOpen = false
                guard ok, let key = PairStore.newKey(), PairStore.save(pc: pc, name: name, key: key) else {
                    self.send(["t": "pair-denied"])
                    return
                }
                self.pcID = pc
                self.send(["t": "paired", "key": key.base64EncodedString(), "device": self.model.device.installID])
                self.model.post { mm in mm.refreshPairs() }
            }
        }
        model.post { mm in mm.enqueue(offer) }
    }

    // MARK: - odbiór plików

    private func handleOffer(_ m: [String: Any]) {
        guard !offerOpen else { return }
        let files = max(0, (m["files"] as? NSNumber)?.intValue ?? 0)
        let bytes = max(0, (m["bytes"] as? NSNumber)?.int64Value ?? 0)
        let report = { [weak self] in
            self?.model.post { mm in
                mm.receiveTotal += files
                mm.receiveTotalBytes += bytes
            }
        }
        if !model.shared.ask {
            accepted = true
            report()
            send(["t": "accepted"])
            return
        }
        offerOpen = true
        let offer = Offer(session: sessionID, kind: .receive,
                          from: String(((m["from"] as? String) ?? peer).prefix(40)),
                          address: viaUSB ? T("kabel USB", "USB cable") : host,
                          files: files, bytes: bytes, viaUSB: viaUSB) { [weak self] ok in
            guard let self = self else { return }
            self.q.async {
                self.offerOpen = false
                self.accepted = ok
                if ok { report() }
                self.send(["t": ok ? "accepted" : "rejected"])
            }
        }
        model.post { mm in mm.enqueue(offer) }
    }

    // MARK: - usuwanie oryginałów (przed wgraniem wersji skompresowanych)

    /// Komputer prosi o usunięcie oryginałów, które ma w kopii. Dwa potwierdzenia: w WynOs i w oknie systemu iOS.
    /// Usunięte trafiają do „Ostatnio usunięte” (30 dni) – aplikacja nie może tego albumu opróżnić.
    private func handleDelete(_ m: [String: Any]) {
        let ids = Array(Set(deleteIDs))
        deleteIDs = []
        guard !ids.isEmpty else {
            send(["t": "deleted", "ok": true, "count": 0, "missing": 0])
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            send(["t": "deleted", "ok": false, "count": 0, "err": T("Brak pełnego dostępu do Zdjęć.", "No full Photos access.")])
            return
        }
        guard !offerOpen else { return }
        offerOpen = true
        let offer = Offer(session: sessionID, kind: .delete, from: String(((m["from"] as? String) ?? peer).prefix(40)),
                          address: viaUSB ? T("kabel USB", "USB cable") : host,
                          files: ids.count, bytes: 0, viaUSB: viaUSB) { [weak self] ok in
            guard let self = self else { return }
            self.q.async {
                self.offerOpen = false
                guard ok else {
                    self.send(["t": "deleted", "ok": false, "count": 0, "declined": true,
                               "err": T("Odrzucone w WynOs na iPhonie.", "Declined in WynOs on the iPhone.")])
                    return
                }
                self.performDelete(ids)
            }
        }
        model.post { mm in mm.enqueue(offer) }
    }

    private func performDelete(_ ids: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            let found = assets.count
            guard found > 0 else {
                self?.q.async { self?.send(["t": "deleted", "ok": true, "count": 0, "missing": ids.count]) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                self?.q.async {
                    guard let self = self else { return }
                    if success {
                        self.send(["t": "deleted", "ok": true, "count": found, "missing": ids.count - found])
                    } else {
                        self.send(["t": "deleted", "ok": false, "count": 0, "declined": true,
                                   "err": error?.localizedDescription ?? T("Usuwanie anulowane.", "Deleting was cancelled.")])
                    }
                }
            }
        }
    }

    // MARK: - kopia na komputer (pobieranie z iPhone'a)

    private func handlePull(_ m: [String: Any]) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            send(["t": "pull-noaccess"])
            return
        }
        guard !offerOpen else { return }
        // ten sam komputer dostał zgodę przed chwilą (np. podgląd, a potem pobieranie) – nie pytamy drugi raz
        if receiver?.recentPull(pcID) == true {
            pullGranted()
            return
        }
        offerOpen = true
        // pobranie galerii – pytamy o zgodę
        let offer = Offer(session: sessionID, kind: .pull, from: String(((m["from"] as? String) ?? peer).prefix(40)),
                          address: viaUSB ? T("kabel USB", "USB cable") : host,
                          files: 0, bytes: 0, viaUSB: viaUSB) { [weak self] ok in
            guard let self = self else { return }
            self.q.async {
                self.offerOpen = false
                if ok {
                    self.receiver?.rememberPull(self.pcID)
                    self.pullGranted()
                } else {
                    self.send(["t": "pull-denied"])
                }
            }
        }
        model.post { mm in mm.enqueue(offer) }
    }

    private func pullGranted() {
        pullAllowed = true
        send(["t": "pull-ok"])
        let usb = viaUSB
        let from = peer
        model.post { mm in
            mm.pulls += 1
            mm.pulling = true
            mm.viaUSB = usb
            mm.peerName = from
            mm.phase = .receiving
            mm.pullTotal = 0
            mm.pullTotalBytes = 0
        }
    }

    // MARK: - test prędkości i podgląd

    /// Losowe dane do pomiaru prędkości (nic z biblioteki). Maks. 64 MB na prośbę.
    private func sendSpeedTest(_ n: Int) {
        let total = min(max(n, 0), 64 * 1024 * 1024)
        send(["t": "speed", "size": total])
        var block = Data(count: 1024 * 1024)
        block.withUnsafeMutableBytes { p in
            if let b = p.baseAddress { arc4random_buf(b, p.count) }
        }
        var left = total
        func pump() {
            guard left > 0 else { return }
            let part = left >= block.count ? block : block.prefix(left)
            left -= part.count
            sendData(part) { [weak self] ok in
                guard let self = self else { return }
                self.q.async {
                    guard ok, !self.closed else { return }
                    self.lastActivity = Date()
                    pump()
                }
            }
        }
        pump()
    }

    private func sendThumbs(_ m: [String: Any]) {
        let ids = ((m["ids"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(200).map { String($0.prefix(200)) }
        let size = (m["size"] as? NSNumber)?.intValue ?? 160
        exporter.thumbnails(ids: Array(ids), size: size, cancel: cancel, each: { [weak self] id, data in
            self?.q.async {
                guard let self = self, !self.closed else { return }
                self.send(["t": "thumb", "id": id, "size": data.count])
                self.sendData(data, nil)
                self.lastActivity = Date()
            }
        }, done: { [weak self] in
            self?.q.async { self?.send(["t": "thumbs-end"]) }
            let n = ids.count
            self?.model.post { mm in mm.thumbsSent += n }
        })
    }

    private func pumpExport() {
        guard !closed, !exporting, !getQueue.isEmpty, ready.count < 2 else { return }
        exporting = true
        let (id, allowCloud) = getQueue.removeFirst()
        let shared = model.shared
        exporter.export(id: id, allowCloud: allowCloud, onWifi: { shared.onWifi }, cancel: cancel) { [weak self] result in
            guard let self = self else {
                LibraryExporter.cleanup(result)
                return
            }
            self.q.async {
                self.exporting = false
                if self.closed {
                    LibraryExporter.cleanup(result)
                    return
                }
                self.ready.append((id, result))
                self.pumpStream()
                self.pumpExport()
            }
        }
    }

    private func pumpStream() {
        guard !closed, !streaming, !ready.isEmpty else { return }
        streaming = true
        let (id, result) = ready.removeFirst()
        switch result {
        case .notLocal:
            send(["t": "got", "id": id, "ok": false, "notLocal": true])
            streaming = false
            pumpStream()
            pumpExport()
        case .noWifi:
            send(["t": "got", "id": id, "ok": false, "noWifi": true,
                  "err": T("iPhone nie jest w sieci Wi-Fi – pliki z iCloud pobieram tylko przez Wi-Fi",
                           "The iPhone is not on Wi-Fi – iCloud files are downloaded over Wi-Fi only")])
            model.post { mm in mm.lastError = T("Połącz iPhone'a z Wi-Fi, aby pobrać pliki z iCloud",
                                                "Connect the iPhone to Wi-Fi to download iCloud files") }
            streaming = false
            pumpStream()
            pumpExport()
        case .failure(let message):
            send(["t": "got", "id": id, "ok": false, "err": message])
            model.post { mm in
                mm.failed += 1
                mm.lastError = message
            }
            streaming = false
            pumpStream()
            pumpExport()
        case .success(let files, let fromCloud):
            streamFiles(id, files, 0, fromCloud)
        }
    }

    private func streamFiles(_ id: String, _ files: [LibraryExporter.File], _ index: Int, _ fromCloud: Bool) {
        if index >= files.count {
            LibraryExporter.cleanup(.success(files, fromCloud: fromCloud))
            send(["t": "got", "id": id, "ok": true])
            model.post { mm in
                mm.exported += 1
                if fromCloud { mm.exportedFromCloud += 1 }
            }
            streaming = false
            pumpStream()
            pumpExport()
            return
        }
        let f = files[index]
        model.post { mm in
            mm.currentFile = f.name
            mm.currentFromCloud = fromCloud
        }
        sendFile(f.url, header: ["t": "res", "id": id, "i": f.index, "name": f.name, "size": f.size]) { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                LibraryExporter.cleanup(.success(files, fromCloud: fromCloud))
                self.close()
                return
            }
            self.streamFiles(id, files, index + 1, fromCloud)
        }
    }

    /// Wysyła plik kawałkami (kolejny kawałek dopiero, gdy poprzedni wyszedł – bez zapychania pamięci).
    private func sendFile(_ url: URL, header: [String: Any], done: @escaping (Bool) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            done(false)
            return
        }
        send(header)
        func pump() {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            } catch {
                try? handle.close()
                done(false)
                return
            }
            if chunk.isEmpty {
                try? handle.close()
                done(true)
                return
            }
            sendData(chunk) { [weak self] ok in
                guard let self = self else { return }
                self.q.async {
                    if !ok || self.closed {
                        try? handle.close()
                        done(false)
                        return
                    }
                    self.lastActivity = Date()
                    self.addBytes(Int64(chunk.count))
                    pump()
                }
            }
        }
        pump()
    }

    private func startFile(_ m: [String: Any]) {
        let id = (m["id"] as? NSNumber)?.intValue ?? 0
        let rawName = (m["name"] as? String) ?? "plik"
        let name = String((rawName as NSString).lastPathComponent.prefix(200))
        let size = (m["size"] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= Session.maxFile else {
            close()
            return
        }
        let kind = (m["kind"] as? String) == "video" ? "video" : "photo"
        var date: Date?
        if let d = (m["date"] as? NSNumber)?.doubleValue, d.isFinite, d > 0, d < Date().timeIntervalSince1970 + 172_800 {
            date = Date(timeIntervalSince1970: d)
        }
        let group = (m["group"] as? String).map { "\(sessionID)-\($0.prefix(32))" }
        let last = (m["last"] as? Bool) ?? true
        let ext = String((name as NSString).pathExtension.lowercased().prefix(8))
        let url = PhotoSaver.incomingDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        var handle: FileHandle?
        var reason = ""
        if Session.freeSpace() < size + Session.reserve {
            reason = T("Za mało miejsca w telefonie", "Not enough space on the phone")
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            if handle == nil { reason = T("Nie można zapisać pliku w telefonie", "Cannot write the file on the phone") }
        }
        let f = Incoming(id: id, name: name, kind: kind, date: date, group: group, last: last, url: url,
                         handle: handle, remaining: size, failed: handle == nil, reason: reason)
        model.post { mm in
            mm.currentFile = name
            mm.currentFromCloud = false
        }
        if size <= 0 {
            finishFile(f)
        } else {
            file = f
        }
    }

    private func finishFile(_ f: Incoming) {
        try? f.handle?.close()
        model.post { mm in mm.received += 1 }
        if f.failed {
            try? FileManager.default.removeItem(at: f.url)
            let err = f.reason.isEmpty ? T("Nie udało się zapisać pliku w telefonie", "Could not write the file on the phone") : f.reason
            send(["t": "ack", "id": f.id, "ok": false, "err": err])
            model.post { mm in
                mm.failed += 1
                mm.lastError = "\(f.name): \(err)"
            }
            return
        }
        let item = PhotoSaver.Item(id: f.id, url: f.url, name: f.name, kind: f.kind, date: f.date,
                                   group: f.group, last: f.last)
        pendingAcks += 1
        saver.add(item) { [weak self] results in
            guard let self = self else { return }
            self.q.async {
                for r in results {
                    self.pendingAcks = max(0, self.pendingAcks - 1)
                    self.send(["t": "ack", "id": r.id, "ok": r.ok, "err": r.err])
                }
            }
        }
    }

    // MARK: - wysyłanie / statystyki

    private func send(_ obj: [String: Any]) {
        guard !closed, let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        sendData(frame, nil)
    }

    /// Wysyła dane (Wi-Fi: zaszyfrowane). Wywoływane zawsze z kolejki sesji – kolejność rekordów zachowana.
    private func sendData(_ data: Data, _ done: ((Bool) -> Void)?) {
        guard !closed else { done?(false); return }
        var out = data
        if let box = box {
            guard let sealed = try? box.seal(data) else { done?(false); close(); return }
            out = sealed
        }
        conn.send(content: out, completion: .contentProcessed { error in done?(error == nil) })
    }

    private func addBytes(_ n: Int64) {
        totalBytes += n
        let now = Date()
        guard now.timeIntervalSince(lastPost) > 0.25 else { return }
        lastPost = now
        window.append((now, totalBytes))
        while let firstSample = window.first, now.timeIntervalSince(firstSample.0) > 3, window.count > 2 {
            window.removeFirst()
        }
        var bps: Double = 0
        if let firstSample = window.first {
            let dt = now.timeIntervalSince(firstSample.0)
            if dt > 0.2 { bps = Double(totalBytes - firstSample.1) / dt }
        }
        let delta = totalBytes - reportedBytes
        reportedBytes = totalBytes
        model.post { mm in
            mm.speed = bps
            mm.bytes += delta
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        cancel.cancel()
        if let f = file {
            try? f.handle?.close()
            try? FileManager.default.removeItem(at: f.url)
            file = nil
        }
        saver.dropGroups(session: sessionID)
        for (_, result) in ready { LibraryExporter.cleanup(result) }
        ready.removeAll()
        getQueue.removeAll()
        conn.cancel()
        let sid = sessionID
        let wasPulling = pullAllowed
        let wasScanning = didList && !scanEnded
        let wasCounted = counted
        let delta = totalBytes - reportedBytes
        reportedBytes = totalBytes
        model.post { mm in
            mm.dropOffers(session: sid)
            if wasPulling {
                mm.pulls = max(0, mm.pulls - 1)
                mm.pulling = mm.pulls > 0
            }
            if wasScanning || !mm.pulling { mm.scanning = false }
            mm.bytes += delta
            if wasCounted { mm.connections = max(0, mm.connections - 1) }
            mm.speed = 0
            if mm.connections == 0 {
                mm.phase = mm.received > 0 || mm.exported > 0 ? .finished : .waiting
                mm.currentFile = ""
            }
        }
        onClose?()
    }

    static func freeSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        return 0
    }
}
