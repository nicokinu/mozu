import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit

/// キーボード・マウスを HID レイヤーで観測し、修飾キーの単発押しを検出して呼び出す。
///
/// 判定ロジックは eikana と同じ発想:
/// `flagsChanged` で「該当フラグが外れた」イベントが届いたとき、
/// その直前のイベントが同じキーの press であれば、
/// その間に他のキーを打っていない＝単発押しだった、と分かる。
///
/// 必要権限は 2 つ（役割が違う）:
/// - **入力監視**（IOHID の ListenEvent）: キーストロークの観測。
///   これが無いとタップは張れるのにイベントが 1 つも流れない
///   静かな失敗をする（flagsChanged だけが通り、keyDown が消える）。
/// - **アクセシビリティ**: `CGEvent.tapCreate` 自体と、確定キーの注入に必要。
///
/// NSEvent のグローバルモニタではなく CGEventTap を使うのは eikana と同じ理由。
/// IME がイベントを消費するより前の生キー入力がそのまま見えるので、
/// 変換中のタイピングも追跡できる。Apple Silicon では HID レベルのタップに
/// 何も流れないので、セッションレベルに張る。
///
/// listenOnly のタップなのでイベントは横取りしない。Command+C などの
/// 既存ショートカットには一切干渉しない。
///
/// ⚠️ メインスレッド専用。タップはメイン RunLoop に紐づけ、
/// コールバックもメインスレッドで実行される。
final class ModifierMonitor {
    var onAloneRelease: ((KeySlot) -> Void)?

    /// 直近の IME 選択以来、Return/Escape・クリック・アプリ切り替えで
    /// 終わっていない文字入力が観測済み。true のあいだは marked text が
    /// 残っているかもしれないので、切り替え前に確定を挟む必要がある。
    private(set) var hasPendingTyping = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: Any?
    private var lastKeyCode: UInt16 = 0

    var isRunning: Bool { tap != nil }

    /// 冪等。アクセシビリティ未許可のうちは失敗するので、
    /// 許可を検出した時点で AppDelegate からもう一度呼ばれる。
    /// 「入力監視」が許可済みか。keyDown の観測はこの TCC が無いと
    /// タップが黙って何も deliver しない。
    var isMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func start() {
        guard tap == nil else { return }

        // 未許可ならシステムに促す（許可済みなら何も起きない）。
        if !isMonitoringGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            // Apple Silicon では HID レベルのタップに何も流れない
            // （Karabiner が HID のために DriverKit ドライバを別に持つ所以）。
            // セッションレベル＋入力監視許可が通常のアプリの正しい経路。
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let monitor = Unmanaged<ModifierMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.handleTapCallback(type: type, event: event)
                }
                // listenOnly: 観測のみで、イベントは常にそのまま流す。
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            // アクセシビリティ未許可。pollTrustStatus が許可を待ってもう一度 start する。
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        tap = newTap
        runLoopSource = source

        // アプリフォーカスが移ったら、前のフィールドの marked text は
        // システム側で確定／破棄される。「今打ったばかり」ではなくなる。
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hasPendingTyping = false
        }
    }

    func stop() {
        guard let tap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }

        self.tap = nil
        runLoopSource = nil
        appActivationObserver = nil
    }

    func clearPendingTyping() {
        hasPendingTyping = false
    }

    // MARK: - Private

    /// タップコールバック本体。タイムアウトで無効化されたときは
    /// system が .tapDisabledByTimeout をここのみに送ってくるので再有効化する。
    private func handleTapCallback(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            handle(type: type, event: event)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            // CGEventFlags の device-dependent ビットは NSEvent.ModifierFlags と同値。
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: event.flags.rawValue))

            if let slot = KeySlot(keyCode: keyCode),
               !modifierFlags.contains(slot.modifier),
               lastKeyCode == keyCode {
                onAloneRelease?(slot)
            }
            lastKeyCode = keyCode

        case .keyDown:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            handleKeyDown(keyCode)
            lastKeyCode = keyCode

        default:
            // どのようなクリックもフォーカスを移す。移った先の marked text は
            // システムが処理するので、少なくとも「打ちたて」ではなくなる。
            hasPendingTyping = false
        }
    }

    private func handleKeyDown(_ keyCode: UInt16) {
        if keyCode == CompositionCommit.eisuKeyCode || keyCode == CompositionCommit.kanaKeyCode {
            // 英数/かなキーは IME が確定してから状態をトグルする。どちらも
            // marked text を終わらせるので確定待ちだけ下ろす。
            // （英数/かなトグル自体は入力ソース ID に反映されないため、
            // 追跡しても外部からの変更（Caps Lock 英数など）で見逃す。
            // 復帰は「日本語ソースを選ぶたび必ずかなキー注入」側で行う）
            hasPendingTyping = false
        } else if Self.endingKeyCodes.contains(keyCode) {
            // Return/Enter は確定、Escape は取り消し。どちらも marked text を
            // 「終わらせる」。注入された Return もここで消えるだけなので
            // フラグを立て直すことはない。
            hasPendingTyping = false
        } else {
            // その他のキーは（IME ソースなら）marked text に化けるので、
            // 確定なしで切り替えてはいけない状態に入る。
            hasPendingTyping = true
        }
    }

    /// marked text を「終わらせる」キー。Carbon の kVK_* は Int で importされる
    /// ので UInt16 に揃えておく。
    private static let endingKeyCodes: Set<UInt16> = [
        UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_Escape),
    ]
}
