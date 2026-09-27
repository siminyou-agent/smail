import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    static let preferenceKey = "appLanguage"
    var id: String { rawValue }
    static var currentLocale: Locale {
        let preference = UserDefaults.standard.string(forKey: preferenceKey) ?? "system"
        return Locale(identifier: (AppLanguage(rawValue: preference) ?? .system).resolvedIdentifier())
    }
    var title: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func text(_ key: String, locale: Locale) -> String {
        let identifier = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    // Errors are stored as source messages so changing language also updates visible errors.
    static func errorText(_ message: String, locale: Locale) -> String {
        let prefix = "本地批次无法读取："
        if message.hasPrefix(prefix) {
            return text(prefix, locale: locale) + errorText(String(message.dropFirst(prefix.count)), locale: locale)
        }
        let httpPrefix = "Gmail 请求失败（"
        let httpSuffix = "），请重试。"
        if message.hasPrefix(httpPrefix), message.hasSuffix(httpSuffix) {
            let code = String(message.dropFirst(httpPrefix.count).dropLast(httpSuffix.count))
            return String(format: text("Gmail 请求失败（%@），请重试。", locale: locale), code)
        }
        return text(message, locale: locale)
    }
}

struct ErrorMessage: View {
    let message: String
    @Environment(\.locale) private var locale
    init(_ message: String) { self.message = message }
    var body: some View { Text(AppLanguage.errorText(message, locale: locale)) }
}

struct MailSubject: View {
    let subject: String
    var body: Text {
        // Recognize the placeholder in batches saved by older app versions as well.
        subject.isEmpty || subject == "（无主题）" ? Text("（无主题）") : Text(verbatim: subject)
    }
}
