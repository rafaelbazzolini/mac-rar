cask "mac-rar" do
  version "2.1.0"
  arch arm: "arm64", intel: "x86_64"

  sha256 arm:   "045cd75ba66c3fb5faab2525fb31564e9a86a210685a129d4e66958684546fce",
         intel: "2d9070c44582246e80d29a122de05a62100e3e11372d9fc6067b8237effe3968"

  url "https://github.com/rafaelbazzolini/mac-rar/releases/download/v#{version}/MacRar-#{version}-#{arch}.zip"
  name "MacRar"
  desc "Native archive extractor and creator for macOS"
  homepage "https://github.com/rafaelbazzolini/mac-rar"

  depends_on macos: ">= :ventura"

  app "MacRar.app"

  zap trash: "~/Library/Preferences/com.macrar.app.plist"

  caveats <<~EOS
    MacRar is ad-hoc signed and is not Apple-notarized.
    macOS may require approval in System Settings > Privacy & Security
    on first launch. Homebrew does not bypass Gatekeeper.
  EOS
end
