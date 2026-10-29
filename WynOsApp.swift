// WynOs – zdjęcia i filmy między komputerem z Windows a iPhone'em: odbiór do galerii po kablu USB
// albo przez Wi-Fi (szyfrowane) oraz kopia oryginałów z iPhone'a na komputer. Autor: Tom Stec
import SwiftUI

@main
struct WynOsApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(model.lang)               // zmiana języka = przebudowa widoków
                .environmentObject(model)
                .preferredColorScheme(model.theme.scheme)
                .onAppear { model.becameActive() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.becameActive()
            }
        }
    }
}

/// Języki aplikacji (kolejność jak w menu).
enum Lang {
    static let all: [(String, String)] = [("en", "English"), ("zh", "中文 (简体)"), ("es", "Español"), ("pt", "Português"), ("fr", "Français"), ("de", "Deutsch"), ("ja", "日本語"), ("ru", "Русский"), ("id", "Bahasa Indonesia"), ("tr", "Türkçe"), ("ko", "한국어"), ("it", "Italiano"), ("vi", "Tiếng Việt"), ("pl", "Polski"), ("uk", "Українська"), ("nl", "Nederlands")]

    /// Wybrany język: ustawienie „lang” albo (auto) język telefonu, jeśli jest na liście; inaczej angielski.
    static var code: String {
        let chosen = UserDefaults.standard.string(forKey: "lang") ?? "auto"
        if chosen != "auto" && all.contains(where: { $0.0 == chosen }) { return chosen }
        let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
        for (c, _) in all where pref.hasPrefix(c) { return c }
        return "en"
    }
}

/// Tekst w wybranym języku. Polski i angielski są w kodzie, pozostałe w Translations.swift (klucz = tekst angielski).
/// Wartości zmienne jako {nazwa} w tekście i w args, np. T("Plików: {n}", "Files: {n}", ["n": "5"]).
func T(_ pl: String, _ en: String, _ args: [String: String] = [:]) -> String {
    let code = Lang.code
    var s = code == "pl" ? pl : code == "en" ? en : (Translations.table[en]?[code] ?? en)
    for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
    return s
}
