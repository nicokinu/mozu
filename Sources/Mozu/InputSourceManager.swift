import Carbon
import Foundation

/// macOS の Text Input Sources (TIS) を叩く薄いラッパー。
///
/// eikana は英数キー（keycode 102）/ かなキー（keycode 104）を CGEvent で注入して
/// 切り替えているが、それは日本語 IME がそのキーコードを受けてくれるからだ。
/// 中国語・韓国語の IME では同じことができないので、ここでは
/// 入力ソースを ID 指定で直接選択する `TISSelectInputSource` を使う。
///
/// なお `TISSelectInputSource` はシステム設定で「入力ソースとして追加」済みの
/// ものでないと失敗する。したがって設定 UI に並べるのは有効なソースだけに限定する。
enum InputSourceManager {
    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// システム設定で有効になっているキーボード入力ソースを一覧化する。
    static func enabledSources() -> [Source] {
        var pairs: [(id: String, name: String)] = []

        for source in inputSourceList(includeAllInstalled: false) {
            guard isSelectCapable(source) else { continue }
            guard isSelectableKeyboardSource(source) else { continue }
            guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { continue }
            let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? id
            pairs.append((id, name))
        }

        let nameCounts = Dictionary(grouping: pairs, by: \.name).mapValues(\.count)

        return pairs
            .map { pair in
                var label = pair.name

                // 「Hiragana」のように表示名が重複する入力ソースがある
                //（ことえりのローマ字入力とかな入力の平仮名モードなど）。
                // 並んだだけで区別できないと「結局どっちを選べばいいか分からない」ので、
                // ID の共通部分を削った残り接尾辞を添って区別できるようにする。
                if nameCounts[pair.name, default: 0] > 1 {
                    let group = pairs.filter { $0.name == pair.name }.map(\.id)
                    label += "（\(friendlySuffix(for: pair.id, in: group))）"
                }

                return Source(id: pair.id, name: label)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, key: kTISPropertyInputSourceID)
    }

    static func currentSourceName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, key: kTISPropertyLocalizedName)
    }

    /// 現在選ばれているのが「IME 入力モード」（平仮名・カタカナ・ピンインなど）か。
    /// ABC のような単なるキーボードレイアウトは marked text を生まない（＝切り替え前に
    /// 確定を挟む必要がない）ので、確定注入の可否をここで絞る。
    static func currentSourceIsInputMode() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return stringProperty(source, key: kTISPropertyInputSourceType) == "TISTypeKeyboardInputMode"
    }

    /// 現在選ばれている入力ソースが日本語（ことえり・ATOK・Google 日本語など）か。
    /// 日本語 IME は Return 注入での確定が効かないので、英数キー注入側に振る。
    static func currentSourceIsJapanese() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return languages(of: source).contains("ja")
    }

    /// 指定 ID のソースが日本語入力モードか（復帰かな注入の判定）。
    static func isJapaneseSource(id: String) -> Bool {
        guard let source = inputSourceList(includeAllInstalled: true)
            .first(where: { stringProperty($0, key: kTISPropertyInputSourceID) == id }) else { return false }
        return languages(of: source).contains("ja")
    }

    /// 該当 ID の入力ソースに切り替える。成功したら true。
    @discardableResult
    static func select(id: String) -> Bool {
        // install 済み全部から引く（有効化済みのものは必ず含まれる）。
        for source in inputSourceList(includeAllInstalled: true) where stringProperty(source, key: kTISPropertyInputSourceID) == id {
            return TISSelectInputSource(source) == noErr
        }

        return false
    }

    // MARK: - Private

    /// 入力ソース ID のモード名を、メニューに表示できる語に翻訳する。
    /// ことえりのローマ字/かな入りのように表示名が衝突するケースで使う。
    /// 訳語そのものは L10n（ .strings ）で持たせる。
    private static let modeLabels: [String: String] = [
        "RomajiTyping": "ローマ字入力",
        "KanaTyping": "かな入力",
    ]

    /// 表示名が重複しているグループから、そのソースを特定できる接尾辞を取り出して
    /// 読みやすい形に直す。
    /// 例: `...Kotoeri.RomajiTyping.Japanese` → `ローマ字入力`
    private static func friendlySuffix(for id: String, in ids: [String]) -> String {
        let raw = distinguishingSuffix(for: id, in: ids)

        // 言語名セグメント（Japanese など）は UI 上冗長なので落とす。
        let translated = raw
            .split(separator: ".")
            .compactMap { segment -> String? in
                if let label = modeLabels[String(segment)] { return L10n.t(label) }
                return isLanguageSegment(String(segment)) ? nil : String(segment)
            }
            .joined(separator: L10n.t("・"))

        return translated.isEmpty ? raw : translated
    }

    /// `Japanese` / `Chinese` のような、モードを区別しない言語名セグメントか。
    /// （部分一致だと `ITABC` のようなモード名を巻き添えにするので完全一致のみ）
    private static func isLanguageSegment(_ segment: String) -> Bool {
        [
            "Japanese", "Chinese", "Korean", "Simplified", "Traditional",
            "Hans", "Hant", "zh", "ja", "ko", "en",
        ]
        .contains(segment)
    }

    /// 表示名が重複しているソース同士で、ID の共通プレフィックスを削った残りを取り出す。
    /// 例: `...Kotoeri.RomajiTyping.Japanese` と `...Kotoeri.KanaTyping.Japanese`
    /// → `RomajiTyping.Japanese` / `KanaTyping.Japanese`
    private static func distinguishingSuffix(for id: String, in ids: [String]) -> String {
        let common = longestCommonPrefix(of: ids)
        let suffix = String(id.dropFirst(common.count))

        return suffix.isEmpty ? id : suffix
    }

    private static func longestCommonPrefix(of strings: [String]) -> String {
        guard strings.count > 1, var prefix = strings.first.map(Array.init) else { return "" }

        for string in strings.dropFirst() {
            let characters = Array(string)
            var matched = 0

            while matched < prefix.count, matched < characters.count, prefix[matched] == characters[matched] {
                matched += 1
            }

            prefix = Array(prefix.prefix(matched))
        }

        return String(prefix)
    }

    private static func inputSourceList(includeAllInstalled: Bool) -> [TISInputSource] {
        guard let cfArray = TISCreateInputSourceList(nil, includeAllInstalled)?.takeRetainedValue() else { return [] }

        var result: [TISInputSource] = []
        let count = CFArrayGetCount(cfArray)

        for index in 0..<count {
            guard let element = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            result.append(unsafeBitCast(element, to: TISInputSource.self))
        }

        return result
    }

    /// メニューに出して意味のある項目だけを絞る。
    ///
    /// TIS の一覧には以下のような「選べても意味がない」項目が混ざる:
    /// - `TISTypeCharacterPalette`: 絵文字パレットや Press and Hold など、入力ソースではないもの
    /// - `TISTypeKeyboardInputMethodModeEnabled`: ATOK や ことえり などの IME 親エントリ
    ///   （実際に選ぶべきは "Hiragana" のような下位の input mode 側）
    ///
    /// 残るのは `TISTypeKeyboardLayout`（ABC など）と
    /// `TISTypeKeyboardInputMode`（平仮名・簡体字ピンインなど）だけになる。
    private static func isSelectableKeyboardSource(_ source: TISInputSource) -> Bool {
        guard stringProperty(source, key: kTISPropertyInputSourceCategory) == "TISCategoryKeyboardInputSource" else { return false }
        guard let type = stringProperty(source, key: kTISPropertyInputSourceType) else { return false }

        return type == "TISTypeKeyboardLayout" || type == "TISTypeKeyboardInputMode"
    }

    private static func isSelectCapable(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// `kTISPropertyInputSourceLanguages`（"ja" / "zh-Hans" / "en" の配列）。
    private static func languages(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()

        var result: [String] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let element = CFArrayGetValueAtIndex(array, index) else { continue }
            result.append(Unmanaged<CFString>.fromOpaque(element).takeUnretainedValue() as String)
        }

        return result
    }
}
