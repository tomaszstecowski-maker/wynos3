import Foundation
import Photos
import UIKit

/// Eksport biblioteki Zdjęć do komputera (kopia oryginałów).
/// Oryginały, których nie ma w telefonie („Optymalizuj miejsce”), są pobierane z iCloud po kolei –
/// w telefonie potrzeba miejsca tylko na jeden plik naraz.
final class LibraryExporter {
    struct File {
        let index: Int
        let name: String
        let url: URL
        let size: Int64
    }

    enum Result {
        case success([File], fromCloud: Bool)
        case failure(String)
        case notLocal           // komputer prosił tylko o pliki z telefonu – ten jest w iCloud
        case noWifi             // plik w iCloud, a telefon nie jest w Wi-Fi (nie używamy sieci komórkowej)
    }

    /// Przerwanie listy / eksportu (np. komputer się rozłączył albo naciśnięto „Zatrzymaj”).
    final class Cancel {
        private let lock = NSLock()
        private var _flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _flag }
        func cancel() { lock.lock(); _flag = true; lock.unlock() }
    }

    static let tmpDir: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// iCloud: brak nowych danych przez tyle sekund = przerwij ten plik (zamiast czekać w nieskończoność).
    static let stallTimeout: TimeInterval = 120
    static let minFreeSpace: Int64 = 500 * 1024 * 1024

    private let exportQ = DispatchQueue(label: "pl.tomstec.wynos.export", qos: .userInitiated)

    /// Oryginalne pliki zdjęcia/filmu (bez wersji edytowanych): zdjęcie, film, film Live Photo, RAW, dźwięk.
    static func resources(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = [.photo, .video, .pairedVideo, .alternatePhoto, .audio]
        let picked = all.filter { wanted.contains($0.type) }
        if !picked.isEmpty { return picked }
        return all.filter { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
    }

    // MARK: - rozmiar i dostępność pliku (klucze KVC odczytywane ostrożnie – gdy ich nie ma, wynik nieznany)

    private static func kv(_ r: PHAssetResource, _ keys: [String]) -> Any? {
        for key in keys where r.responds(to: NSSelectorFromString(key)) {
            return r.value(forKey: key)
        }
        return nil
    }

    static func size(of r: PHAssetResource) -> Int64? {
        (kv(r, ["fileSize"]) as? NSNumber)?.int64Value
    }

    /// true = plik jest w telefonie, false = tylko w iCloud, nil = nie wiadomo.
    static func isLocal(_ r: PHAssetResource) -> Bool? {
        (kv(r, ["locallyAvailable", "isLocallyAvailable"]) as? NSNumber)?.boolValue
    }

    static func isLocal(_ res: [PHAssetResource]) -> Bool? {
        var unknown = false
        for r in res {
            guard let l = isLocal(r) else { unknown = true; continue }
            if !l { return false }
        }
        return unknown ? nil : true
    }

    private static func libraryFetch() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        return PHAsset.fetchAssets(with: opts)
    }

    /// Podsumowanie biblioteki dla komputera: ile plików i ile zajmują – w telefonie i tylko w iCloud.
    func stats(cancel: Cancel, done: @escaping ([String: Any]) -> Void) {
        exportQ.async {
            var count = 0, photos = 0, videos = 0, local = 0, cloud = 0
            var bytes: Int64 = 0, localBytes: Int64 = 0, cloudBytes: Int64 = 0
            LibraryExporter.libraryFetch().enumerateObjects { asset, _, stop in
                if cancel.isCancelled { stop.pointee = true; return }
                let isVideo = asset.mediaType == .video
                if asset.mediaType != .image && !isVideo { return }
                let res = LibraryExporter.resources(for: asset)
                if res.isEmpty { return }
                var size: Int64 = 0
                for r in res { size += LibraryExporter.size(of: r) ?? 0 }
                count += 1
                if isVideo { videos += 1 } else { photos += 1 }
                bytes += size
                if LibraryExporter.isLocal(res) == false {
                    cloud += 1
                    cloudBytes += size
                } else {
                    local += 1
                    localBytes += size
                }
            }
            done(["count": count, "bytes": bytes, "local": local, "cloud": cloud, "local_bytes": localBytes,
                  "cloud_bytes": cloudBytes, "photos": photos, "videos": videos])
        }
    }

    /// Lista wszystkich zdjęć i filmów (w paczkach po 500). Albumy liczone tylko, gdy komputer ich potrzebuje.
    // MARK: - lista biblioteki (z pamięcią podręczną)

    /// Ostatnia pełna lista – drugi i kolejny skan z komputera są natychmiastowe,
    /// dopóki w bibliotece Zdjęć nic się nie zmieni (obserwator zmian ją unieważnia).
    private let cacheLock = NSLock()
    private var cachedItems: [[String: Any]]?
    private var cachedAlbums = false
    private var watcher: LibraryWatcher?

    private func invalidateCache() {
        cacheLock.lock(); cachedItems = nil; cacheLock.unlock()
    }

    /// Jeden wpis listy dla komputera (nil = nie zdjęcie/film albo brak zasobów).
    private static func entry(_ asset: PHAsset, album: String?) -> [String: Any]? {
        let isVideo = asset.mediaType == .video
        if asset.mediaType != .image && !isVideo { return nil }
        let res = LibraryExporter.resources(for: asset)
        if res.isEmpty { return nil }
        var names: [[String: Any]] = []
        for (i, r) in res.enumerated() {
            var e: [String: Any] = ["i": i, "name": r.originalFilename]
            if let size = LibraryExporter.size(of: r) { e["size"] = size }
            names.append(e)
        }
        var item: [String: Any] = ["id": asset.localIdentifier, "kind": isVideo ? "video" : "photo", "res": names]
        if let local = LibraryExporter.isLocal(res) { item["local"] = local }
        if let d = asset.creationDate { item["date"] = d.timeIntervalSince1970 }
        if let album = album { item["album"] = album }
        return item
    }

    /// Lista wszystkich zdjęć i filmów dla komputera – w paczkach po 500, z postępem.
    /// Zasoby czytane równolegle na wszystkich rdzeniach (to najwolniejsza część), wynik zapamiętany.
    func list(photos: Bool, videos: Bool, albums: Bool, cancel: Cancel,
              progress: @escaping (Int, Int) -> Void = { _, _ in },
              chunk: @escaping ([[String: Any]], Bool, Int) -> Void) {
        exportQ.async {
            if self.watcher == nil {
                self.watcher = LibraryWatcher { [weak self] in self?.invalidateCache() }
            }
            self.cacheLock.lock()
            var items = (self.cachedItems != nil && (self.cachedAlbums || !albums)) ? self.cachedItems : nil
            self.cacheLock.unlock()
            if items == nil {
                var albumOf: [String: String] = [:]
                if albums {
                    progress(0, 0)
                    let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
                    cols.enumerateObjects { collection, _, stop in
                        if cancel.isCancelled { stop.pointee = true; return }
                        let title = collection.localizedTitle ?? ""
                        if title.isEmpty { return }
                        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                            if albumOf[asset.localIdentifier] == nil { albumOf[asset.localIdentifier] = title }
                        }
                    }
                }
                if cancel.isCancelled { return }
                let all = LibraryExporter.libraryFetch()
                let total = all.count
                var out: [[String: Any]] = []
                out.reserveCapacity(total)
                var start = 0
                var lastProgress = Date.distantPast
                while start < total {
                    if cancel.isCancelled { return }
                    let end = min(total, start + 400)
                    var slots = [[String: Any]?](repeating: nil, count: end - start)
                    let base = start
                    let map = albumOf
                    slots.withUnsafeMutableBufferPointer { buf in
                        let ptr = buf            // każdy wątek pisze tylko do swojego miejsca
                        DispatchQueue.concurrentPerform(iterations: ptr.count) { k in
                            autoreleasepool {
                                let asset = all.object(at: base + k)
                                ptr[k] = LibraryExporter.entry(asset, album: map[asset.localIdentifier])
                            }
                        }
                    }
                    out.append(contentsOf: slots.compactMap { $0 })
                    start = end
                    if Date().timeIntervalSince(lastProgress) > 0.25 || start == total {
                        lastProgress = Date()
                        progress(start, total)
                    }
                }
                self.cacheLock.lock()
                self.cachedItems = out
                self.cachedAlbums = albums
                self.cacheLock.unlock()
                items = out
            }
            let list = (items ?? []).filter { it in
                let v = (it["kind"] as? String) == "video"
                return v ? videos : photos
            }
            let total = list.count
            var i = 0
            repeat {
                if cancel.isCancelled { return }
                let end = min(total, i + 500)
                chunk(Array(list[i..<end]), end < total, total)
                i = end
            } while i < total
        }
    }

    /// Zapisuje oryginały jednego zdjęcia/filmu do plików tymczasowych.
    /// allowCloud = false: tylko to, co jest w telefonie (reszta -> .notLocal, komputer poprosi o nią na końcu).
    /// Z iCloud pobieramy tylko przez Wi-Fi (onWifi), nigdy przez sieć komórkową.
    func export(id: String, allowCloud: Bool, onWifi: @escaping () -> Bool, cancel: Cancel,
                done: @escaping (Result) -> Void) {
        exportQ.async {
            if cancel.isCancelled {
                done(.failure(T("Przerwano", "Cancelled")))
                return
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                done(.failure(T("Tego pliku nie ma już w telefonie", "This item is no longer on the phone")))
                return
            }
            let res = LibraryExporter.resources(for: asset)
            let local = LibraryExporter.isLocal(res)
            if local == false && !allowCloud {
                done(.notLocal)
                return
            }
            if local == false && !onWifi() {
                done(.noWifi)
                return
            }
            if Session.freeSpace() < LibraryExporter.minFreeSpace {
                done(.failure(T("Za mało miejsca w telefonie na pobranie oryginału z iCloud",
                                "Not enough space on the phone to download the original from iCloud")))
                return
            }
            var files: [File] = []
            // nieznana dostępność + bez zgody na iCloud: próbujemy bez sieci; nie wyszło = pewnie jest w iCloud
            let network = allowCloud && (local != true) && onWifi()
            for (i, r) in res.enumerated() {
                let url = LibraryExporter.tmpDir.appendingPathComponent(UUID().uuidString)
                if let error = LibraryExporter.fetch(r, to: url, network: network, cancel: cancel) {
                    for f in files { try? FileManager.default.removeItem(at: f.url) }
                    try? FileManager.default.removeItem(at: url)
                    if local == nil && !network && !cancel.isCancelled {
                        done(allowCloud ? .noWifi : .notLocal)
                    } else {
                        done(.failure(error))
                    }
                    return
                }
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                files.append(File(index: i, name: (r.originalFilename as NSString).lastPathComponent,
                                  url: url, size: size))
            }
            done(.success(files, fromCloud: local == false))
        }
    }

    /// Pobiera jeden zasób do pliku. Strażnik: brak postępu przez `stallTimeout` s albo przerwanie
    /// = anulowanie prośby do iCloud. Zwraca opis błędu albo nil.
    private static func fetch(_ resource: PHAssetResource, to url: URL, network: Bool, cancel: Cancel) -> String? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return T("Nie można utworzyć pliku tymczasowego", "Cannot create a temporary file")
        }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = network       // pobierz oryginał z iCloud (tylko przez Wi-Fi)
        let lock = NSLock()
        var lastData = Date()
        var writeError: String?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        opts.progressHandler = { _ in
            lock.lock(); lastData = Date(); lock.unlock()
        }
        let manager = PHAssetResourceManager.default()
        let req = manager.requestData(for: resource, options: opts, dataReceivedHandler: { data in
            lock.lock(); lastData = Date(); lock.unlock()
            do {
                try handle.write(contentsOf: data)
            } catch {
                lock.lock(); writeError = T("Brak miejsca w telefonie", "Out of space on the phone"); lock.unlock()
            }
        }, completionHandler: { error in
            failure = error
            sem.signal()
        })
        var cancelledBy: String?
        while sem.wait(timeout: .now() + 1) == .timedOut {
            lock.lock()
            let idle = Date().timeIntervalSince(lastData)
            let wErr = writeError
            lock.unlock()
            if cancel.isCancelled {
                cancelledBy = T("Przerwano", "Cancelled")
            } else if idle > stallTimeout {
                cancelledBy = T("iCloud nie odpowiada – ten plik pominięto (spróbuj ponownie później)",
                                "iCloud does not respond – this item was skipped (try again later)")
            } else if let w = wErr {
                cancelledBy = w
            }
            if cancelledBy != nil {
                manager.cancelDataRequest(req)
                _ = sem.wait(timeout: .now() + 10)
                break
            }
        }
        try? handle.close()
        if let c = cancelledBy { return c }
        if let w = writeError { return w }
        if let e = failure { return e.localizedDescription }
        return nil
    }

    // MARK: - podgląd (miniatury) i test prędkości iCloud

    private let thumbQ = DispatchQueue(label: "pl.tomstec.wynos.thumbs", qos: .userInitiated)

    /// Miniatury JPEG dla podglądu na komputerze. Tylko to, co jest w telefonie (bez pobierania z iCloud –
    /// system ma małe podglądy także dla plików trzymanych w iCloud).
    func thumbnails(ids: [String], size: Int, cancel: Cancel, each: @escaping (String, Data) -> Void,
                    done: @escaping () -> Void) {
        thumbQ.async {
            let side = CGFloat(min(max(size, 64), 512))
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var byID: [String: PHAsset] = [:]
            assets.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
            let opts = PHImageRequestOptions()
            opts.isSynchronous = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false
            let mgr = PHImageManager.default()
            for id in ids {
                if cancel.isCancelled { break }
                guard let a = byID[id] else { continue }
                var out: Data?
                autoreleasepool {
                    mgr.requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                     options: opts) { img, _ in
                        out = img?.jpegData(compressionQuality: 0.7)
                    }
                }
                if out == nil {                      // brak dużego podglądu w telefonie – weź najmniejszy
                    let fast = PHImageRequestOptions()
                    fast.isSynchronous = true
                    fast.deliveryMode = .fastFormat
                    fast.isNetworkAccessAllowed = false
                    autoreleasepool {
                        mgr.requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                         options: fast) { img, _ in
                            out = img?.jpegData(compressionQuality: 0.7)
                        }
                    }
                }
                if let d = out { each(id, d) }
            }
            done()
        }
    }

    enum CloudTest {
        case allLocal       // wszystko jest w telefonie – nie ma czego mierzyć
        case noWifi
        case bps(Double)
        case failed
    }

    /// Mierzy, jak szybko iPhone pobiera oryginały z iCloud: pobiera do pamięci (maks. `seconds` s)
    /// jeden plik trzymany tylko w iCloud i od razu go odrzuca. Nic nie jest zapisywane ani wysyłane.
    func cloudSpeed(seconds: Double, onWifi: Bool, cancel: Cancel, done: @escaping (CloudTest) -> Void) {
        exportQ.async {
            var target: PHAssetResource?
            LibraryExporter.libraryFetch().enumerateObjects(options: .reverse) { asset, _, stop in
                if cancel.isCancelled { stop.pointee = true; return }
                for r in LibraryExporter.resources(for: asset)
                where LibraryExporter.isLocal(r) == false && (LibraryExporter.size(of: r) ?? 0) > 2_000_000 {
                    target = r
                    stop.pointee = true
                    return
                }
            }
            guard let r = target else { done(.allLocal); return }
            guard onWifi else { done(.noWifi); return }
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            let lock = NSLock()
            var got: Int64 = 0
            var first: Date?
            let sem = DispatchSemaphore(value: 0)
            let mgr = PHAssetResourceManager.default()
            let req = mgr.requestData(for: r, options: opts, dataReceivedHandler: { data in
                lock.lock()
                if first == nil { first = Date() }
                got += Int64(data.count)
                lock.unlock()
            }, completionHandler: { _ in sem.signal() })
            let end = Date().addingTimeInterval(seconds + 10)
            while sem.wait(timeout: .now() + 0.5) == .timedOut {
                lock.lock(); let f = first; lock.unlock()
                let limit = f.map { $0.addingTimeInterval(seconds) } ?? end
                if cancel.isCancelled || Date() > limit {
                    mgr.cancelDataRequest(req)
                    _ = sem.wait(timeout: .now() + 5)
                    break
                }
            }
            lock.lock(); let total = got; let f = first; lock.unlock()
            guard let start = f, total > 0 else { done(.failed); return }
            let dt = max(0.2, Date().timeIntervalSince(start))
            done(.bps(Double(total) / dt))
        }
    }

    static func cleanup(_ result: Result) {
        if case let .success(files, _) = result {
            for f in files { try? FileManager.default.removeItem(at: f.url) }
        }
    }
}

/// Obserwator zmian w bibliotece Zdjęć – unieważnia zapamiętaną listę.
final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
