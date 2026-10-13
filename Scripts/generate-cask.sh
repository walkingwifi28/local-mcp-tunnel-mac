#!/bin/bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  cat >&2 <<'EOF'
Usage:
  ./Scripts/generate-cask.sh <version> <sha256> <download-url> <output-file> [homepage]

Example:
  ./Scripts/generate-cask.sh \
    1.0.0 \
    <sha256> \
    https://github.com/walkingwifi28/local-mcp-tunnel/releases/download/v1.0.0/Local-MCP-Tunnel-1.0.0-arm64.zip \
    Casks/local-mcp-tunnel.rb \
    https://github.com/walkingwifi28/local-mcp-tunnel
EOF
  exit 1
fi

VERSION="$1"
SHA256="$2"
DOWNLOAD_URL="$3"
OUTPUT_FILE="$4"
HOMEPAGE="${5:-https://github.com/walkingwifi28/local-mcp-tunnel}"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z.-]+)*$ ]]; then
  echo "Error: invalid version: $VERSION" >&2
  exit 1
fi

if [[ ! "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Error: SHA-256 must contain 64 hexadecimal characters." >&2
  exit 1
fi

if [[ ! "$DOWNLOAD_URL" =~ ^https://github.com/ ]] && [[ ! "$DOWNLOAD_URL" =~ ^file:// ]]; then
  echo "Error: unsupported download URL: $DOWNLOAD_URL" >&2
  exit 1
fi

SHA256_LOWER="$(printf '%s' "$SHA256" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<EOF
cask "local-mcp-tunnel" do
  version "$VERSION"
  sha256 "$SHA256_LOWER"

  url "$DOWNLOAD_URL"
  name "Local MCP Tunnel"
  desc "GUI for controlling tunnel-client and local-mcp"
  homepage "$HOMEPAGE"

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
EOF

echo "Cask generated: $OUTPUT_FILE"
