# obsidian_scansnap

ScanSnap でスキャンした書類を、ローカル LLM で要約して Obsidian のノートに自動変換する仕組み。

監視フォルダにファイルが入ると launchd が起動し、PDF なら本文を抽出してローカル LLM（Ollama）に日付・タイトル・要約を生成させ、`日付_タイトル.md` のノートを作る。元ファイルは `_resources/` に移動され、ノートから embed で参照される。クラウドに書類を送らずローカル完結で処理する。

## 動作の流れ

```
_incoming/ にファイルが入る
        ↓  launchd (WatchPaths) が発火
        ↓  内容の SHA-256 で処理済みを判定（同名・別内容は別ファイル扱い）
        ├─ PDF      → pdftotext で本文抽出 → Ollama で 日付/タイトル/要約 を生成
        └─ PDF 以外 → LLM 推論はスキップ
        ↓
001_scanbox/日付_タイトル.md を作成（embed リンク入り）
        ↓
元ファイルを _resources/ へ移動 → 処理済みリストに記録
```

取り込んだファイルは必ず vault に残ることを優先している。LLM が落ちていても、応答が壊れていても、PDF 以外でも、要約なしのノートを作って元ファイルを保全する。

### 日付とタイトルの決定

| 項目 | 優先順位 |
|---|---|
| 日付 | 1. LLM が書類本文から抽出（8桁として妥当な場合のみ）→ 2. 元ファイル名の日付（`20260401` / `2026-04-01` / `2026_04_01`）→ 3. 処理日 |
| タイトル | 1. LLM が生成 → 2. 元ファイル名から日付・連番を除いたもの → 3. `無題` |

同名ノートがある場合は `_2`, `_3` と連番が付く。`_resources/` に同名ファイルがある場合も同様に連番が付くため、先に取り込んだ実ファイルが上書きで失われることはない。

## 構成

| ファイル | 役割 |
|---|---|
| `scan_to_obsidian_local_v2.sh` | 本体。取り込み・要約・ノート作成・ファイル移動 |
| `com.user.scansnap-obsidian-local.plist.template` | launchd 定義のテンプレート。`_incoming` を WatchPaths で監視 |
| `install.sh` | テンプレートのパスを置換して配置し、launchd に登録する |
| `test/run_test.sh` | 本番パスに触れず `test/` 配下だけで動作確認するラッパー |
| `CLAUDE.md` | 開発時の約束事（テストは必ず `test/` を使う、本番反映手順） |

### 本番のパス

| 用途 | パス |
|---|---|
| 監視対象（未処理の置き場） | `~/syncthing/notes/001_scanbox/_incoming` |
| ノート出力先 | `~/syncthing/notes/001_scanbox` |
| 元ファイル保管先 | `~/syncthing/notes/001_scanbox/_resources` |
| ログ | `~/Library/Logs/scan_to_obsidian.log` |
| 処理済みリスト（SHA-256） | `~/.scan_to_obsidian_processed` |

`_incoming` は Syncthing の `.stignore` で同期対象外にする想定（未処理ファイルを NAS/iOS に同期させないため）。`_resources` と生成ノートは同期対象。

## 必要なもの

```bash
brew install poppler jq ollama
ollama pull qwen3:4b
ollama serve
```

モデルは `scan_to_obsidian_local_v2.sh` の `OLLAMA_MODEL` で切り替える。`qwen3:4b` は速度重視の選択で、精度を上げたい場合は `dsasai/llama3-elyza-jp-8b` などの日本語特化モデルを使う。1件あたりの処理時間は書類の分量とモデルサイズ次第で、4B モデルで概ね 10 秒〜2 分程度。

## テスト

本番の `_incoming` に直接ファイルを置くと launchd が誤発火するため、動作確認は必ず `test/` を使う。

```bash
# test/vault/001_scanbox/_incoming/ にファイルを置いてから
./test/run_test.sh
```

`run_test.sh` が `VAULT_DIR` / `LOG_FILE` / `PROCESSED_LIST` を `test/` 配下へ差し替えて本体を起動する。本体は環境変数が未設定なら本番パスにフォールバックするため、本番用にコピーし直す際の書き換えは不要。`test/vault/` と `test/logs/` は `.gitignore` 対象。

Ollama の障害時の挙動を確認したい場合は、エンドポイントを潰して実行する。

```bash
OLLAMA_TAGS_URL=http://localhost:19999/api/tags OLLAMA_URL=http://localhost:19999/api/chat ./test/run_test.sh
```

## インストール / 本番反映

```bash
./install.sh
```

スクリプトを `~/bin/` へ、plist を `~/Library/LaunchAgents/` へ配置して launchd に登録する。

launchd は plist 内の `~` や `$HOME` を展開しないため、パスは絶対パスでなければならない。そのため plist はテンプレートとして持ち、`install.sh` が実行環境の値に置換して書き出す。

vault の位置が既定（`~/syncthing/notes`）と違う場合は環境変数で指定する。

```bash
VAULT_DIR=~/Documents/vault ./install.sh
```

監視対象のフォルダを直接指定することもできる。

```bash
INCOMING_DIR=~/scan_inbox ./install.sh
```

スクリプトだけを更新したい場合（plist に変更がないとき）は、コピーするだけでよい。launchd は起動のたびにスクリプトを読み直すため、再登録は不要。

```bash
cp scan_to_obsidian_local_v2.sh ~/bin/scan_to_obsidian_local_v2.sh
```

## トラブルシュート

**発火しているかを確認する**

```bash
launchctl print gui/$(id -u)/com.user.scansnap-obsidian-local
```

`runs` が増えていれば launchd は起動している。`state = running` かつ `watching = 0` は実行中に監視が一時的に外れているだけで正常。実行中は LLM 推論で数分かかることがある。

**ノートができない**

まずログを見る。`_incoming` にファイルが残ったままで `処理開始` のログもない場合、内容が処理済みリストの SHA-256 と一致している（＝過去に取り込んだのと同一内容）可能性が高い。

```bash
grep -n "$(shasum -a 256 path/to/file.pdf | awk '{print $1}')" ~/.scan_to_obsidian_processed
```

**注意**: 監視対象はフォルダ全体なので、PDF 以外のファイルや `.DS_Store` の作成でも launchd は起動する。ただし処理ループが実際に扱うのは通常ファイルのみで、隠しファイルとディレクトリは対象外。
