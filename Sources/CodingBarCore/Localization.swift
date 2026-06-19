import Foundation

// MARK: - App language (CN / EN, English-default)
//
// CodingBar localizes via a tiny code-based table rather than .xcstrings/.lproj:
// CodingBarCore ships no bundle resources, the app is hand-assembled by package.sh,
// and the language is an explicit user setting — so a runtime-selected string pair is
// simpler and more reliable than the OS localization machinery. User-facing strings
// built in the data layer (coach tips, forecasts, quota errors) take an AppLanguage and
// resolve at production time; the UI threads it through the SwiftUI environment.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case en
    case zh

    /// Pick the right variant — English first, since the app defaults to English.
    public func t(_ en: String, _ zh: String) -> String { self == .zh ? zh : en }
}
