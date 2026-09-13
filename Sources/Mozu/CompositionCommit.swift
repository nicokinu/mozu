import CoreGraphics
import Foundation

/// IME の marked text（変換中文字列）を確定させ、英数/かな状態を整理する。
///
/// 変換中に `TISSelectInputSource` を叩くと、IME は marked text を確定ではなく
/// 「棚上げ」で保持する。画面からは消えるのに、後で同じ入力ソースに戻した
/// 瞬間に再出現して化ける。確定の打法は IME によって違う:
///
/// - 中国語 IME: Return（36）注入でそのまま確定する（拼音はアルファベットの
///   まま残るが、それは Return 確定の仕様）。
/// - ことえり: Return では確定しきれない。確定が非同期で、直後のソース切り替えが
///   先に走るため marked text が棚上げされたままになる（Return 自体は IME が
///   消費するのでアプリに改行は届かない）。英かなと同じく**英数キー（102）を
///   注入**して IME 自身に確定させる。
///
/// 英数/かなは同じ入力ソース内のトグルなので、英数のままソースを離れると
/// 状態が永続化する。`ModifierMonitor` が英数/かなキーの押下を観測して
/// 「英数のまま出た」かを数え、日本語ソースに戻る側で `restoreKanaMode()` を
/// 呼んでかな入力に戻す。
///
/// marked text が生きている間は Return/英数も IME が先に消費するのでアプリには
/// 届かない。逆に確定済みのところで撃つと改行（最悪 Enter 相当の既定ボタン）に
/// なってしまうため、撃つべきかどうかの判定は呼び出し側に厳しくなるしかない。
enum CompositionCommit {
    /// kVK_Return
    private static let returnKeyCode: CGKeyCode = 36
    /// 日本語キーボードの英数キー（Carbon に kVK 定数がないのでベタ置き）
    static let eisuKeyCode: CGKeyCode = 102
    /// かなキー
    static let kanaKeyCode: CGKeyCode = 104

    /// 中国語系 IME の marked text をそのまま確定させる。
    static func commit() {
        post(returnKeyCode)
    }

    /// ことえり自身に確定させる（確定後に英数状態へ入る）。
    static func commitByEisu() {
        post(eisuKeyCode)
    }

    /// 英数状態のことえりをかな入力で使えるように戻す。
    static func restoreKanaMode() {
        post(kanaKeyCode)
    }

    private static func post(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
