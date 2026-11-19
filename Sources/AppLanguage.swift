import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system, ko, en

    static let key = "RAMCruzyLanguage"
    var id: Self { self }

    init(saved: String?) {
        self = saved.flatMap(Self.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: tr("시스템 설정 따르기")
        case .ko: "한국어"
        case .en: "English"
        }
    }

    func resolved(preferredLanguages: [String]) -> AppLanguage {
        switch self {
        case .ko: return .ko
        case .en: return .en
        case .system:
            for identifier in preferredLanguages {
                if let code = Locale(identifier: identifier).language.languageCode?.identifier,
                   let language = AppLanguage(rawValue: code) {
                    return language
                }
            }
            return .en
        }
    }
}

enum AppLanguage: String {
    case ko, en

    // Keep the language fixed for this run, including messages from background tasks.
    static let active = AppLanguagePreference(saved: UserDefaults.standard.string(forKey: AppLanguagePreference.key))
        .resolved(preferredLanguages: Locale.preferredLanguages)
    private static let english = Bundle.main.url(forResource: "en", withExtension: "lproj")
        .flatMap(Bundle.init(url:))

    var locale: Locale { Locale(identifier: self == .ko ? "ko_KR" : "en") }

    func string(_ key: String) -> String {
        guard self == .en, let english = Self.english else { return key }
        return english.localizedString(forKey: key, value: key, table: nil)
    }
}

// One %@ placeholder per interpolation keeps names and numbers intact and lets
// the English catalog reorder them. Korean source literals are the fallback.
struct AppText: ExpressibleByStringInterpolation {
    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        mutating func appendInterpolation<T>(_ value: T) {
            arguments.append(String(describing: value))
            key += "%\(arguments.count)$@"
        }
    }

    fileprivate let key: String
    fileprivate let arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }
}

func tr(_ text: AppText) -> String {
    let language = AppLanguage.active
    let format = language.string(text.key)
    return text.arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: text.arguments)
}
