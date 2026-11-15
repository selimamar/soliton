# The Homebrew cask for the Soliton Mac app (docs/releasing.md). Its home is
# Casks/soliton.rb in the selimamar/homebrew-tap repository; this copy is the
# template. The release workflow keeps `version` and `sha256` up to date
# there.
#
#   brew install --cask selimamar/tap/soliton
cask "soliton" do
  version "0.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/selimamar/soliton/releases/download/v#{version}/Soliton-#{version}.zip"
  name "Soliton"
  desc "Follow training runs and simulations while they run"
  homepage "https://github.com/selimamar/soliton"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :monterey"

  app "Soliton.app"

  zap trash: "~/Library/Containers/io.github.selimamar.soliton"

  caveats <<~EOS
    Soliton isn't notarised by Apple, so macOS blocks it the first time.
    Open it once, then choose System Settings → Privacy & Security →
    Open Anyway. Or, from a terminal:
      xattr -dr com.apple.quarantine /Applications/Soliton.app

    After each update, macOS asks once more whether Soliton may read its
    server token from your keychain: choose Always Allow.
  EOS
end
