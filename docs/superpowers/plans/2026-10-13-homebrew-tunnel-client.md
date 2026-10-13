# 公式 Homebrew tunnel-client への移行

承認済み方針: 公式 Formula を Cask の依存にする。GUI の init/run、停止、ログ管理、Keychain と既存の手動パス設定は維持する。

- Casks/local-mcp-tunnel.rb と Scripts/generate-cask.sh に公式 Formula の依存を追加する。
- ShellPathResolver.swift で名前指定の tunnel-client のみ Homebrew の安定した opt/bin と bin を優先する。
- SettingsView.swift に実行ファイルのパスと --version の結果、再確認、公式導入・更新コマンドを表示する。確認は非同期、時間制限付きとし、API キーを渡さない。
- README.md に公式導入と更新、手動パスの扱いを記載する。
- 一時ディレクトリの実行ファイルで明示パス・PATH 解決を検証し、Cask 生成結果の Ruby 構文と依存を確認する。既存の Debug ビルドを実行する。
