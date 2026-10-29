import Foundation
import Network
import Photos
import SwiftUI
import UIKit

/// Stałe informacje o telefonie (odczytane raz, na głównym wątku).
struct DeviceInfo {
    let model: String
    let installID: String       // losowy identyfikator tej instalacji (nie identyfikuje telefonu ani osoby)
    let appVersion: String

    static func current() -> DeviceInfo {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let defaults = UserDefaults.standard
        var id = defaults.string(forKey: "installID") ?? ""
        if id.isEmpty {
            id = UUID().uuidString
            defaults.set(id, forKey: "installID")
        }
        return DeviceInfo(model: machine, installID: id, appVersion: version)
    }

    /// Nazwa handlowa modelu, np. „iPhone16,1” -> „iPhone 15 Pro”.
    var marketingName: String {
        let names: [String: String] = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE", "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        ]
        if let n = names[model] { return n }
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }
}

/// Jak telefon przyjmuje pliki.
enum ReceiveMode: String, CaseIterable {
    case cable, wifi, both
    var allowsCable: Bool { self != .wifi }
    var allowsWifi: Bool { self != .cable }
}

/// Wygląd: jak w systemie / jasny / ciemny.
enum AppTheme: String, CaseIterable {
    case system, light, dark
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    var next: AppTheme {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

/// Ustawienia czytane z wątków sieciowych (bezpiecznie, pod blokadą).
final class SharedSettings {
    private let lock = NSLock()
    private var _name = ""
    private var _mode = ReceiveMode.both
    private var _ask = true
    private var _onWifi = false

    var name: String {
        get { lock.lock(); defer { lock.unlock() }; return _name }
        set { lock.lock(); _name = newValue; lock.unlock() }
    }
    var mode: ReceiveMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    var ask: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _ask }
        set { lock.lock(); _ask = newValue; lock.unlock() }
    }
    /// Telefon jest w sieci Wi-Fi (pliki z iCloud pobieramy tylko wtedy – nigdy przez sieć komórkową).
    var onWifi: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _onWifi }
        set { lock.lock(); _onWifi = newValue; lock.unlock() }
    }
}

/// Prośba komputera (jak w LocalSend – można przyjąć albo odrzucić). Prośby czekają w kolejce.
struct Offer: Identifiable {
    enum Kind { case receive, pull, pair, delete }
    let id = UUID()
    let session: String
    let kind: Kind
    let from: String
    let address: String
    let files: Int
    let bytes: Int64
    let viaUSB: Bool
    let answer: (Bool) -> Void
    var pull: Bool { kind == .pull }
}

/// Dawne losowe nazwy urządzenia (wersje do 3.1) – tylko po to, żeby je rozpoznać
/// i zastąpić nazwą modelu telefonu.
enum NameGenerator {
    static let names: [String: [String]] = [
        "pl": ["Szybki Delfin", "Spokojna Panda", "Odważny Orzeł", "Dzielny Łabędź", "Mądry Żółw", "Wesoła Wydra", "Bystry Sokół", "Polarny Niedźwiedź", "Złoty Lew", "Cichy Jeleń", "Zwinny Ryś", "Górski Żubr", "Pogodny Pingwin", "Leśny Bóbr", "Szybki Gepard", "Spokojny Wieloryb", "Dzielny Tygrys", "Zwinna Wiewiórka", "Wesoły Koliber", "Morska Foka"],
        "en": ["Swift Dolphin", "Calm Panda", "Brave Eagle", "Gentle Swan", "Wise Turtle", "Happy Otter", "Quick Falcon", "Polar Bear", "Golden Lion", "Quiet Deer", "Nimble Lynx", "Mountain Bison", "Sunny Penguin", "Forest Beaver", "Fast Cheetah", "Calm Whale", "Brave Tiger", "Nimble Squirrel", "Happy Hummingbird", "Ocean Seal"],
        "es": ["Delfín Veloz", "Panda Tranquilo", "Águila Valiente", "Cisne Sereno", "Tortuga Sabia", "Nutria Alegre", "Halcón Rápido", "Oso Polar", "León Dorado", "Ciervo Tranquilo", "Lince Ágil", "Pingüino Feliz", "Ballena Serena", "Tigre Valiente", "Colibrí Alegre", "Foca Marina"],
        "pt": ["Golfinho Veloz", "Panda Tranquilo", "Águia Corajosa", "Cisne Sereno", "Tartaruga Sábia", "Lontra Alegre", "Falcão Rápido", "Urso Polar", "Leão Dourado", "Cervo Tranquilo", "Lince Ágil", "Pinguim Feliz", "Baleia Serena", "Tigre Valente", "Beija-flor Alegre", "Foca Marinha"],
        "fr": ["Dauphin Rapide", "Panda Calme", "Aigle Courageux", "Cygne Serein", "Tortue Sage", "Loutre Joyeuse", "Faucon Agile", "Ours Polaire", "Lion Doré", "Cerf Paisible", "Lynx Agile", "Manchot Joyeux", "Baleine Sereine", "Tigre Courageux", "Colibri Joyeux", "Phoque des Mers"],
        "de": ["Schneller Delfin", "Ruhiger Panda", "Mutiger Adler", "Sanfter Schwan", "Weise Schildkröte", "Fröhlicher Otter", "Flinker Falke", "Eisbär", "Goldener Löwe", "Stiller Hirsch", "Flinker Luchs", "Fröhlicher Pinguin", "Ruhiger Wal", "Mutiger Tiger", "Fröhlicher Kolibri", "Meeresrobbe"],
        "it": ["Delfino Veloce", "Panda Tranquillo", "Aquila Coraggiosa", "Cigno Sereno", "Tartaruga Saggia", "Lontra Allegra", "Falco Rapido", "Orso Polare", "Leone Dorato", "Cervo Tranquillo", "Lince Agile", "Pinguino Felice", "Balena Serena", "Tigre Coraggiosa", "Colibrì Allegro", "Foca Marina"],
        "nl": ["Snelle Dolfijn", "Rustige Panda", "Dappere Adelaar", "Sierlijke Zwaan", "Wijze Schildpad", "Vrolijke Otter", "Vlugge Valk", "IJsbeer", "Gouden Leeuw", "Stil Hert", "Vlugge Lynx", "Vrolijke Pinguïn", "Rustige Walvis", "Dappere Tijger", "Vrolijke Kolibrie", "Zeehond"],
        "ru": ["Быстрый Дельфин", "Спокойная Панда", "Смелый Орёл", "Белый Лебедь", "Мудрая Черепаха", "Весёлая Выдра", "Быстрый Сокол", "Белый Медведь", "Золотой Лев", "Тихий Олень", "Ловкая Рысь", "Весёлый Пингвин", "Спокойный Кит", "Смелый Тигр", "Весёлая Колибри", "Морской Тюлень"],
        "uk": ["Швидкий Дельфін", "Спокійна Панда", "Сміливий Орел", "Білий Лебідь", "Мудра Черепаха", "Весела Видра", "Швидкий Сокіл", "Білий Ведмідь", "Золотий Лев", "Тихий Олень", "Спритна Рись", "Веселий Пінгвін", "Спокійний Кит", "Сміливий Тигр", "Весела Колібрі", "Морський Тюлень"],
        "tr": ["Hızlı Yunus", "Sakin Panda", "Cesur Kartal", "Zarif Kuğu", "Bilge Kaplumbağa", "Neşeli Su Samuru", "Çevik Şahin", "Kutup Ayısı", "Altın Aslan", "Sessiz Geyik", "Çevik Vaşak", "Mutlu Penguen", "Sakin Balina", "Cesur Kaplan", "Neşeli Sinek Kuşu", "Deniz Foku"],
        "id": ["Lumba-lumba Cepat", "Panda Tenang", "Elang Berani", "Angsa Anggun", "Penyu Bijak", "Berang-berang Ceria", "Alap-alap Lincah", "Beruang Kutub", "Singa Emas", "Rusa Tenang", "Lynx Lincah", "Penguin Ceria", "Paus Tenang", "Harimau Berani", "Kolibri Ceria", "Kupu-kupu Ceria"],
        "vi": ["Cá heo Nhanh", "Gấu trúc Điềm tĩnh", "Đại bàng Dũng cảm", "Thiên nga Duyên dáng", "Rùa Thông thái", "Rái cá Vui vẻ", "Chim ưng Nhanh nhẹn", "Gấu Bắc cực", "Sư tử Vàng", "Hươu Hiền hòa", "Linh miêu Nhanh nhẹn", "Chim cánh cụt Vui vẻ", "Cá voi Điềm tĩnh", "Hổ Dũng cảm", "Chim ruồi Vui vẻ", "Hải cẩu"],
        "zh": ["敏捷海豚", "安静熊猫", "勇敢雄鹰", "优雅天鹅", "智慧海龟", "快乐水獭", "迅捷猎隼", "北极熊", "金色狮子", "宁静小鹿", "灵巧猞猁", "快乐企鹅", "平静鲸鱼", "勇敢老虎", "快乐蜂鸟", "海洋海豹"],
        "ja": ["はやいイルカ", "おだやかなパンダ", "ゆうかんなワシ", "やさしいハクチョウ", "かしこいカメ", "たのしいカワウソ", "すばやいハヤブサ", "シロクマ", "金色のライオン", "しずかなシカ", "すばやいオオヤマネコ", "げんきなペンギン", "おだやかなクジラ", "ゆうかんなトラ", "たのしいハチドリ", "うみのアザラシ"],
        "ko": ["빠른 돌고래", "차분한 판다", "용감한 독수리", "우아한 백조", "지혜로운 거북", "즐거운 수달", "날쌘 매", "북극곰", "황금 사자", "조용한 사슴", "날렵한 스라소니", "즐거운 펭귄", "고요한 고래", "용감한 호랑이", "즐거운 벌새", "바다표범"],
    ]

    static func isLegacy(_ name: String) -> Bool {
        names.values.contains { $0.contains(name) }
    }
}

final class AppModel: ObservableObject {
    enum Phase { case starting, waiting, receiving, finished, error }

    static let maxOffers = 5

    @Published var phase: Phase = .starting
    @Published var listenerError: String = ""
    @Published var viaUSB = true
    @Published var peerName = ""
    @Published var connections = 0 { didSet { updateIdleTimer() } }
    @Published var received = 0
    @Published var saved = 0
    @Published var failed = 0
    @Published var bytes: Int64 = 0
    @Published var speed: Double = 0          // bajty na sekundę
    @Published var currentFile = ""
    @Published var lastError = ""
    @Published var photoStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var wifiAddress: String?
    @Published var offers: [Offer] = []
    @Published var exported = 0             // wysłane do komputera (kopia)
    @Published var pulling = false { didSet { updateIdleTimer() } }
    @Published var pairs: [PairStore.Pair] = []
    @Published var onWifi = false
    @Published var pullTotal = 0                // ile plików komputer zamierza pobrać (koło postępu)
    @Published var pullTotalBytes: Int64 = 0
    @Published var exportedFromCloud = 0
    @Published var currentFromCloud = false
    @Published var receiveTotal = 0             // ile plików komputer zapowiedział do wysłania
    @Published var receiveTotalBytes: Int64 = 0
    @Published var albumName = ""
    var pulls = 0                               // ile połączeń komputera ma zgodę na kopię
    @Published var scanning = false             // komputer skanuje bibliotekę (lista + miniatury), nic jeszcze nie kopiuje
    @Published var scanListed = 0
    @Published var scanTotal = 0
    @Published var thumbsSent = 0
    @Published var lang: String {
        didSet { UserDefaults.standard.set(lang, forKey: "lang") }
    }

    var pendingOffer: Offer? { offers.first }

    @Published var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            shared.name = deviceName
            receiver?.settingsChanged()
        }
    }
    @Published var mode: ReceiveMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            shared.mode = mode
            receiver?.settingsChanged()
        }
    }
    @Published var askBeforeReceive: Bool {
        didSet {
            UserDefaults.standard.set(askBeforeReceive, forKey: "ask")
            shared.ask = askBeforeReceive
            receiver?.settingsChanged()
        }
    }
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    let device: DeviceInfo
    let shared = SharedSettings()
    private var receiver: Receiver?
    private var saver: PhotoSaver?
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)

    init() {
        let dev = DeviceInfo.current()
        device = dev
        let defaults = UserDefaults.standard
        lang = defaults.string(forKey: "lang") ?? "auto"
        var name = defaults.string(forKey: "deviceName") ?? ""
        if name.isEmpty || NameGenerator.isLegacy(name) {      // zwykła nazwa: model telefonu, np. „iPhone 15 Pro”
            name = dev.marketingName
            defaults.set(name, forKey: "deviceName")
        }
        deviceName = name
        mode = ReceiveMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .both
        askBeforeReceive = defaults.object(forKey: "ask") as? Bool ?? true
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        shared.name = deviceName
        shared.mode = mode
        shared.ask = askBeforeReceive
        pairs = PairStore.all()
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
            self?.shared.onWifi = wifi
            DispatchQueue.main.async {
                self?.onWifi = wifi
                self?.wifiAddress = AppModel.currentWifiAddress()
            }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "pl.tomstec.wynos.wifi"))
    }

    /// Zmiana stanu z dowolnego wątku – wykonuje się na głównym.
    func post(_ change: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    func becameActive() {
        wifiAddress = AppModel.currentWifiAddress()
        refreshPhotoStatus()
        pairs = PairStore.all()
        if photoStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { self.photoStatus = status }
            }
        }
        if saver == nil {
            saver = PhotoSaver(model: self)
        }
        if receiver == nil, let saver = saver {
            receiver = Receiver(model: self, saver: saver)
        }
        receiver?.start()
        updateIdleTimer()
    }

    /// Ekran nie gaśnie tylko podczas przesyłania (potem normalnie, oszczędza baterię).
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = connections > 0 || pulling
    }

    // MARK: - prośby

    /// Dodaje prośbę do kolejki; za dużo naraz = automatyczna odmowa (ochrona przed zasypaniem okienkami).
    func enqueue(_ offer: Offer) {
        if offers.count >= AppModel.maxOffers || offers.contains(where: { $0.session == offer.session }) {
            offer.answer(false)
            return
        }
        offers.append(offer)
    }

    func answerOffer(_ accept: Bool) {
        guard let offer = offers.first else { return }
        offers.removeFirst()
        offer.answer(accept)
    }

    func dropOffers(session: String) {
        offers.removeAll { $0.session == session }
    }

    // MARK: - parowanie

    func refreshPairs() {
        pairs = PairStore.all()
    }

    func forget(_ pair: PairStore.Pair) {
        PairStore.remove(pair.id)
        pairs = PairStore.all()
        receiver?.closeSessions(pc: pair.id)
    }

    // MARK: - inne

    func stopPull() {
        receiver?.stopPulls()
    }

    func resetName() {
        deviceName = device.marketingName
    }

    func refreshPhotoStatus() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func resetCounters() {
        received = 0
        exported = 0
        exportedFromCloud = 0
        pullTotal = 0
        pullTotalBytes = 0
        receiveTotal = 0
        receiveTotalBytes = 0
        albumName = ""
        saved = 0
        failed = 0
        bytes = 0
        speed = 0
        currentFile = ""
        lastError = ""
        if connections == 0 {
            phase = .waiting
        }
    }

    var canSave: Bool {
        photoStatus == .authorized || photoStatus == .limited ||
            PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    /// Adres IPv4 telefonu w sieci Wi-Fi.
    static func currentWifiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
