#!/bin/bash
###############################################################################
# run_test.sh
#
# scan_to_obsidian_local_v2.sh を本番パス(~/syncthing/notes など)に一切
# 触れずに、test/ 配下のディレクトリだけを対象に実行するためのラッパー。
#
# 使い方:
#   test/vault/001_scanbox/_incoming/ にテスト用ファイルを置いてから実行
#   ./test/run_test.sh
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$SCRIPT_DIR"

export VAULT_DIR="$TEST_ROOT/vault"
export LOG_FILE="$TEST_ROOT/logs/scan_to_obsidian.log"
export PROCESSED_LIST="$TEST_ROOT/logs/.scan_to_obsidian_processed"

# vault/ と logs/ は .gitignore 対象で clone 直後には存在しないため、
# 本体が触る前にここで作る(本体は _incoming とログ用ディレクトリを作らない)
mkdir -p "$TEST_ROOT/logs" "$VAULT_DIR/001_scanbox/_incoming"

bash "$SCRIPT_DIR/../scan_to_obsidian_local_v2.sh"
