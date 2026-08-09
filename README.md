# Local MCP Tunnel

`tunnel-client`と`local-mcp`をSwiftUIから操作するmacOSアプリです。

- 対応CPU: Apple Silicon（arm64）のみ
- 対応OS: macOS 14 Sonoma以降

## インストール

Homebrew Caskからインストールします。

```bash
brew tap walkingwifi28/local-mcp-tunnel https://github.com/walkingwifi28/local-mcp-tunnel.git
brew trust --cask walkingwifi28/local-mcp-tunnel/local-mcp-tunnel
brew install --cask local-mcp-tunnel
```

起動します。

```bash
open /Applications/Local\ MCP\ Tunnel.app
```

現在の自動ReleaseはDeveloper ID署名・Apple公証を設定していない場合、ad hoc署名で公開されます。Gatekeeperで起動を止められた場合は、Finderでアプリを右クリックして「開く」を選択してください。それでも起動できない場合はquarantine属性を削除します。

```bash
xattr -dr com.apple.quarantine /Applications/Local\ MCP\ Tunnel.app
open /Applications/Local\ MCP\ Tunnel.app
```

アンインストール:

```bash
brew uninstall --cask local-mcp-tunnel
```

## アプリ内更新

設定画面の「アプリの更新」でGitHub Releaseの最新版を確認できます。更新がある場合は、表示された更新ボタンを押すと次の処理を行います。

1. Apple Silicon arm64向けZIPとSHA-256ファイルをダウンロード
2. SHA-256、Bundle ID、バージョン、コード署名を検証
3. アプリ終了後に現在の`.app`を新しいバージョンへ差し替え
4. 更新後のアプリを自動で再起動

更新には、現在のアプリが保存されているフォルダへの書き込み権限が必要です。通常は`/Applications/Local MCP Tunnel.app`へインストールして使用してください。

## 対応コマンド

```bash
tunnel-client init --sample sample_mcp_stdio_local --profile <profile> --tunnel-id <tunnel-id> --mcp-command "$HOME/.local/bin/local-mcp mcp" --force
tunnel-client run --profile <profile>
local-mcp start <session-id>
```

local-mcp起動後、以下を標準入力へ送信できます。

```text
/permission ask
/permission yolo
/permission allow <directory>
/permission revoke <directory>
/permission list
/permission status
```

## 設定保存

- Profile、Tunnel ID、Session IDなど: `UserDefaults`
- `CONTROL_PLANE_API_KEY`: macOS Keychain
- App Sandbox: 無効（任意のCLIとディレクトリへアクセスするため）
- Hardened Runtime: 有効

## 開発

```bash
open LocalMCPTunnel.xcodeproj
```

### Debugビルド確認

```bash
./Scripts/verify-build.sh
```

XcodeのCommand Line Toolsだけが選択されている場合は、Xcode本体を選択してください。

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## リリースフロー

`v*`タグをpushすると、`.github/workflows/macos-release.yml`が次の処理を自動実行します。

1. シェルスクリプトの構文検証
2. Apple Silicon arm64向けReleaseビルド
3. `.app`のZIP化
4. SHA-256ファイルの生成と再検証
5. GitHub Releaseの作成とZIP・SHA-256の添付
6. このリポジトリの`Casks/local-mcp-tunnel.rb`を更新
7. CaskのRuby構文検証、デフォルトブランチへのcommit・push

### Homebrew tapの構成

参照リポジトリと同様に、このリポジトリ自体をHomebrew tapとして利用します。別の`homebrew-tap`リポジトリや専用Personal Access Tokenは不要です。workflowの`GITHUB_TOKEN`と`contents: write`権限で、同じリポジトリの`Casks/local-mcp-tunnel.rb`を更新します。

リポジトリ名が`homebrew-`で始まらないため、利用者は`brew tap`時にGit URLを明示します。

```bash
brew tap walkingwifi28/local-mcp-tunnel https://github.com/walkingwifi28/local-mcp-tunnel.git
```

Homebrewで一般公開するには、GitHub ReleaseのZIPへ認証なしでアクセスできる必要があるため、このリポジトリをpublicにしてください。デフォルトブランチに直接pushできないブランチ保護を設定している場合は、GitHub Actionsからのpushを許可するか、Pull Request方式へ変更する必要があります。

### 公開方法

```bash
git tag v1.0.0
git push origin v1.0.0
```

生成物:

```text
Local-MCP-Tunnel-1.0.0-arm64.zip
Local-MCP-Tunnel-1.0.0-arm64.zip.sha256
```

Release URL:

```text
https://github.com/walkingwifi28/local-mcp-tunnel/releases/download/v1.0.0/Local-MCP-Tunnel-1.0.0-arm64.zip
```

### ローカルでReleaseパッケージを作る

```bash
./Scripts/build-release.sh 1.0.0
```

生成物は`dist/`へ出力されます。スクリプトは次も検証します。

- 実行バイナリがarm64のみであること
- `CFBundleShortVersionString`が指定バージョンと一致すること
- app bundleのコード署名が検証できること

### ローカルCask生成

```bash
VERSION=1.0.0
ARCHIVE="dist/Local-MCP-Tunnel-${VERSION}-arm64.zip"
SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

./Scripts/generate-cask.sh \
  "$VERSION" \
  "$SHA256" \
  "file://$(pwd)/$ARCHIVE" \
  dist/local-mcp-tunnel.rb \
  "https://github.com/walkingwifi28/local-mcp-tunnel"

ruby -c dist/local-mcp-tunnel.rb
brew install --cask "$(pwd)/dist/local-mcp-tunnel.rb"
```

## workflow・スクリプトの検証

```bash
bash -n Scripts/*.sh
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/macos-release.yml"); puts "workflow YAML OK"'
```

`actionlint`がインストールされている場合は、GitHub Actions固有の構文も検証できます。

```bash
actionlint .github/workflows/macos-release.yml
```

## ライセンス

[MIT License](LICENSE)

## Developer ID署名・Apple公証

`Scripts/build-release.sh`は次の環境変数に対応しています。

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: COMPANY NAME (TEAM_ID)" \
NOTARYTOOL_PROFILE="local-mcp-tunnel-notary" \
./Scripts/build-release.sh 1.0.0
```

`NOTARYTOOL_PROFILE`を指定する場合は、事前にKeychainへ資格情報を保存します。

```bash
xcrun notarytool store-credentials local-mcp-tunnel-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```
