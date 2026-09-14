class Mozu < Formula
  desc "Modifier-key single-tap input source switcher for macOS"
  homepage "https://github.com/nicokinu/mozu"
  url "https://github.com/nicokinu/mozu/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "9757ab29137d01d6b38ca351e20dc98c1b2487b5004b18e2b3efd8063f0fabf3"
  license "MIT"

  # Sources/Mozu は platforms: .macOS(.v14)。Swift は CLT 付属のもので足りる
  # （SwiftPM 依存ゼロなのでビルドにネットワークも不要）。
  # 実質 macOS 専用はホスト要件で担保されるので depends_on は書かない。

  def install
    # Scripts/build-app.sh が swift build -c release → .app バンドル化 →
    # 安定した designated requirement 付き ad-hoc 署名まで面倒を見る。
    # ローカルビルド生成物には quarantine が付かないので、Gatekeeper に
    # 署名/公証を要求させずに済む（cask にせず formula にした理由）。
    system "./Scripts/build-app.sh"
    prefix.install "build/Mozu.app"
  end

  def caveats
    <<~EOS
      起動:
        open #{opt_prefix}/Mozu.app

      初回は設定ウィンドウの「状態」でアクセシビリティと入力監視の
      両方を許可してください（片方だけだと変換中の確定だけが黙って壊れます）。
      ログイン時起動はアプリ内のトグルで ON にします（brew services では
      管理しません）。
    EOS
  end
end
