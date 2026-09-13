import Foundation

/// UI 文言の参照。
///
/// キーは日本語の原文そのまま。`.strings` が揃わない言語（韓国語など）では
/// キー＝日本語がそのまま出てしまうので、そのフォールバックは
/// Info.plist の開発言語 `en` 経由で英語になるようにしている。
///
/// 対応言語は ja / en / zh-Hans / zh-Hant の 4 種のみ。
/// キリル・タイなどは knowingly 対象外（使う人が自分で寄越すのを待つ）。
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, value: key, comment: "")
    }
}
