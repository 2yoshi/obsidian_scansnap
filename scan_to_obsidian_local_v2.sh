#!/bin/bash
###############################################################################
# scan_to_obsidian_local_v2.sh
#
# 001_scanbox/_incoming に新しいファイルが入ったら
#   PDFの場合:
#     1. pdftotext でテキスト抽出
#     2. ローカルLLM(Ollama)で JSON形式(日付/タイトル/要約)を取得
#     3. 001_scanbox 直下に "日付_タイトル.md" で新規ノートを作成
#     4. スキャン元PDFは 001_scanbox/_resources に移動
#   PDF以外の場合:
#     LLM推論・テキスト抽出は行わず、ファイル名から日付・タイトルを推定して
#     ノート作成とリンク挿入(embed)のみ行う(3,4は共通)
#
# _incoming は .stignore でSyncthing同期対象外にする想定(未処理ファイルを
# NAS/iOSに同期させないため)。_resources と生成ノートは同期対象。
#
# 事前準備:
#   brew install poppler jq ollama
#   ollama pull dsasai/llama3-elyza-jp-8b   # 好みの日本語特化モデル
#   ollama serve
###############################################################################

set -euo pipefail

# launchd経由の実行はLANG/LC_ALLが未設定(Cロケール)になりがちで、
# cut/tr/sedがマルチバイト文字を"バイト単位"で処理し日本語の途中で
# 文字列を切断してしまう(→不正なファイル名でIllegal byte sequence)。
# それを防ぐため明示的にUTF-8ロケールを固定する。
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# ==== 設定 ====
# 環境変数で上書きされなければ本番パスを使う(テスト時は test/run_test.sh が
# これらを test/ 配下に差し替えて実行する)
VAULT_DIR="${VAULT_DIR:-$HOME/syncthing/notes}"
INBOX_DIR="${INBOX_DIR:-$VAULT_DIR/001_scanbox/_incoming}"
NOTES_DIR="${NOTES_DIR:-$VAULT_DIR/001_scanbox}"
RESOURCES_DIR="${RESOURCES_DIR:-$VAULT_DIR/001_scanbox/_resources}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/scan_to_obsidian.log}"
PROCESSED_LIST="${PROCESSED_LIST:-$HOME/.scan_to_obsidian_processed}"

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/chat}"
OLLAMA_TAGS_URL="${OLLAMA_TAGS_URL:-http://localhost:11434/api/tags}"
OLLAMA_MODEL="qwen3:4b"   # 速度重視。精度重視なら dsasai/llama3-elyza-jp-8b や schroneko/llama-3.1-swallow-8b-instruct-v0.1

mkdir -p "$RESOURCES_DIR" "$NOTES_DIR"
touch "$PROCESSED_LIST"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
  # ERROR始まりのログはmacOS通知でも知らせる
  case "$1" in
    ERROR:*)
      if command -v shortcuts >/dev/null 2>&1; then
        # terminal-notifier/osascriptは廃止APIのため最新macOSで通知許可が
        # 得られないことがある。ショートカット(Shortcuts.app)経由が確実。
        # 事前に「ScanSnapNotify」という名前のショートカットを作成しておくこと
        # (入力を受け取り、「通知を表示」アクションの本文に渡すだけの簡単な内容)。
        if ! shortcuts_err=$(echo "$1" | shortcuts run "ScanSnapNotify" 2>&1 1>/dev/null); then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: shortcuts run 失敗: $shortcuts_err" >> "$LOG_FILE"
        fi
      elif command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "ScanSnap→Obsidian 要約処理" -message "$1" -sound Basso \
          >/dev/null 2>&1 || true
      else
        local msg="${1//\\/\\\\}"
        msg="${msg//\"/\\\"}"
        osascript -e "display notification \"$msg\" with title \"ScanSnap→Obsidian 要約処理\" sound name \"Basso\"" \
          >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# ファイル名に使えない文字を置換し、長さを制限
# (tr の SET1/SET2 長さ不一致バグを避けるため sed ベースで実装)
sanitize_filename() {
  local s="$1"
  # 不正なUTF-8バイト列があれば破棄して有効なUTF-8だけ残す(防御線)
  s=$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$s")
  # 改行・タブなどの制御文字を除去
  s=$(printf '%s' "$s" | tr -d '\n\r\t')
  # ファイル名に使えない記号・半角/全角スペースをアンダースコアに置換
  s=$(printf '%s' "$s" | sed -e 's#[/:*?"<>|]#_#g' -e 's/[ 　]/_/g')
  # 先頭・末尾の連続アンダースコアを除去
  s=$(printf '%s' "$s" | sed 's/^_*//;s/_*$//')
  # 60文字に制限(UTF-8ロケール下では文字単位でカットされる)
  printf '%s' "$s" | cut -c1-60
}

# Obsidianのwikilink構文を壊す文字だけを置換する
# (| はエイリアス区切り、[ ] は括弧、# は見出しアンカー、^ はブロック参照)
sanitize_link_target() {
  printf '%s' "$1" | sed -e 's/[][|#^]/_/g'
}

# ファイル名から日付(YYYYMMDD)を推定。見つからなければ空文字を返す
extract_date_from_filename() {
  local base="$1"
  local date_match filename_date
  date_match=$(echo "$base" | grep -oE '[0-9]{4}[-_]?[0-9]{2}[-_]?[0-9]{2}' | head -1 || true)
  # BSD(macOS)の tr は '-_' を先頭ハイフンのオプションとして解釈して失敗するため
  # 外部コマンドを使わずbashのパラメータ展開で区切り文字を除去する
  filename_date="${date_match//[-_]/}"
  if [[ "$filename_date" =~ ^[0-9]{8}$ ]] && date -j -f "%Y%m%d" "$filename_date" >/dev/null 2>&1; then
    printf '%s' "$filename_date"
  fi
}

# ファイル名(拡張子・日付らしき部分を除いたもの)からタイトルを推定
# (例: "20260315_143022_scan.pdf" -> "scan")
title_from_filename() {
  local base="$1"
  local t="${base%.*}"
  t=$(echo "$t" | sed -E \
    -e 's/[0-9]{4}[-_]?[0-9]{2}[-_]?[0-9]{2}//g' \
    -e 's/[0-9]{2}[.:_][0-9]{2}[.:_][0-9]{2}//g' \
    -e 's/[0-9]{6,}//g')
  sanitize_filename "$t"
}

shopt -s nullglob
for item in "$INBOX_DIR"/*; do
  [ -d "$item" ] && continue
  base=$(basename "$item")

  # 取り込み中の一時ファイルがglob展開後に消えることがある。set -e で
  # ログを残さず全体が落ちないよう、失敗はこのファイルのスキップに留める
  if ! file_hash=$(shasum -a 256 "$item" 2>>"$LOG_FILE" | awk '{print $1}') || [ -z "$file_hash" ]; then
    log "警告: ハッシュ計算に失敗、次回トリガーで再試行します: $base"
    continue
  fi

  # ファイル名ではなく内容のSHA-256で重複判定(同名・別内容の誤スキップを防ぐ)
  if grep -q "^${file_hash}  " "$PROCESSED_LIST"; then
    log "スキップ(処理済みハッシュと一致): $base"
    continue
  fi

  case "$base" in
    *.[Pp][Dd][Ff]) is_pdf=1 ;;
    *) is_pdf=0 ;;
  esac

  # まずファイル名ベースの値を既定値として用意する。
  # LLM推論が成功した場合のみ、この後で推論結果で上書きする。
  # (非PDF・LLM失敗のどちらの場合もこの既定値のままノートを作成する)
  doc_date=$(extract_date_from_filename "$base")
  [ -z "$doc_date" ] && doc_date=$(date '+%Y%m%d')
  safe_title=$(title_from_filename "$base")
  [ -z "$safe_title" ] && safe_title="無題"

  if [ "$is_pdf" -eq 1 ]; then
    log "処理開始: $base (sha256: ${file_hash:0:12}...)"
    summary="(LLM推論に失敗したため自動要約なし)"
    result_json=""

    if ! curl -sS "$OLLAMA_TAGS_URL" >/dev/null 2>&1; then
      log "警告: Ollamaサーバーに接続できません。要約なしでノートを作成します: $base"
    else
      # 1. テキスト抽出
      text=$(pdftotext -layout "$item" - 2>>"$LOG_FILE" || true)
      if [ -z "$text" ]; then
        log "警告: テキスト抽出不可(画像のみのPDFの可能性): $base"
        text="(テキスト抽出不可。手動確認が必要)"
      fi
      # ロケール固定でcut -cは文字単位になるが、念のため不正バイトも除去しておく
      text_trunc=$(printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null | cut -c1-4000)

      # 2. JSON形式で 日付/タイトル/要約 を取得
      prompt="以下はスキャンした書類のOCRテキストです。次のJSON形式で**のみ**回答してください。前置き・説明文・コードブロック記号は一切不要です。
{
  \"document_date\": \"書類内に記載されている日付をYYYYMMDD形式(例: 20260315)で。見つからなければ空文字\",
  \"title\": \"書類の内容を表す15文字以内の簡潔な日本語タイトル。スペースや記号(/:*?\\\"<>|)は使わない\",
  \"summary\": \"3〜5行程度の日本語要約。書類の種類・日付・金額・差出人など重要情報があれば箇条書きで含める\"
}

---
$text_trunc"

      payload=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$prompt" \
        '{model: $model, messages: [{role: "user", content: $content}], format: "json", stream: false}')

      # curl自体が失敗しても set -e で全体が落ちないようにする(要約なしで続行)
      response=$(curl -sS "$OLLAMA_URL" -d "$payload" || true)
      result_json=$(echo "$response" | jq -r '.message.content // empty' 2>>"$LOG_FILE" || true)

      if [ -z "$result_json" ]; then
        # 応答全体をログに流すと thinking フィールドで1行が数KBになるため、
        # エラー本文だけを取り出して長さも切り詰める
        err_detail=$(echo "$response" | jq -r '.error // "応答にcontentが含まれていません"' 2>/dev/null | head -1 | cut -c1-200 || true)
        log "警告: LLM応答取得失敗、要約なしでノートを作成します: $base ($err_detail)"
      fi
    fi

    # 3. 推論に成功した項目だけ既定値を上書きする
    if [ -n "$result_json" ]; then
      llm_date=$(echo "$result_json" | jq -r '.document_date // empty' 2>>"$LOG_FILE" || true)
      llm_title=$(echo "$result_json" | jq -r '.title // empty' 2>>"$LOG_FILE" || true)
      llm_summary=$(echo "$result_json" | jq -r '.summary // empty' 2>>"$LOG_FILE" || true)

      # 日付優先順位: 1.LLMが書類内容から抽出 → 2.ファイル名/処理日(既定値)
      if [[ "$llm_date" =~ ^[0-9]{8}$ ]]; then
        doc_date="$llm_date"
      else
        log "書類内に有効な日付が見つからず、ファイル名または処理日で代用: $base (LLM抽出値: '$llm_date' → $doc_date)"
      fi

      llm_safe_title=$(sanitize_filename "$llm_title")
      if [ -n "$llm_safe_title" ] && [ "$llm_safe_title" != "無題" ]; then
        safe_title="$llm_safe_title"
      else
        log "タイトル推論失敗、ファイル名から代用: $base -> $safe_title"
      fi

      if [ -n "$llm_summary" ]; then
        summary="$llm_summary"
      else
        log "要約が空のためプレースホルダを使用: $base"
        summary="(LLMが要約を生成できませんでした)"
      fi
    fi
  else
    log "処理開始(非PDF、LLM推論スキップ): $base (sha256: ${file_hash:0:12}...)"
    summary="(PDF以外のファイルのため自動要約なし)"
  fi

  note_name="${doc_date}_${safe_title}.md"
  note_path="$NOTES_DIR/$note_name"

  # 同名ノートがあれば連番を付与
  n=2
  while [ -e "$note_path" ]; do
    note_name="${doc_date}_${safe_title}_${n}.md"
    note_path="$NOTES_DIR/$note_name"
    n=$((n+1))
  done

  # _resources での保存名をノート作成前に確定させる。embedはこの名前を使うため、
  # 実ファイル名とリンク先が食い違うことはない。
  # 同名ファイルが既にある場合(内容が違うので重複判定は通過している)に
  # 連番を付けないと、先に取り込んだ実ファイルをmvが上書きして消してしまう。
  resource_name=$(sanitize_link_target "$base")
  case "$resource_name" in
    *.*) res_stem="${resource_name%.*}"; res_suffix=".${resource_name##*.}" ;;
    *)   res_stem="$resource_name"; res_suffix="" ;;
  esac
  m=2
  while [ -e "$RESOURCES_DIR/$resource_name" ]; do
    resource_name="${res_stem}_${m}${res_suffix}"
    m=$((m+1))
  done
  [ "$resource_name" != "$base" ] && log "保存先ファイル名を変更: $base -> $resource_name"

  # 3. ノートを先に作成(一時ファイルに書いてから確定させる)
  #    ここで失敗した場合は元ファイルをまだ移動していないので、次回トリガーで
  #    自動的に再試行される(_resourcesに取り残されることを防ぐ)
  tmp_note_path="${note_path}.tmp"
  if ! { echo "---"
    echo "date: $doc_date"
    echo "source: scansnap"
    echo "---"
    echo ""
    echo "![[_resources/$resource_name]]"
    echo ""
    echo "$summary"
  } > "$tmp_note_path" 2>>"$LOG_FILE"; then
    log "ERROR: ノート書き込み失敗、元ファイルは移動せず再試行対象のままにします: $base"
    rm -f "$tmp_note_path"
    continue
  fi
  mv "$tmp_note_path" "$note_path"

  # 4. ノート作成が確定してから元ファイルを_resourcesへ移動
  #    -n と移動後の確認で、連番決定後に横から同名ファイルが現れた場合でも
  #    既存ファイルを上書きしないようにする
  if ! mv -n "$item" "$RESOURCES_DIR/$resource_name" 2>>"$LOG_FILE" || [ -e "$item" ]; then
    log "ERROR: ファイル移動に失敗、作成済みノートを削除して次回再試行します: $base -> $resource_name"
    rm -f "$note_path"
    continue
  fi

  # "ハッシュ  ファイル名" 形式で記録(ハッシュは判定用、ファイル名は目視確認用)
  echo "${file_hash}  ${base}" >> "$PROCESSED_LIST"
  log "完了: $base -> $note_name"
done
