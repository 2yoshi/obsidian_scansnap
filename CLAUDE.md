# obsidian_scansnap

ScanSnap → Obsidian 自動要約システムの作業コピー。本番は以下に配置されている:

- スクリプト本体: `~/bin/scan_to_obsidian_local_v2.sh`
- launchd plist: `~/Library/LaunchAgents/com.user.scansnap-obsidian-local.plist`
- 本番の監視対象: `~/syncthing/notes/001_scanbox/_incoming`

## テスト時の注意

**本番の `~/syncthing/notes/001_scanbox/_incoming` には直接ファイルを置かないこと。**
launchd の WatchPaths がそのフォルダを監視しており、テスト用ファイルを置くと
本番の自動処理(Ollama LLM推論・Obsidianノート作成)が誤発火する。

動作確認は必ず `test/` ディレクトリを使う:

```bash
# テスト用ファイルを test/vault/001_scanbox/_incoming/ に置いてから実行
./test/run_test.sh
```

`test/run_test.sh` が `VAULT_DIR` / `LOG_FILE` / `PROCESSED_LIST` を
`test/vault/`, `test/logs/` 配下に差し替えて `scan_to_obsidian_local_v2.sh` を
起動する。スクリプト本体は環境変数が未設定なら本番パスにフォールバックする
ようになっているため、本番用にコピーし直す際も変更不要。

## 本番反映の手順

このディレクトリで動作確認が取れたら、以下にコピーして反映する:

```bash
cp scan_to_obsidian_local_v2.sh ~/bin/scan_to_obsidian_local_v2.sh
cp com.user.scansnap-obsidian-local.plist ~/Library/LaunchAgents/com.user.scansnap-obsidian-local.plist
launchctl unload ~/Library/LaunchAgents/com.user.scansnap-obsidian-local.plist
launchctl load ~/Library/LaunchAgents/com.user.scansnap-obsidian-local.plist
```
