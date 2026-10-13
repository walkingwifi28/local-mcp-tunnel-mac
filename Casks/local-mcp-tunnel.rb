cask "local-mcp-tunnel" do
  version "0.1.20"
  sha256 "ef4d118dc4c9c53908724b6178615401535e73c53ad7a5ab380f5ecc2de8a9bd"

  url "https://github.com/walkingwifi28/local-mcp-tunnel-mac/releases/download/v0.1.20/Local-MCP-Tunnel-0.1.20-arm64.zip"
  name "Local MCP Tunnel"
  desc "GUI for controlling tunnel-client and local-mcp"
  homepage "https://github.com/walkingwifi28/local-mcp-tunnel-mac"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on formula: "openai/tools/tunnel-client"
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Local MCP Tunnel.app"

  caveats <<~EOS
    This build is ad hoc signed but is not Apple notarized.
    If macOS blocks the app on first launch, run:
      xattr -dr com.apple.quarantine /Applications/Local\ MCP\ Tunnel.app
  EOS

  zap trash: [
    "~/Library/Preferences/jp.co.walkingwifi.LocalMCPTunnel.plist",
    "~/Library/Saved Application State/jp.co.walkingwifi.LocalMCPTunnel.savedState",
    "~/Library/Preferences/jp.co.varista.LocalMCPTunnelApp.plist",
    "~/Library/Saved Application State/jp.co.varista.LocalMCPTunnelApp.savedState",
  ]
end
