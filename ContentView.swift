import Photos
import SwiftUI
import UIKit

/// Kolor marki WynOs (niebieski) – w trybie ciemnym jaśniejszy, jak systemowe kolory iOS.
extension Color {
    static let brand = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.36, green: 0.61, blue: 1.00, alpha: 1)     // #5B9BFF
        : UIColor(red: 0.14, green: 0.34, blue: 0.76, alpha: 1) })  // #2456C2
    static let leaf = Color(red: 0.13, green: 0.77, blue: 0.37)     // #22C55E
}

/// Koło postępu z dużą liczbą w środku.
struct RingView: View {
    let progress: Double
    let big: String
    let small: String

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 14)
            if progress > 0.002 {
                Circle()
                    .trim(from: 0, to: min(1, progress))
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
            }
            VStack(spacing: 2) {
                Text(big)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(small).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 24)
        }
        .frame(width: 176, height: 176)
        .padding(.top, 6)
    }
}

/// Mała etykieta (np. „Wi-Fi ✓”).
struct Badge: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(ok ? .green : .orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.16)))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            List {
                Section { hero }
                if showsStats { statsSection }
                if !model.canSave { photosSection }
                phoneSection
                pairsSection
                if !model.lastError.isEmpty { errorSection }
                footerSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("WynOs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Image("Logo").resizable().interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showHelp = true }) { circleIcon("questionmark") }
                        .accessibilityLabel(T("Pomoc", "Help"))
                    languageMenu
                    Button(action: toggleTheme) { circleIcon(scheme == .dark ? "moon.fill" : "sun.max.fill") }
                        .accessibilityLabel(T("Wygląd", "Appearance"))
                }
            }
        }
        .tint(.brand)
        // kolejka próśb: każda kolejna pokazuje się po odpowiedzi na poprzednią
        .alert(item: Binding(get: { model.pendingOffer }, set: { _ in })) { offer in
            Alert(title: Text(title(for: offer)), message: Text(offerMessage(offer)),
                  primaryButton: offer.kind == .delete
                    ? .destructive(Text(T("Usuń", "Delete"))) { model.answerOffer(true) }
                    : .default(Text(offer.kind == .pair ? T("Sparuj", "Pair") : T("Akceptuj", "Accept"))) {
                      model.answerOffer(true)
                  },
                  secondaryButton: .cancel(Text(T("Odrzuć", "Decline"))) { model.answerOffer(false) })
        }
        .alert(T("Nazwa telefonu", "Phone name"), isPresented: $editingName) {
            TextField(T("np. Szybki Delfin", "e.g. Swift Dolphin"), text: $nameDraft)
            Button(T("Anuluj", "Cancel"), role: .cancel) {}
            Button(T("Zapisz", "Save")) {
                let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.deviceName = String(trimmed.prefix(40)) }
            }
        } message: {
            Text(T("Tak telefon będzie widoczny w programie WynOs na komputerze.",
                   "This is how the phone appears in WynOs on the computer."))
        }
        .sheet(isPresented: $showHelp) { helpSheet }
    }

    // MARK: - pasek u góry

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(.tertiarySystemFill)))
    }

    private var languageMenu: some View {
        Menu {
            Picker(T("Język", "Language"), selection: $model.lang) {
                Text(T("Jak w telefonie", "Phone language")).tag("auto")
                ForEach(0..<Lang.all.count, id: \.self) { i in
                    Text(Lang.all[i].1).tag(Lang.all[i].0)
                }
            }
        } label: {
            circleIcon("globe")
        }
        .accessibilityLabel(T("Język", "Language"))
    }

    private func toggleTheme() {
        model.theme = scheme == .dark ? .light : .dark
    }

    // MARK: - karta stanu

    @ViewBuilder
    private var hero: some View {
        if model.pulling && model.scanning {
            scanHero
        } else if model.pulling {
            pullHero
        } else if model.phase == .receiving {
            receiveHero
        } else {
            idleHero
        }
    }

    private var idleHero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(statusColor.opacity(0.16)).frame(width: 56, height: 56)
                Image(systemName: statusIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            Text(statusTitle).font(.title3.weight(.semibold))
            Text(statusDetail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Badge(text: model.onWifi ? "Wi-Fi ✓" : T("Brak Wi-Fi", "No Wi-Fi"), ok: model.onWifi)
                Button(action: { if !model.canSave { openPhotosPermission() } }) {
                    Badge(text: photosBadge, ok: model.photoStatus == .authorized)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var pullHero: some View {
        let frac: Double = model.pullTotalBytes > 0
            ? Double(model.bytes) / Double(model.pullTotalBytes)
            : (model.pullTotal > 0 ? Double(model.exported) / Double(model.pullTotal) : 0)
        let left = Double(max(0, model.pullTotalBytes - model.bytes))
        return VStack(spacing: 8) {
            RingView(progress: frac, big: model.pullTotal > 0 || model.pullTotalBytes > 0 ? "\(Int(min(1, frac) * 100))%" : "\(model.exported)",
                     small: eta(model.speed > 0 && model.pullTotalBytes > 0 ? left / model.speed : nil))
            Text(T("Kopia na komputer", "Backup to computer")).font(.title3.weight(.semibold)).padding(.top, 6)
            Text(peerLine).font(.subheadline).foregroundColor(.secondary)
            if !model.currentFile.isEmpty {
                Text((model.currentFromCloud ? "☁︎ " + T("z iCloud: ", "from iCloud: ") : "") + model.currentFile)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(role: .destructive, action: { model.stopPull() }) {
                Label(T("Zatrzymaj", "Stop"), systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// Komputer skanuje bibliotekę: lista zdjęć i filmów, potem miniatury do podglądu. Nic nie jest jeszcze kopiowane.
    private var scanHero: some View {
        let listing = model.scanTotal == 0 || model.scanListed < model.scanTotal
        let frac: Double = listing
            ? (model.scanTotal > 0 ? Double(model.scanListed) / Double(model.scanTotal) : 0)
            : Double(min(model.thumbsSent, model.scanTotal)) / Double(max(1, model.scanTotal))
        let big = listing ? (model.scanTotal > 0 ? number(model.scanListed) : "…") : number(min(model.thumbsSent, model.scanTotal))
        let small = model.scanTotal > 0 ? T("z {n}", "of {n}", ["n": number(model.scanTotal)]) : T("przeglądam…", "reading…")
        return VStack(spacing: 8) {
            RingView(progress: frac, big: big, small: small)
            Text(listing ? T("Skanuję bibliotekę", "Scanning the library") : T("Wysyłam podgląd", "Sending previews"))
                .font(.title3.weight(.semibold)).padding(.top, 6)
            Text(peerLine).font(.subheadline).foregroundColor(.secondary)
            Text(listing
                 ? T("Komputer odczytuje listę zdjęć i filmów. Nic nie jest jeszcze kopiowane.",
                     "The computer is reading the list of photos and videos. Nothing is copied yet.")
                 : T("Małe miniatury do wyboru zdjęć na komputerze. Oryginały nie są wysyłane.",
                     "Small thumbnails for choosing photos on the computer. Originals are not sent."))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive, action: { model.stopPull() }) {
                Label(T("Zatrzymaj", "Stop"), systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var receiveHero: some View {
        let frac: Double = model.receiveTotalBytes > 0
            ? Double(model.bytes) / Double(model.receiveTotalBytes)
            : (model.receiveTotal > 0 ? Double(model.received) / Double(model.receiveTotal) : 0)
        let left = Double(max(0, model.receiveTotalBytes - model.bytes))
        return VStack(spacing: 8) {
            RingView(progress: frac, big: model.receiveTotal > 0 ? "\(Int(min(1, frac) * 100))%" : "\(model.received)",
                     small: eta(model.speed > 0 && model.receiveTotalBytes > 0 ? left / model.speed : nil))
            Text(T("Odbieram do Zdjęć", "Receiving to Photos")).font(.title3.weight(.semibold)).padding(.top, 6)
            Text(peerLine).font(.subheadline).foregroundColor(.secondary)
            if !model.currentFile.isEmpty {
                Text(model.currentFile)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var peerLine: String {
        let via = model.viaUSB ? T("kabel", "cable") : T("Wi-Fi, szyfrowane", "Wi-Fi, encrypted")
        return model.peerName.isEmpty ? via : "\(model.peerName) · \(via)"
    }

    // MARK: - liczniki

    private var showsStats: Bool {
        model.pulling || model.phase == .receiving || model.exported > 0 || model.received > 0 || model.failed > 0
    }

    private var isPullStats: Bool {
        model.pulling || (model.phase != .receiving && model.exported > 0 && model.received == 0)
    }

    private var statsSection: some View {
        Section {
            if isPullStats {
                HStack {
                    stat(T("wysłane", "sent"), number(model.exported))
                    stat(T("z iCloud", "from iCloud"), number(model.exportedFromCloud))
                    stat(T("błędy", "errors"), "\(model.failed)", model.failed > 0 ? .red : nil)
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    stat(T("w Zdjęciach", "in Photos"), number(model.saved), .green)
                    stat(T("odebrane", "received"), ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                    stat(T("błędy", "errors"), "\(model.failed)", model.failed > 0 ? .red : nil)
                }
                .padding(.vertical, 4)
                if !model.albumName.isEmpty {
                    LabeledContent(T("Album", "Album"), value: model.albumName)
                }
            }
            LabeledContent(T("Prędkość", "Speed"),
                           value: model.speed > 0 ? String(format: "%.1f MB/s", model.speed / 1_000_000) : "–")
            if !model.pulling && model.phase != .receiving {
                Button(T("Wyzeruj liczniki", "Reset counters")) { model.resetCounters() }
            }
        } footer: {
            if model.pulling {
                Text(T("Najpierw pliki z telefonu, potem z iCloud (tylko przez Wi-Fi). Nie blokuj telefonu – ekran nie zgaśnie do końca kopii.",
                       "Phone files first, then iCloud (Wi-Fi only). Don't lock the phone – the screen stays on until the backup ends."))
            } else if model.phase == .receiving {
                Text(T("Pliki trafiają do Zdjęć z oryginalną datą, miejscem i parami Live Photo – na właściwe miejsce na osi czasu.",
                       "Files go to Photos with their original date, location and Live Photo pairs – in the right place on the timeline."))
            }
        }
    }

    // MARK: - ten telefon, komputery

    private var phoneSection: some View {
        Section {
            HStack {
                Label {
                    Text(model.deviceName).font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "iphone").foregroundColor(.brand)
                }
                Spacer()
                Button(action: { model.resetName() }) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(T("Losuj nazwę", "Random name"))
                Button(action: { nameDraft = model.deviceName; editingName = true }) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .padding(.leading, 12)
                    .accessibilityLabel(T("Zmień nazwę", "Rename"))
            }
            Picker(T("Połączenie", "Connection"), selection: $model.mode) {
                Text(T("Kabel", "Cable")).tag(ReceiveMode.cable)
                Text("Wi-Fi").tag(ReceiveMode.wifi)
                Text(T("Kabel + Wi-Fi", "Cable + Wi-Fi")).tag(ReceiveMode.both)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            Toggle(T("Pytaj przed odbiorem", "Ask before receiving"), isOn: $model.askBeforeReceive)
            if let ip = model.wifiAddress, model.mode.allowsWifi {
                LabeledContent(T("Adres Wi-Fi", "Wi-Fi address")) {
                    Text(ip).font(.body.monospacedDigit()).textSelection(.enabled)
                }
            }
        } header: {
            Text(T("Ten telefon", "This phone"))
        } footer: {
            Text(T("Kopia na komputer i parowanie zawsze wymagają Twojej zgody.",
                   "Backup to the computer and pairing always need your approval."))
        }
    }

    private var pairsSection: some View {
        Section {
            if model.pairs.isEmpty {
                Text(T("Brak sparowanych komputerów.", "No paired computers."))
                    .foregroundColor(.secondary)
            }
            ForEach(model.pairs) { pair in
                HStack {
                    Label(pair.name, systemImage: "desktopcomputer")
                    Spacer()
                    Text(T("szyfrowane", "encrypted")).font(.subheadline).foregroundColor(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) { model.forget(pair) } label: {
                        Label(T("Usuń", "Remove"), systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { model.forget(pair) } label: {
                        Label(T("Usuń", "Remove"), systemImage: "trash")
                    }
                }
            }
            Button(action: { model.refreshConnection() }) {
                Label(T("Odśwież połączenie", "Refresh connection"), systemImage: "arrow.clockwise")
            }
            if let t = model.refreshedAt, Date().timeIntervalSince(t) < 60 {
                Text(T("Odświeżono – na komputerze kliknij „Odśwież” w „Dostępne urządzenia”.",
                       "Refreshed – on the computer click “Refresh” in “Available devices”."))
                    .font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text(T("Sparowane komputery", "Paired computers"))
        } footer: {
            Text(T("Przez Wi-Fi łączą się tylko komputery sparowane raz przez kabel. Połączenie jest szyfrowane. Przesuń w lewo, aby usunąć. Nowy komputer? Podłącz kabel, odblokuj iPhone'a i stuknij „Ufaj”, potem na komputerze „Sparuj”.",
                   "Only computers paired once over the cable can connect over Wi-Fi. The connection is encrypted. Swipe left to remove. New computer? Connect the cable, unlock the iPhone and tap “Trust”, then “Pair” on the computer."))
        }
    }

    private var photosSection: some View {
        Section {
            Label(T("Brak dostępu do Zdjęć", "No access to Photos"), systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(T("Bez pełnego dostępu WynOs nie skopiuje zdjęć na komputer ani nie zapisze odebranych plików.",
                   "Without full access WynOs cannot copy photos to the computer or save received files."))
                .font(.subheadline).foregroundColor(.secondary)
            Button(model.photoStatus == .notDetermined ? T("Zezwól", "Allow") : T("Otwórz Ustawienia", "Open Settings"),
                   action: openPhotosPermission)
        }
    }

    private var errorSection: some View {
        Section(T("Ostatni błąd", "Last error")) {
            Text(model.lastError).font(.footnote).foregroundColor(.secondary)
        }
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("WynOs \(model.device.appVersion) · Tom Stec")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - pomoc

    private var helpSheet: some View {
        NavigationStack {
            List {
                Section {
                    step(1, T("Otwórz WynOs na komputerze i tutaj, na iPhonie.",
                              "Open WynOs on the computer and here, on the iPhone."))
                    step(2, T("Za pierwszym razem podłącz kabel i kliknij na komputerze „Sparuj” – potem działa też Wi-Fi (szyfrowane).",
                              "The first time, connect the cable and click “Pair” on the computer – then Wi-Fi works too (encrypted)."))
                    step(3, T("Na komputerze wybierz: pobierz oryginały, kompresuj albo wyślij pliki na iPhone'a.",
                              "On the computer choose: download originals, compress or send files to the iPhone."))
                    step(4, T("Nie zamykaj aplikacji i nie blokuj telefonu, aż skończy.",
                              "Keep the app open and the phone unlocked until it finishes."))
                } header: {
                    Text(T("Jak to działa", "How it works"))
                }
                Section {
                    Text(T("Oryginały z iCloud pobiera sam iPhone – na swoim koncie, bez podawania hasła komputerowi. Pliki z iCloud pobierane są tylko przez Wi-Fi.",
                           "The iPhone downloads iCloud originals itself – on its own account, without giving a password to the computer. iCloud files are downloaded over Wi-Fi only."))
                        .font(.subheadline)
                    Text(T("WynOs działa tylko w Twojej sieci: nic nie wysyła do internetu i nie zbiera danych.",
                           "WynOs works only on your own network: it sends nothing to the internet and collects no data."))
                        .font(.subheadline)
                } header: {
                    Text(T("Prywatność", "Privacy"))
                } footer: {
                    Text(T("iPhone i iCloud są znakami towarowymi Apple Inc., Windows – Microsoft Corporation. WynOs nie jest powiązany z tymi firmami. Autor: Tom Stec.",
                           "iPhone and iCloud are trademarks of Apple Inc., Windows of Microsoft Corporation. WynOs is not affiliated with these companies. Author: Tom Stec."))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(T("Pomoc", "Help"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Gotowe", "Done")) { showHelp = false }
                }
            }
        }
    }

    // MARK: - pomocnicze

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.footnote.weight(.bold)).foregroundColor(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.brand))
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func stat(_ title: String, _ value: String, _ color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundColor(color ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func eta(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "" }
        let m = Int(s / 60)
        if m >= 60 { return T("ok. {h} h {m} min", "about {h} h {m} min", ["h": "\(m / 60)", "m": "\(m % 60)"]) }
        if m >= 1 { return T("ok. {m} min", "about {m} min", ["m": "\(m)"]) }
        return T("mniej niż minuta", "under a minute")
    }

    private var photosBadge: String {
        switch model.photoStatus {
        case .authorized: return T("Zdjęcia: pełny dostęp ✓", "Photos: full access ✓")
        case .limited: return T("Zdjęcia: ograniczony dostęp", "Photos: limited access")
        default: return T("Zdjęcia: brak dostępu", "Photos: no access")
        }
    }

    private func title(for offer: Offer) -> String {
        switch offer.kind {
        case .pull: return T("Dostęp dla komputera?", "Allow the computer?")
        case .pair: return T("Sparować komputer?", "Pair this computer?")
        case .receive: return T("Odebrać pliki?", "Receive files?")
        case .delete: return T("Usunąć oryginały?", "Delete the originals?")
        }
    }

    private func offerMessage(_ offer: Offer) -> String {
        let via = offer.viaUSB ? T("po kablu", "over the cable")
            : T("przez Wi-Fi (sieć lokalna, szyfrowane)", "over Wi-Fi (local network, encrypted)")
        let queued = model.offers.count > 1
            ? "\n\n" + T("(Czekają jeszcze {n} prośby.)", "({n} more requests waiting.)", ["n": "\(model.offers.count - 1)"]) : ""
        switch offer.kind {
        case .pull:
            return T("„{from}” chce zeskanować bibliotekę (lista i podgląd) i skopiować oryginały zdjęć i filmów – także z iCloud – {via}. Zgoda obowiązuje 15 minut dla tego komputera.",
                     "“{from}” wants to scan the library (list and previews) and copy the original photos and videos – including iCloud – {via}. The permission lasts 15 minutes for this computer.",
                     ["from": offer.from, "via": via]) + queued
        case .pair:
            return T("„{from}” chce się sparować z tym telefonem. Potem będzie mógł łączyć się także przez Wi-Fi (szyfrowane). Paruj tylko ze swoim komputerem.",
                     "“{from}” wants to pair with this phone. It will then also be able to connect over Wi-Fi (encrypted). Only pair with your own computer.",
                     ["from": offer.from]) + queued
        case .delete:
            return T("„{from}” chce usunąć z tego iPhone'a {n} oryginałów, których kopia jest na komputerze, a wersje skompresowane zostaną zaraz wgrane. Za chwilę iOS zapyta jeszcze raz. Usunięte trafią do „Ostatnio usunięte” – opróżnij ten album, żeby zwolnić miejsce.",
                     "“{from}” wants to delete {n} originals from this iPhone – they are backed up on the computer and the compressed versions will be uploaded next. iOS will ask once more. Deleted items go to “Recently Deleted” – empty that album to free up space.",
                     ["from": offer.from, "n": "\(offer.files)"]) + queued
        case .receive:
            let size = ByteCountFormatter.string(fromByteCount: offer.bytes, countStyle: .file)
            return T("„{from}” chce wysłać {n} plików ({size}) {via}. Trafią do Zdjęć.",
                     "“{from}” wants to send {n} files ({size}) {via}. They will go to Photos.",
                     ["from": offer.from, "n": "\(offer.files)", "size": size, "via": via]) + queued
        }
    }

    private var statusIcon: String {
        switch model.phase {
        case .finished: return "checkmark"
        case .error: return "exclamationmark.triangle"
        default: return model.mode == .cable ? "cable.connector" : "wifi"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .finished: return .green
        case .error: return .red
        default: return .brand
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .starting: return T("Uruchamiam…", "Starting…")
        case .waiting, .receiving: return T("Gotowy", "Ready")
        case .finished: return T("Zakończono", "Finished")
        case .error: return T("Błąd nasłuchu", "Listening error")
        }
    }

    private var statusDetail: String {
        switch model.phase {
        case .waiting, .starting, .receiving:
            switch model.mode {
            case .cable:
                return T("Podłącz kabel i otwórz WynOs na komputerze – „{name}” pojawi się tam sam.",
                         "Connect the cable and open WynOs on the computer – “{name}” appears there by itself.",
                         ["name": model.deviceName])
            case .wifi:
                return T("Widoczny dla sparowanych komputerów w sieci Wi-Fi. Otwórz WynOs na komputerze.",
                         "Visible to paired computers on Wi-Fi. Open WynOs on the computer.")
            case .both:
                return T("Widoczny dla sparowanych komputerów w sieci Wi-Fi i po kablu. Otwórz WynOs na komputerze.",
                         "Visible to paired computers on Wi-Fi and over the cable. Open WynOs on the computer.")
            }
        case .finished:
            if model.exported > 0 && model.received == 0 {
                return T("Skopiowano na komputer: {n}.", "Copied to the computer: {n}.", ["n": number(model.exported)])
            }
            return T("Zapisano w Zdjęciach: {n}. Możesz wysłać kolejne pliki.", "Saved to Photos: {n}. You can send more files.",
                     ["n": number(model.saved)])
        case .error:
            return model.listenerError
        }
    }

    private func openPhotosPermission() {
        if model.photoStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { model.photoStatus = status }
            }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
