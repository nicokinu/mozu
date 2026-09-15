# Mozu 設計メモ

[README（日本語）](../README.ja.md) の裏側。なぜこうなったかの記録で、
使うだけの人には不要。陷阱の再発見防止が主目的。

## 英かなとの重要な違い

英かなは「 Cmd 単押し」を検出すると **英数キー（keycode 102）/ かなキー（keycode 104）をCGEvent で注入**する。これは日本語 IME がそのキーコードを受けてくれるから成立する仕組みで、中国語の IME では同じことができない。

Mozu の切り替えはキー入力をシミュレートせず、**Text Input Sources (TIS) API の `TISSelectInputSource` で入力ソースを直接選択**する。
だから IME が何かによらず動く。

……と思ったんだけど。
TIS には変換中のまだ確定していない文字を確定させる API が無いので、IME 自身にキーを
処理させるしかない。無理やり入力言語だけ切り替えると、確定前の文字列は裏で残ってしまうバグが発生する。
これを解決するために、IMEにキーを処理させるしかなかった。つまり
・日本語は英数/かな
・中国語はReturn
のキー注入を使う。それから入力言語の切り替えを行う。

| | 英かな | Mozu |
|---|---|---|
| トリガー | Cmd 単発押し | Cmd / Option / Control の単発押し |
| 切り替え手段 | 英数・かなキーコード注入 | `TISSelectInputSource` |
| 変換中の確定 | 英数/かなキーが兼任 | 確定キー注入（Return / 英数 / かな） |
| 対応言語 | 日英 | 日本語・中国語・その他すべて(IMEの仕様による) |
| 設定 | 組み合わせキーの設定もできる | メニューから6つのボタン固定で割り当て |

## 変換中文字列の取り残し（詳細）

変換中（marked text あり）のまま `TISSelectInputSource` で切り替えると、
日本語や中国語のIMEは変換中文字列を確定ではなく「棚上げ」で保持する。
画面からは消えるのに、あとで同じソースに戻した瞬間に再出現して混乱の原因になる。
marked text の有無を外部から照会する公開 API は無い（Accessibility に
属性は存在しない）ので、Mozu はキー入力の観測で推定する:

- 観測は `CGEventTap`（**セッションレベル** + listenOnly）。Apple Silicon では
  HID レベルのタップに何も流れない。NSEvent のグローバルモニタでは
  IME が消費前の keyDown を見られない。
- IME 入力モードが選択されたあと、Return/Escape・クリック・アプリ切り替えで
  終わっていない文字入力があれば「marked text が生きているかもしれない」
- その状態で IME 系ソースから離れるときだけ確定キーを 1 発注入して
  （約 60ms 待って）から切り替える
- Secure Input（パスワードフィールド）は marked text を作らないので確定しない

この推定には **keyDown が観測できなければならない**。keyDown の観測には
「入力監視（Input Monitoring）」の TCC が必要で、無い場合はタップが張れるのに
イベントが黙って deliver されない。しかも flagsChanged だけは通るので
「切り替えは動くのに確定だけ壊れる」という一番わかりにくい壊れ方をする
（まさにこのバグの隠れ主因）。よって Mozu は両権限が揃ってからタップを張る。

確定キーは IME で使い分ける。中国語 IME は Return 注入でそのまま確定する
（拼音がアルファベットのままで残るのは Return 確定の仕様）。一方ことえりは
Return を注入しても確定が非同期で、直後の切り替えに負けて text が
棚上げされたままになる（Return 自体は IME が消費するので改行にはならない）。
日本語ソースでは**英数キー（keycode 102）**を撃って IME 自身に確定させる。

待ち時間（60ms）の本質は「注入キーが改行になる」問題ではなく、**確定と
切り替えの順序保証**である。注入キーは HID→セッション→アプリ→IME と
非同期に流れるイベントで、`TISSelectInputSource` は Carbon API から IMKit に
直接話しかける別経路。両者に順序の保証はないため、待たずに即 select すると
「IME が確定キーを処理する前にソースが deactivate される」競争が起き、
棚上げが再発する。

英数は同じ入力ソース内のトグルなので、ことえりは英数状態のままソースを
離れると、あとで「平仮名」を選び直しても英数状態が復活してアルファベットが
打ててしまう。そこで英数/かなキーの押下を常時観測して英数状態を追跡し、
日本語ソースに戻る瞬間（選択が効いてから約 120ms 後）に**かなキー
（keycode 104）**を注入して必ずかな入力で返すようにしている。

撃つべきでないときに撃った確定キーは改行としてアプリに届いてしまうため、
「怪しいときだけ撃つ」方向に振ってある。推定が外れて撃ち損じたときは
従来どおり変換中文字列が裏に残るだけで、余計な改行は入らない。

**インジケーターが 2回パチパチすることがある**。日本語から離れるとき、
確定のために撃った英数キーでことえりが英数状態に入るため、カーソル横に
まず「ABC」が表示され、その約 60ms 後のソース切り替え表示が 2 回目になる。
中国語（Return 確定）は IME 内部状態が変わらないので 1 回だけ。
英数確定をやめると 2 段表示は消えるが、確定が未完のまま切り替わる
競争が復活して裏残りのバグが再発する。これは見た目ではなくデータのほうを
取った結果。

## 再ビルドと TCC の許可

TCC（アクセシビリティ / 入力監視）はコード署名の**指定要件（designated
requirement）**でアプリを識別する。ad-hoc 署名は何もしないと cdhash（＝
バイナリそのもの）が識別子になるため、リビルドのたびに許可が外れて
「システム設定のスイッチは ON なのに未許可」という幽霊状態になる。

`build-app.sh` は `codesign --requirements` で **identifier のだけ**の
指定要件を埋め込んでいる（`designated => identifier "com.nico.mozu"`）。
これはリビルドでバイナリが変わっても不変なので、**一度許可すれば
再ビルドしても外れない**（実機で確認済み）。同じ理由で、brew 版と zip 版・
Cellar のパス差し替えをまたいでも TCC 的には同じアプリとして扱われる。

許可が壊れたときの初期化（このアプリだけの許可が戻る）:

```sh
tccutil reset Accessibility com.nico.mozu
tccutil reset ListenEvent com.nico.mozu   # 入力監視
```

## Homebrew: なぜ cask ではなく formula か

配布物には手頃な cask はビルド済み zip をダウンロードするので、ad-hoc 署名・
非公証のアプリは Gatekeeper の quarantine で「開けません」になる
（回避の `xattr -d` は Homebrew 的に原則 NG）。
formula はユーザーのマシンでビルドするので生成物に quarantine が付かない。
SwiftPM の依存がゼロなのでビルドにネットワークも要らない。
GUI アプリの正統な置き場は cask なので、「CLT の swift でビルドできることを
承知の上で formula にしている」旨は tap 側に書いておくのが作法。
Developer ID 署名 + 公証をやるようになったら cask に昇格できる。

## リリース手順

1. `Resources/Info.plist` の `CFBundleShortVersionString` を上げる
2. タグを打って push: `git tag vX.Y.Z && git push --tags`
3. tarball の sha256 を取って formula に反映:

```sh
curl -sL https://github.com/nicokinu/mozu/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
```

4. `Formula/mozu.rb` の url / sha256 を更新して commit
5. 手元で反映を確認: `brew update && brew install mozu`（試し直しは `brew fetch --force mozu`）

tarball の sha256 は「タグ時点の tarball」に対する値で、formula 本体は tap の
HEAD から読まれる。なので sha 反映のコミットがタグより後ろにあっても正しい。

## zip 配布（Release アセット）

ビルド済み zip を配りたいなら **リポジトリにコミットせず**、同じタグの
**Release アセット**として添付する。git にバイナリを混ぜると履歴に残り続けて
クローンが重くなる（Homebrew で tarball を引く人まで巻き添え）。`Formula/mozu.rb`
は GitHub が自動生成する source tarball を使うので、zip を添付しても影響しない。

```sh
./Scripts/package-zip.sh   # build/Mozu-vX.Y.Z.zip ができる
```

Release を同じバージョンのタグで作成し、この zip をドラッグして添付する。

**ダウンロードした側の落とし穴**: ブラウザダウンロードには quarantine が付くので、
ad-hoc 署名のアプリはダブルクリックだと「開発者を確認できません」で開けない。
右クリック→開く、もしくは `xattr -dr com.apple.quarantine /Applications/Mozu.app`
で通る。

## 前提として必要なこと（TIS の制約）

`TISSelectInputSource` は、**システム設定で「入力ソースとして追加」済みのものしか選択できない**。
中国語ピンインを選ぶ予定なら、先にシステム設定 → キーボード → 入力ソースで追加しておくこと。

メニューに並ぶのは追加済みの入力ソースだけ（`TISTypeKeyboardLayout` と
`TISTypeKeyboardInputMode` のみ。絵文字パレットなどは表示されない）。

### 表示名が重複するとき

ことえりのローマ字入力とかな入力の平仮名モードのように、
**別々の入力ソースが同じ表示名を持つ**ことがある（どちらも「ひらがな」）。
並んだだけで区別できないと「結局どっちを選べばいいか分からない」ので、
名前列が重複しているソースには ID の差分接尾辞を自動で添える:

```
ひらがな（ローマ字入力）
ひらがな（かな入力）
```

既知のモード名（`RomajiTyping` / `KanaTyping`）は上の語に翻訳し、
`Japanese` のような言語名セグメントは冗長なので落とす。未知の IME で
翻訳できないときは ID の接尾辞をそのまま表示するフォールバックになる。

実際にどちらを選ぶべきかは入力方式による。ローマ字で打って漢字変換する人は `RomajiTyping` 側。

## 韓国語について

Korean の 두벌식 は 1 つのキーボードレイアウトでハングルと英字の両方を入力できるため、
そもそもこの種の切り替えが必要ない。選んだとして、レイアウトを 1 本に固定したまま
`Caps Lock` で英字に入る運用のままのはず。

## なぜメニューだけ AppKit か

SwiftUI の `MenuBarExtra` は、**メニューを開いている最中にコンテンツ内の
`@Published` が変わるとメニューを再生成し、その瞬間メニューが閉じる**。
「現在の入力ソース」を表示する以上は状態が変わらないわけにいかないので、
ここは素の `NSStatusItem` + `NSMenuDelegate` で実装している。

`menuNeedsUpdate:` はメニューが開く**直前**に同期で呼ばれるため、
そこで状態をいくら更新してもメニューは閉じない。

アプリのライフサイクルも素の `NSApplication`（ `@main` な `static func main()` ）にして、
設定ウィンドウも `NSWindow` + `NSHostingController` で自前に生成している。
`Settings` / `Window` シーンに任せる場合、AppKit 側から開く手段が
`showSettingsWindow:` を responder chain に流す裏技だけになり、
しかもメインメニューを持たない accessory アプリではそのアクションが
到達しない（クリックしても何も起きない）。

つまり **メニューバーもウィンドウも AppKit、中身の描画だけ SwiftUI** という割り切り。
その代わり メインメニューがないので `Cmd+,` や `Cmd+W` は効かない
（どちらもメニューバーから辿れる）。

## UI の住み分け

- **メニューバー**: 現在の入力ソース / 今すぐ切り替える / 設定… / ログイン時に起動 / 再起動 / 終了
- **設定ウィンドウ**: キー割り当て（6 スロット）と権限状態だけ

毎回の操作（今のソース確認と手動切り替え）はメニューに、
めったにやらない割り当て編集はウィンドウに。設定ウィンドウは 2 click 先なので、
そこに日常操作を隠すと存在しないのと同じになる。

メニューバーのメニューは項目を選ぶたびに閉じるので、6 スロットの割り当てを
そこでやると「開く → 選ぶ → 閉じる」を 6 回やることになる。それがウィンドウにした理由。

## 対応言語（実装の詳細）

UIの対応言語は **ja / en / zh-Hans / zh-Hant の 4 種のみ**。
想定ユーザーが日本語・中国語(簡体字・繁体字)話者なので、それ以外（キリル文字圏・タイ語など）は作っていません。開発言語を `en` にしてあるため、未知の言語環境では英語にフォールバックする。
言語切り替え自体は他の言語でもできます(未確認)

`Localizable.strings` のキーは日本語原文そのまま。
翻訳が引けない環境では自然に日本語が出る、というフォールバック順も兼ねている。
あるアプリだけ言語を切り替えて確認したいとき:

```sh
defaults write com.nico.mozu AppleLanguages -array en   # 英語で起動し直す
defaults delete com.nico.mozu AppleLanguages            # OS 設定に戻す
```

入力ソースの名前そのもの（「ひらがな」/「Hiragana」）は TIS が OS の言語設定で
返すので、このアプリでは翻訳を持たない。

## 構成

```
Sources/Mozu/
  MozuApp.swift        アプリ本体・AppDelegate・割り当て永続化
  ModifierMonitor.swift      単発押しの検出（CGEventTap・セッションレベル）
  InputSourceManager.swift   TIS API ラッパー（名前列の重複解消込み）
  CompositionCommit.swift    切り替え前の確定キー注入（Return / 英数 / かな）
  SourcesStore.swift         入力ソース一覧と現在値の保持
  KeySlot.swift              割り当て対象 6 キーの定義
  StatusItemController.swift メニューバー（NSStatusItem + NSMenuDelegate）
  SettingsView.swift         設定ウィンドウ＝割り当て編集 UI
  L10n.swift                 UI 文言の参照
Resources/Info.plist         LSUIElement などのバンドル情報
Resources/AppIcon.icns       アプリアイコン（make-icon.sh で再生成可能）
Resources/icon-1024.png      アイコン原画（Vision で切り抜いた白シルエット版の 1024px PNG）
Resources/MenuBarIcon.png    メニューバーアイコン（黒シルエットのテンプレート PNG、要コミット）
Resources/{ja,en,zh-Hans,zh-Hant}.lproj/Localizable.strings
Scripts/build-app.sh         .app バンドル化 + ad-hoc 署名（cdhash 不変の指定要件付き）
Scripts/make-icon.swift      元写真 → Vision で前景分割 → アプリアイコン 1024px PNG ＋メニューバー用黒シルエット
Scripts/make-icon.sh         元写真（Resources/shrike.jpg、git 管理外）→ icon-1024.png / MenuBarIcon.png → AppIcon.icns
                             写真が無い環境ではコミット済みの生成物を使う
Scripts/package-zip.sh       Release 添付用の zip 作成（git には入れない）
Formula/mozu.rb              Homebrew tap 用 formula（このリポジトリが tap を兼ねる）
docs/DESIGN.md               この文書
docs/assets/                 README 用の スクショ・デモ動画
```
