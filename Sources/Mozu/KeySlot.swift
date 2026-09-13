import AppKit
import Carbon
import Foundation

/// 割り当て対象にできる修飾キー。
/// いずれも「単発押し（他のキーを挟まずに離す）」だけを検出し、
/// 通常どおり修飾キーとして併用した場合は何もしない。
enum KeySlot: String, CaseIterable, Identifiable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .leftCommand: return UInt16(kVK_Command)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .leftOption: return UInt16(kVK_Option)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftControl: return UInt16(kVK_Control)
        case .rightControl: return UInt16(kVK_RightControl)
        }
    }

    /// このキーに対応する修飾フラグ。単発押しの判定は
    /// 「flagsChanged でフラグが消えた && 直前のイベントがこのキー」という条件で行う。
    var modifier: NSEvent.ModifierFlags {
        switch self {
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        }
    }

    var title: String {
        switch self {
        case .leftCommand: return L10n.t("左 Command")
        case .rightCommand: return L10n.t("右 Command")
        case .leftOption: return L10n.t("左 Option")
        case .rightOption: return L10n.t("右 Option")
        case .leftControl: return L10n.t("左 Control")
        case .rightControl: return L10n.t("右 Control")
        }
    }

    var defaultsKey: String { "inputSource.\(rawValue)" }

    init?(keyCode: UInt16) {
        guard let matched = KeySlot.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = matched
    }
}
