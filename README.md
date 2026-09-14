# Mozu

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.ja.md">日本語</a>
</p>

A macOS menu bar app that switches input sources on a **single tap** of a modifier key.

JIS keyboards have dedicated Kana/Eisu keys for Japanese, but there is no such key for Chinese or any other language. [eikana](https://github.com/KS1019/eikana) is a well-known app that does this for Japanese/English on US keyboards. Mozu extends the idea to any input source.

The name comes from the Japanese shrike (モズ). Its kanji name 百舌鳥 means "bird of a hundred tongues" — it is known for mimicking other birds.

![demo](docs/assets/mozu-demo.mp4)

## How it works

Every assignment is **absolute**, never a toggle:

- Releasing an assigned key selects that exact input source, whatever the current one is
- If that source is already selected, nothing happens
- It never interferes with normal shortcuts like `Cmd+C`: the tap only fires when the modifier is released and no other key was pressed in between

When you leave a Japanese or Chinese IME while a composition is still uncommitted, Mozu commits it first (via the Eisu key for Kotoeri, Return for Chinese IMEs) and only then switches. Nothing lingers invisibly in the background. As a side effect the cursor indicator may flash twice ("ABC", then the target language) — that is by design, see [docs/DESIGN.md](docs/DESIGN.md).

## Install

### Homebrew (this repository is the tap)

```sh
brew tap nicokinu/mozu https://github.com/nicokinu/mozu.git
brew install mozu
open "$(brew --prefix mozu)/Mozu.app"
```

The formula builds on your machine (zero SwiftPM dependencies, no network needed), so the app arrives without the macOS quarantine flag and opens normally.

### Zip (GitHub Releases)

Download `Mozu-vX.Y.Z.zip` from the releases page and drag `Mozu.app` to `/Applications`.

The build is ad-hoc signed, so a browser-downloaded copy is blocked on first launch ("cannot be opened because the developer cannot be verified"). Either of these passes:

- In Finder: **right-click → Open** (once only)
- In Terminal: `xattr -dr com.apple.quarantine /Applications/Mozu.app`

The brew and zip builds share the same bundle id and designated requirement, so macOS treats them as the same app and your permissions survive a swap.

## Permissions (both are required)

| Permission | Why |
|---|---|
| Input Monitoring | observing keystrokes — without it, typing is silently invisible |
| Accessibility | creating the event tap and injecting the commit keys |

⚠️ **Input Monitoring never shows a prompt.** In the settings window press `Grant…` and System Settings opens — flip Mozu's switch **manually**. With only Accessibility granted, switching itself still works but the pending-composition handling breaks silently, so Mozu starts monitoring only when both are granted.

## First run

1. Menu bar icon → **Settings…**
2. Under "Status", grant **Accessibility** and **Input Monitoring** (the setting window shows both rows)
3. Under "Key Assignments", pick an input source for each key
4. Turn on **Launch at Login**

The menu only lists input sources you have already added in System Settings → Keyboard → Input Sources. Add your languages there first.

Example assignment:

```
Left Command   → English (ABC)
Right Command  → Japanese (Hiragana)
Left Option    → Simplified Chinese (Pinyin)
Right Option   → Traditional Chinese (Zhuyin/Pinyin)
Left/Right Control → (spare slots)
```

<p float="left">
  <img src="docs/assets/menu.png" width="280" />
  <img src="docs/assets/settings.png" width="360" />
</p>

If two input sources share a display name (Kotoeri's romaji and kana modes both show "Hiragana"), Mozu appends an automatic suffix to tell them apart.

## Troubleshooting

If the switches in System Settings look ON but Mozu still acts ungranted:

```sh
tccutil reset Accessibility com.nico.mozu
tccutil reset ListenEvent com.nico.mozu   # Input Monitoring
```

then grant both again. Normal rebuilds do **not** revoke permissions: the signature embeds a designated requirement that does not depend on the binary hash.

## Building from source

```sh
./Scripts/build-app.sh
open build/Mozu.app
```

## Why this design

The full story — TIS vs key injection, the pending-composition problem, event tap levels, TCC identity, AppKit vs SwiftUI, release mechanics — lives in [docs/DESIGN.md](docs/DESIGN.md) (Japanese).

The UI ships in **ja / en / zh-Hans / zh-Hant**; other locales fall back to English.
