import SwiftUI

/// 設定ウィンドウの中身。
/// メニューバーのメニューでは選択のたびにメニューが閉じてしまうため、
/// 割り当て編集はウィンドウ内のポップアップ（Picker）で行う。
///
/// 「現在の入力ソース」と「手動切り替え」は毎回使うのでメニュー側に置いてあり、
/// ここには置かない（ウィンドウは 2 click 先なので深い）。
///
/// 窓そのものは `AppDelegate.showSettings()` が NSWindow + NSHostingController で作る。
struct SettingsView: View {
    @EnvironmentObject private var appDelegate: AppDelegate
    @EnvironmentObject private var store: SourcesStore

    var body: some View {
        Form {
            Section(L10n.t("状態")) {
                // 二つの権限は役割が違う。入力監視が無いと keyDown が
                // 黙って消え、アクセシビリティが無いとタップも注入も動かない。
                // なので一行一つずつ選び、両方揃うまで案内を出す。
                LabeledContent(L10n.t("アクセシビリティ")) {
                    if appDelegate.isTrusted {
                        Label(L10n.t("許可済み"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L10n.t("許可する…")) {
                            appDelegate.requestTrust()
                        }
                    }
                }

                LabeledContent(L10n.t("入力監視")) {
                    if appDelegate.isMonitoring {
                        Label(L10n.t("許可済み"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L10n.t("許可する…")) {
                            appDelegate.requestTrust()
                        }
                    }
                }

                if !appDelegate.hasAllPermissions {
                    Text(L10n.t("文字入力の検出には入力監視、確定キーの注入にはアクセシビリティが必要です。両方の許可が必要です。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("キー割り当て")) {
                if store.sources.isEmpty {
                    Text(L10n.t("システム設定 → キーボード → 入力ソースで、使う言語を追加してください。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(KeySlot.allCases) { slot in
                    SlotPicker(slot: slot)
                }

                Text(L10n.t("いずれも単発押しで発火します。他のキーと併用すれば通常の修飾キーとしてそのまま使えます。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.t("ログイン時に起動"), isOn: Binding(
                    get: { appDelegate.isLaunchAtLoginEnabled },
                    set: { appDelegate.setLaunchAtLogin($0) }
                ))

                LabeledContent(L10n.t("バージョン")) {
                    Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?.?.?")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .onAppear {
            // 設定中にシステム側で入力ソースが追加されることがあるので、開いたときに引き直す。
            store.refresh()
        }
    }
}

/// 1 キー分の割り当て行。`@AppStorage` に ID を保存する。
private struct SlotPicker: View {
    @AppStorage private var storedID: String
    @EnvironmentObject private var store: SourcesStore

    private let slot: KeySlot

    init(slot: KeySlot) {
        self.slot = slot
        _storedID = AppStorage(wrappedValue: "", slot.defaultsKey)
    }

    var body: some View {
        LabeledContent(slot.title) {
            Picker("", selection: $storedID) {
                Text(L10n.t("未設定")).tag("")
                ForEach(store.sources) { source in
                    Text(source.name).tag(source.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 180)
        }
    }
}
