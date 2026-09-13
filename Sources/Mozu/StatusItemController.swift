import AppKit

/// メニューバーの常駐アイコンとメニュー。
///
/// SwiftUI の `MenuBarExtra` は、メニューを開いている最中にコンテンツ内の
/// `@Published` が変わるとメニュー全体を再生成してしまい、その瞬間メニューが
/// 閉じてしまう（「アイコンにポインタを合わせると消える」の正体）。
/// 現在の入力ソースを表示する以上、状態が変わらないわけにはいかないので、
/// ここは素の `NSStatusItem` + `NSMenuDelegate` で実装する。
///
/// `menuNeedsUpdate` はメニューが開く「直前」に同期で呼ばれるので、
/// そこで状態をいくら更新してもメニューは閉じない。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let appDelegate: AppDelegate
    private let store: SourcesStore

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    init(appDelegate: AppDelegate, store: SourcesStore) {
        self.appDelegate = appDelegate
        self.store = store
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = symbol(trusted: AXIsProcessTrusted())
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    func updateIcon(trusted: Bool) {
        statusItem?.button?.image = symbol(trusted: trusted)
    }

    // MARK: - NSMenuDelegate

    /// `NSMenuDelegate` のメソッドはメインスレッドから同期で呼ばれる。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        // メニューが開く直前なので、ここで状態を引き直しても問題ない。
        store.refresh()

        menu.removeAllItems()

        // 何のメニューか分からない問題への対策。ブランド名なので翻訳しない。
        menu.addItem(item(title: "mozu", action: nil))
        menu.addItem(.separator())

        menu.addItem(item(title: store.currentName ?? "不明", action: nil))
        menu.addItem(.separator())

        menu.addItem(submenu(title: L10n.t("今すぐ切り替える"), buildSwitcher()))

        menu.addItem(.separator())

        menu.addItem(item(title: L10n.t("設定…"), action: #selector(openSettings)))

        let login = item(title: L10n.t("ログイン時に起動"), action: #selector(toggleLaunchAtLogin))
        login.state = appDelegate.isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        if !appDelegate.hasAllPermissions {
            menu.addItem(item(title: L10n.t("権限を許可する"), action: #selector(requestTrust)))
        }

        menu.addItem(.separator())
        menu.addItem(item(title: L10n.t("再起動"), action: #selector(restart)))
        menu.addItem(item(title: L10n.t("終了"), action: #selector(NSApplication.terminate(_:))))
    }

    private func buildSwitcher() -> NSMenu {
        let submenu = NSMenu()

        if store.sources.isEmpty {
            submenu.addItem(item(title: L10n.t("利用可能な入力ソースがありません"), action: nil))
            return submenu
        }

        for source in store.sources {
            let menuItem = item(title: source.name, action: #selector(selectSource(_:)))
            menuItem.representedObject = source.id
            menuItem.state = store.currentID == source.id ? .on : .off
            submenu.addItem(menuItem)
        }

        return submenu
    }

    // MARK: - Items

    private func item(title: String, action: Selector?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self

        // autoenablesItems を切っているので、表示専用の行（現在のソース等）は
        // 明示的に無効にしないと撃てる項目に見えてしまう。
        if action == nil {
            menuItem.isEnabled = false
        }

        return menuItem
    }

    private func submenu(title: String, _ content: NSMenu) -> NSMenuItem {
        let menuItem = item(title: title, action: nil)
        menuItem.submenu = content

        // サブメニューの親は action を持たないが、無効にしては開けない。
        menuItem.isEnabled = true

        return menuItem
    }

    private func symbol(trusted: Bool) -> NSImage? {
        let name = trusted ? "globe" : "globe.badge.chevron.backward"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Mozu")
        image?.isTemplate = true
        return image
    }

    // MARK: - Actions

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // メニューからでも変換中の確定は必要があるので単一入口を通す。
        // ただしメニューを開いた時点でクリックが観測済みなので、
        // 通常は確定注入はスキップされる。
        appDelegate.switchTo(id: id)
    }

    @objc private func openSettings() {
        appDelegate.showSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        appDelegate.setLaunchAtLogin(!appDelegate.isLaunchAtLoginEnabled)
    }

    @objc private func requestTrust() {
        appDelegate.requestTrust()
    }

    @objc private func restart() {
        appDelegate.restart()
    }
}
