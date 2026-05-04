class Clawdex < Formula
  desc "Codex-pet-compatible companion overlay for Claude Code"
  homepage "https://github.com/danielkempe/clawdex"
  url "https://github.com/danielkempe/clawdex/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_TARBALL"
  license "MIT"
  head "https://github.com/danielkempe/clawdex.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/clawdex"
    bin.install ".build/release/clawdexd"

    # Hook scripts into share/clawdex/hooks so the installer can find them.
    (share/"clawdex/hooks").install Dir["hooks/clawdex-hook", "hooks/clawdex-statusline"]
    (share/"clawdex").install "install.sh"
    (share/"clawdex").install "skill"
  end

  def caveats
    <<~EOS
      To wire the Claude Code hooks and start the daemon at login, run:
        #{share}/clawdex/install.sh

      Then:
        clawdex list
        clawdex wake

      Pets are read from ~/.codex/pets/ and ~/.clawdex/pets/.
      Existing Codex pets work unmodified.
    EOS
  end

  service do
    run [opt_bin/"clawdexd"]
    keep_alive true
    log_path var/"log/clawdex.log"
    error_log_path var/"log/clawdex.log"
  end

  test do
    assert_match "Codex-pet companion", shell_output("#{bin}/clawdex 2>&1", 2)
  end
end
