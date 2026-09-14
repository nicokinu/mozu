# Mozu

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.ja.md">日本語</a> |
  <a href="README.zh-CN.md">简体中文</a> |
  <a href="README.zh-TW.md">繁體中文</a>
</p>

按下修飾鍵**一次**即可切換輸入法的 macOS 選單列常駐應用。

JIS 鍵盤有專用「仮名」「英數」鍵，但沒有任何按鍵可以切換到中文或其他語言。在 US 鍵盤上切換日語和英語的知名應用是 [eikana（英かな）](https://github.com/KS1019/eikana)，Mozu 想把同樣的體驗帶到所有語言。

名字來自鳥類——莫茲（日本歌鶇，モズ）。它的漢字名「百舌鳥」意為「擁有百種舌頭的鳥」，據說擅長模仿其他鳥的叫聲。

![demo](docs/assets/mozu-demo.gif)

## 設計方針（為什麼不是切換式）

中文輸入法一般用 Shift 在中英之間切換：中文時切到英文，英文時切回中文。
但這種來回切換必須先看清「現在是哪種語言」。
為了確認而移動視線時，注意力也跟著飛走，思路就斷了。

所以 Mozu 只提供**絕對指定**：

- 鬆開分配鍵的瞬間狀態就正確了（結果不受目前狀態影響）
- 該輸入源已被選取時，什麼都不做
- 不干擾現有快捷鍵（`Cmd+C` 等）

在輸入法（日文／中文）還有未確定文字時切換語言，IME 會把未確定文字以「掛起」而不是「提交」的方式保留，之後切回同一輸入法時突然冒出，令人困惑。Mozu 為了避開這一點，會在離開輸入法前**先注入一次確定鍵再切換**（日語用英數鍵，中文用 Return）。

其副作用是：從日語切走時，游標旁的指示器會**閃爍兩次**（先顯示 ABC，再顯示目標語言）。這是有意設計：去掉英數確定雖然只剩一次顯示，但「確定未完成就切換」的競態會復活，後台殘留的 bug 也會回來。我們選擇的是資料，不是外觀。

## 安裝

### Homebrew（本倉庫本身就是 tap）

```sh
brew tap nicokinu/mozu https://github.com/nicokinu/mozu.git
brew install mozu
open "$(brew --prefix mozu)/Mozu.app"
```

formula 在你自己的機器上建置（SwiftPM 零相依，建置也不需要網路），產物不帶 quarantine 標記，可以正常開啟。

### zip（GitHub Releases）

從 Releases 頁面下載 `Mozu-vX.Y.Z.zip`，把 `Mozu.app` 拖到 `/Applications`。

採 ad-hoc 簽名，瀏覽器下載後首次雙擊會提示「無法開啟，來自身份不明的開發者」。兩種方式任選其一：

- 在 Finder 中**右鍵 → 開啟**（僅第一次）
- 終端機執行 `xattr -dr com.apple.quarantine /Applications/Mozu.app`

brew 版和 zip 版的 bundle id 與 designated requirement 相同，macOS 視為同一個應用，互換版本權限依然保留。

## 所需權限（兩項都必須）

| 權限 | 作用 |
|---|---|
| 輸入監控 | 偵測按鍵。沒有它，打字內容會無聲地看不見 |
| 輔助使用 | 建立事件 tap、注入確定鍵（英數／假名／Return） |

⚠️ **「輸入監控」不會跳出授權對話框。** 在設定視窗點「授予…」會開啟系統設定，請**手動開啟** Mozu 的開關。只給輔助使用時，切換本身還能用，只有「轉換中確定」會無聲壞掉——這種壞法最難察覺，所以 Mozu 要兩項都齊了才開始監聽。

## 首次啟動

1. 選單列圖示 → **設定…**
2. 「狀態」裡授予**輔助使用**和**輸入監控**
3. 「按鍵分配」裡為每個鍵選擇輸入源
4. 開啟**登入時啟動**

選單裡沒有任何輸入源時，請先到「系統設定 → 鍵盤 → 輸入法」新增你要使用的語言（`TISSelectInputSource` 只能選取已新增的輸入源）。

### 分配範例

```
左 Command  → 英語 (ABC)
右 Command  → 日語（平假名）
左 Option   → 簡體中文（拼音）
右 Option   → 繁體中文（注音符號／拼音）
左/右 Control → （備用槽位）
```

分配可以在選單裡自由更改。

<p float="left">
  <img src="docs/assets/menu.png" width="406" />
  <img src="docs/assets/settings.png" width="266" />
</p>

不同的輸入源有時會使用相同顯示名（例如 Kotoeri 的羅馬輸入和假名輸入都叫「平假名」）。這時 Mozu 會自動附加後綴加以區分（`平假名（羅馬輸入）` / `平假名（假名輸入）`）。

## 疑難排解

系統設定裡的開關明明是 ON，Mozu 的行為卻像未授權：

```sh
tccutil reset Accessibility com.nico.mozu
tccutil reset ListenEvent com.nico.mozu   # 輸入監控
```

執行後重新授予兩項權限。一般的重新建置**不會**使權限失效（簽名中內嵌了不依賴二進位雜湊的 designated requirement，詳見 [docs/DESIGN.md](docs/DESIGN.md)，日文文件）。

## 建置

```sh
./Scripts/build-app.sh
open build/Mozu.app
```

`swift build` 也能做偵錯建置，但要作為選單列常駐應用正常運作，需要 `.app` 套件（`LSUIElement` 與穩定的 bundle id）。

## 介面語言

介面支援 **ja / en / zh-Hans / zh-Hant 四種**。開發語言設為 `en`，未知語言環境會回退到英語。

## 為什麼是這種設計

與英かな的差異、未確定文字掛起機制、事件 tap 的階層、TCC 的識別方式、選單列用 AppKit 的理由、發布流程等，都寫在 [docs/DESIGN.md](docs/DESIGN.md)（日文）。
