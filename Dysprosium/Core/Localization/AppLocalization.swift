import Foundation
import Observation
import os
import SwiftUI

/// User-selectable in-app language override supporting system-following behavior
/// alongside live switching between English and Simplified Chinese (`zh-Hans`).
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// Native display title for the language picker.
    /// Explicit languages keep their autonyms so users can always recover if they switch unintentionally.
    public var pickerTitle: String {
        switch self {
        case .system:
            return AppLocalization.string("Automatic")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    public var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    public var appleLanguagesOverride: [String]? {
        switch self {
        case .system:
            return nil
        case .english:
            return ["en"]
        case .simplifiedChinese:
            return ["zh-Hans"]
        }
    }
}

/// Thread-safe localization bridge backed by Xcode's compiled `Localizable.xcstrings` (`Localizable.loctable`).
///
/// - SwiftUI views calling `L(...)` on the main thread automatically register `@Observable`
///   tracking on `AppLanguageStore.shared`, refreshing instantaneously when the user changes
///   the in-app language without tearing down live `WKWebView` tabs or active downloads.
/// - Background actors, models, and error types resolve against the lock-protected active locale
///   with zero MainActor hops and full Swift 6 concurrency safety.
public enum AppLocalization {
    private static let localeLock = OSAllocatedUnfairLock<Locale>(initialState: initialPersistedLocale())

    private static func initialPersistedLocale() -> Locale {
        #if DEBUG
        if let envOverride = ProcessInfo.processInfo.environment["DYSPROSIUM_LANGUAGE"],
           let parsed = parseLanguageCode(envOverride) {
            return parsed.locale
        }
        #endif
        if let saved = UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey),
           let parsed = AppLanguage(rawValue: saved) {
            return parsed.locale
        }
        return .autoupdatingCurrent
    }

    fileprivate static func parseLanguageCode(_ raw: String) -> AppLanguage? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "system", "auto", "automatic":
            return .system
        case "en", "en-us", "en-gb", "english":
            return .english
        case "zh", "zh-hans", "zh-cn", "zh_hans", "zh_cn", "chinese", "mandarin":
            return .simplifiedChinese
        default:
            return AppLanguage(rawValue: raw)
        }
    }

    /// The currently active `Locale` for string resolution, date formatting, and number formatting.
    public static var currentLocale: Locale {
        localeLock.withLock { $0 }
    }

    fileprivate static func setActiveLocale(_ locale: Locale) {
        localeLock.withLock { $0 = locale }
    }

    /// Resolves the exact localization bundle for an explicit locale override (`en` / `zh-Hans`),
    /// supporting both compiled `.loctable` catalogs and `.lproj` `.strings`/`.stringsdict` bundles.
    public static func resolvedBundle(for locale: Locale, baseBundle: Bundle = .main) -> Bundle {
        let identifier = locale.identifier
        guard !identifier.isEmpty, locale != .autoupdatingCurrent else {
            return baseBundle
        }
        let candidates: [String]
        if identifier.hasPrefix("zh") {
            candidates = ["zh-Hans", "zh_Hans", "zh"]
        } else if identifier.hasPrefix("en") {
            candidates = ["en"]
        } else {
            candidates = [identifier]
        }
        for code in candidates {
            if let path = baseBundle.path(forResource: code, ofType: "lproj"),
               let subBundle = Bundle(path: path) {
                return subBundle
            }
        }
        return baseBundle
    }

    /// Resolves a `String.LocalizationValue` (including `%@`, `%lld`, and String Catalog ICU plurals)
    /// against `Localizable.xcstrings` using the active in-app language.
    public static func string(
        _ key: String.LocalizationValue,
        table: String = "Localizable",
        bundle: Bundle = .main,
        locale overrideLocale: Locale? = nil
    ) -> String {
        let resolvedLocale: Locale
        if let overrideLocale {
            resolvedLocale = overrideLocale
        } else {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    _ = AppLanguageStore.shared.selection
                }
            }
            resolvedLocale = currentLocale
        }
        let targetBundle = resolvedBundle(for: resolvedLocale, baseBundle: bundle)
        return String(localized: key, table: table, bundle: targetBundle, locale: resolvedLocale)
    }

    /// Resolves a runtime string key against `Localizable.xcstrings` using the active in-app language.
    public static func dynamic(
        _ key: String,
        table: String = "Localizable",
        bundle: Bundle = .main,
        locale overrideLocale: Locale? = nil
    ) -> String {
        string(String.LocalizationValue(key), table: table, bundle: bundle, locale: overrideLocale)
    }

    /// Returns a `LocalizedStringResource` bound to the active in-app locale.
    public static func resource(
        _ key: String.LocalizationValue,
        table: String = "Localizable",
        bundle: LocalizedStringResource.BundleDescription = .main
    ) -> LocalizedStringResource {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _ = AppLanguageStore.shared.selection
            }
        }
        return LocalizedStringResource(key, table: table, locale: currentLocale, bundle: bundle)
    }
}

/// Shorthand localization helper for SwiftUI labels, toolbar items, alerts, UIKit chrome, and models.
@inline(__always)
public func L(_ key: String.LocalizationValue) -> String {
    AppLocalization.string(key)
}

/// Persists the user's chosen language across launches, syncs `AppleLanguages` for system frameworks
/// on subsequent launches, and drives reactive SwiftUI `.environment(\.locale, ...)` updates.
@MainActor
@Observable
public final class AppLanguageStore {
    public static let shared = AppLanguageStore()
    public nonisolated static let defaultsKey = "dysprosium.appLanguage"

    public var selection: AppLanguage {
        didSet {
            guard oldValue != selection else { return }
            applySelection(selection, persist: true)
        }
    }

    public private(set) var effectiveLocale: Locale

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        var resolved: AppLanguage = .system
        if let saved = userDefaults.string(forKey: Self.defaultsKey),
           let parsed = AppLanguage(rawValue: saved) {
            resolved = parsed
        }
        #if DEBUG
        if let envOverride = ProcessInfo.processInfo.environment["DYSPROSIUM_LANGUAGE"],
           let parsed = AppLocalization.parseLanguageCode(envOverride) {
            resolved = parsed
        }
        #endif

        self.selection = resolved
        self.effectiveLocale = resolved.locale
        AppLocalization.setActiveLocale(resolved.locale)
        syncAppleLanguages(for: resolved)
    }

    public func select(_ language: AppLanguage) {
        selection = language
    }

    private func applySelection(_ language: AppLanguage, persist: Bool) {
        effectiveLocale = language.locale
        AppLocalization.setActiveLocale(language.locale)
        if persist {
            userDefaults.set(language.rawValue, forKey: Self.defaultsKey)
            syncAppleLanguages(for: language)
        }
    }

    private func syncAppleLanguages(for language: AppLanguage) {
        if let override = language.appleLanguagesOverride {
            userDefaults.set(override, forKey: "AppleLanguages")
        } else {
            userDefaults.removeObject(forKey: "AppleLanguages")
        }
    }
}
