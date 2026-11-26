import Foundation

/// halo ships two UI languages. Korean is used when it is the user's first preferred language, English otherwise.
enum AppLanguage {
    case korean, english

    nonisolated(unsafe) static var current = resolve(Locale.preferredLanguages)

    static func resolve(_ preferred: [String]) -> AppLanguage {
        preferred.first?.hasPrefix("ko") == true ? .korean : .english
    }
}

func L(_ korean: String, _ english: String) -> String {
    AppLanguage.current == .korean ? korean : english
}
