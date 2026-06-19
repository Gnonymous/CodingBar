import SwiftUI
import CodingBarCore

// Current UI language flows through the SwiftUI environment (like `\.dc`), so any view
// can read `@Environment(\.lang) private var lang` and call `lang.t("English", "中文")`.
// PanelView injects `store.language`; the default is English.
private struct LangKey: EnvironmentKey { static let defaultValue: AppLanguage = .en }

extension EnvironmentValues {
    var lang: AppLanguage {
        get { self[LangKey.self] }
        set { self[LangKey.self] = newValue }
    }
}
