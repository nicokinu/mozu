import Combine
import Foundation

/// 入力ソース一覧と現在の入力ソースを保持するストア。
///
/// 更新は「メニューが開く直前」と「設定ウィンドウが開いたとき」の明示的なリフレッシュだけ。
/// 以前のような常時ポーリングは、メニューが開いている最中に @Published を書き換えて
/// SwiftUI のメニューを再生成＝メニューを閉じてしまうため採用していない。
/// AppKit の NSMenuDelegate.menuNeedsUpdate から refresh() を呼ぶ設計にしている。
@MainActor
final class SourcesStore: ObservableObject {
    @Published private(set) var sources: [InputSourceManager.Source] = []
    @Published private(set) var currentID: String?
    @Published private(set) var currentName: String?

    init() {
        refresh()
    }

    func refresh() {
        sources = InputSourceManager.enabledSources()
        currentID = InputSourceManager.currentSourceID()
        currentName = InputSourceManager.currentSourceName()
    }

    func refreshCurrent() {
        currentID = InputSourceManager.currentSourceID()
        currentName = InputSourceManager.currentSourceName()
    }
}
