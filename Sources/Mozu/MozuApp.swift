import ApplicationServices
import AppKit
import Carbon
import IOKit
import ServiceManagement
import SwiftUI

/// SwiftUI の `App` / scene 管理は使わず、`NSApplication` を直接起動する。
///
/// 理由:
/// - メニューバーは `MenuBarExtra` が「開期中のリフレッシュで閉じる」ため
///   `NSStatusItem` に置き換えていた
/// - 設定ウィンドウを `Settings` / `Window` シーンにすると、AppKit 側から
///   確実に開く手段が `showSettingsWindow:` を responder chain に流す
///   裏技だけになる。しかも accessory アプリ（メインメニューがない）では
///   そのアクションが到達せず、クリックしても何も起きない
///
/// なのでウィンドウも自前で持つ。中身の UI だけ SwiftUI のままにできる。
/// `NSApplication.delegate` は弱参照なので、`main()` のローカルに持つと
/// 戻った瞬間に解放されてしまう。グローバルで寿命を持つ。
@MainActor private let appDelegate = AppDelegate()

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// アクセシビリティ権限が許可済みかどうか。
    @Published var isTrusted: Bool = false

    /// 「入力監視」（IOHID ListenEvent）が許可済みかどうか。
    /// これが無いと keyDown が観測できず、変換中文字列の確定判定が
    /// 永久に「打っていない」になってしまう。両権限が揃って初めて
    /// モニタが正しく動く。
    @Published var isMonitoring: Bool = false

    /// メニューバーと設定ウィンドウで共有する入力ソース状態。
    /// AppDelegate が owner なので、切り替え直後に即リフレッシュできる。
    let store = SourcesStore()

    private let monitor = ModifierMonitor()
    private var statusController: StatusItemController?
    private var trustPollingTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var pendingSwitch: DispatchWorkItem?
    private var pendingKana: DispatchWorkItem?
    private var pendingVerify: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニューバー常駐だけなので Dock には出さない。
        NSApp.setActivationPolicy(.accessory)

        monitor.onAloneRelease = { [weak self] slot in
            self?.activate(slot: slot)
        }
        monitor.start()

        let controller = StatusItemController(appDelegate: self, store: store)
        controller.install()
        statusController = controller

        pollTrustStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        trustPollingTask?.cancel()
    }

    /// 単発押しが確定したキーに割り当てられた入力ソースへ切り替える。
    /// ここは「トグル」ではなく「絶対指定」なので、現在の状態を読みにいく必要がない。
    private func activate(slot: KeySlot) {
        guard let id = Mapping.sourceID(for: slot) else { return }
        switchTo(id: id)
    }

    /// 入力ソース切り替えの単一入口（キー単発押しとメニューからの選択で共有）。
    ///
    /// 変換中（marked text が生きている）状態で `TISSelectInputSource` を呼ぶと、
    /// ことえりも中国語 IME も変換中文字列を確定ではなく「棚上げ」で保持し、
    /// あとで同じソースに戻した瞬間に再出現して化ける。だから確定の可能性があるまま
    /// IME 系ソースから離れるときは、先に Return を注入して確定させてから切り替える。
    ///
    /// 判定は conservative に。「IME 入力モードが選択済み」かつ「その後の文字入力が
    /// Return/Escape・クリック・アプリ切り替えで終わっていない」ときだけ Return を撃つ。
    /// 確定済みのところで Return を打つと改行としてアプリに届いてしまうため、
    /// 怪しいときだけ撃つほうがいい（撃たなければ従来動作で化けるだけ）。
    /// パスワードフィールド（Secure Input）は marked text を作らないので確定不要。
    func switchTo(id: String) {
        let current = InputSourceManager.currentSourceID()
        guard current != id else { return }

        let pendingTyping = monitor.hasPendingTyping
        let inputMode = InputSourceManager.currentSourceIsInputMode()
        let secure = IsSecureEventInputEnabled()
        let needsCommit = pendingTyping && inputMode && secure == false

        monitor.clearPendingTyping()
        pendingSwitch?.cancel()
        pendingKana?.cancel()
        pendingVerify?.cancel()

        guard needsCommit else {
            applySelect(id: id)
            return
        }

        // 日本語 IME は Return 注入でも確定しきれない（確定が非同期で切り替えが
        // 先に走る）。英かなと同じく英数キーを撃って IME 自身に確定させる。
        let japanese = InputSourceManager.currentSourceIsJapanese()

        if japanese {
            CompositionCommit.commitByEisu()
        } else {
            CompositionCommit.commit()
        }

        // 確定キーは別プロセスに非同期で届く。即 TISSelectInputSource を呼ぶと
        // 切り替えが先に走り、確定が未完のまま marked text が棚上げされる
        // （確定キーが切り替え先に落ちて改行になるのも同じ競争の別側面）。
        // 少し待ってから選択する。速さより順序が目的なので、短くして
        // 裏残りが再発したら戻す。
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applySelect(id: id)
            // 確定が確定より後に着弾すると、IME がセッションを自分に引き戻して
            // 「英語を選んだのに日本語が入力される」裏戻りが起きうる。一瞬後に照合する。
            self.scheduleRevertCheck(from: current, to: id)
        }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// 確定を伴う切り替えの一瞬後、選択が裏戻りしていないか照合する。
    ///
    /// ことえりの確定は本当に非同期で、確定処理が TISSelectInputSource より後に
    /// 着弾するとセッションがことえりに引き戻されることがある（実測で「ABC を
    /// 選んだのに打ち出しが日本語になる」）。その頃には確定も済んでいるので、
    /// もう一度選べば戻されない。
    ///
    /// 「現在のソースが切り替え元そのもの」のときだけ再選択する。ユーザーが
    /// その 0.3 秒のあいだに ⌘Space などで third のソースへ移っている場合
    /// （＝裏戻りではなく自前の選択）を巻き添えにしないため。
    private func scheduleRevertCheck(from original: String?, to id: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVerify = nil
            let now = InputSourceManager.currentSourceID()
            guard now != id, now == original else { return }
            NSLog("Mozu: input source selection reverted to %@; re-selecting %@", now ?? "nil", id)
            self.applySelect(id: id)
        }
        pendingVerify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func applySelect(id: String) {
        pendingSwitch = nil

        let selected = InputSourceManager.select(id: id)

        guard selected else {
            NSSound.beep()
            return
        }
        store.refreshCurrent()

        // ことえりの英数/かな状態は入力ソース ID に反映されないので、外部で
        // 変わった分まで観測するのは不可能（Caps Lock 英数切替・mozu 非起動中の
        // 英数キーなど）。なので日本語ソースを選んだときはフラグを見ずに毎回
        // 必ずかなキーを撃つ。ただし撃つのは「まだ何も打っていない」ことが
        // 確かなときだけ。変換中（marked text が生きている）ところにかなキーを
        // 落とすと、打ちかけのローマ字を勝手に「変換」してしまう
        // （実測で「日本語ボタンを押すとカーソル位置の英語が変換された」）。
        // 選択が確定してからでないとことえりに拾われないので少し待つ。
        if InputSourceManager.isJapaneseSource(id: id) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingKana = nil
                // 選択後にユーザーが打っていれば marked text が生きているかも
                // しれない。復帰を待つより直撃を避けるほうが重要なので見送る。
                guard !self.monitor.hasPendingTyping else { return }
                // 選択後に ⌘Space などで他所へ移っていたら撃たない。
                guard InputSourceManager.currentSourceID() == id else { return }
                CompositionCommit.restoreKanaMode()
            }
            pendingKana = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    /// メニュー・アイコンが示す「ちゃんと動く」状態 = 両権限が揃っていること。
    var hasAllPermissions: Bool { isTrusted && isMonitoring }

    // MARK: - 設定ウィンドウ

    /// 設定ウィンドウを開く（開いていればフロントに持ってくる）。
    ///
    /// `isReleasedWhenClosed = false` にして閉じてもインスタンスを残す。
    /// 毎回作り直すとウィンドウ位置がリセットされてうっとうしい。
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)

        let window: NSWindow

        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.t("Mozu 設定")
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(self)
                    .environmentObject(store)
            )
            // NSHostingController は自己申告の sizeThatFits を優先するので、
            // SettingsView 側の .frame と窓のサイズがねじれないように揃えておく。
            window.setContentSize(window.contentViewController!.view.fittingSize)
            settingsWindow = window
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 権限（アクセシビリティ＋入力監視）

    private func pollTrustStatus() {
        trustPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let trusted = AXIsProcessTrusted()
                let monitoring = self?.monitor.isMonitoringGranted ?? false
                self?.isTrusted = trusted
                self?.isMonitoring = monitoring
                self?.statusController?.updateIcon(trusted: trusted && monitoring)

                if trusted && monitoring {
                    // 起動時は未許可だった CGEventTap がここで張れるようになる。
                    // （start は幂等なので許可済みでも再実行して問題ない）
                    // 片方だけでも flagsChanged は流れて単発押し自体は動くが、
                    // keyDown が黙って消える＝変換中の確定だけ壊れるという
                    // 一番わかりにくい壊れ方をするので、両方揃うまで張らない。
                    self?.monitor.start()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 両権限のプロンプトを出す（許可済み側のプロンプトは出ない）。
    ///
    /// 注意: 「入力監視」はアクセシビリティとちがって許可ダイアログが
    /// 出ない。IOHIDRequestAccess は一覧にアプリを並べるだけで、
    /// ユーザーがシステム設定で手動にオンにしないと許可されない。
    /// なので「許可する…」を押したら設定ペインを直接開いてやる。
    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !monitor.isMonitoringGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 再起動

    /// 自分の.bundle をもう一度起動するプロセスを切り離して仕込んでから終了する。
    /// 終了と同時に開こうとすると「終了中のアプリ」に open が勝てないので、
    /// 少し待たせてから起動する。
    func restart() {
        let bundlePath = Bundle.main.bundleURL.path
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "sleep 0.5; open \"$1\"", "sh", bundlePath]
        do {
            try launcher.run()
        } catch {
            NSLog("Mozu: restart failed: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - ログイン時起動

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Mozu: login item update failed: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }
}

/// 修飾キー → 入力ソース ID の対応。UserDefaults に永続化する。
enum Mapping {
    static func sourceID(for slot: KeySlot) -> String? {
        UserDefaults.standard.string(forKey: slot.defaultsKey)
    }

    static func set(_ id: String?, for slot: KeySlot) {
        if let id {
            UserDefaults.standard.set(id, forKey: slot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: slot.defaultsKey)
        }
    }
}
