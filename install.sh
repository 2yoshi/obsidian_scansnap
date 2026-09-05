#!/bin/bash
###############################################################################
# install.sh
#
# スクリプトを ~/bin へ、plist を ~/Library/LaunchAgents へ配置して
# launchd に登録する。plist は launchd が ~ や $HOME を展開しないため、
# テンプレートの __HOME__ / __INCOMING_DIR__ をここで実パスに置換する。
#
# 監視対象を既定(~/syncthing/notes/001_scanbox/_incoming)から変えたい場合:
#   VAULT_DIR=~/Documents/vault ./install.sh
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAULT_DIR="${VAULT_DIR:-$HOME/syncthing/notes}"
INCOMING_DIR="${INCOMING_DIR:-$VAULT_DIR/001_scanbox/_incoming}"

LABEL="com.user.scansnap-obsidian-local"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DEST="$HOME/bin/scan_to_obsidian_local_v2.sh"

# WatchPaths は監視対象が存在しないと登録できない
mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents" "$INCOMING_DIR"

/bin/cp -f "$SCRIPT_DIR/scan_to_obsidian_local_v2.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

sed -e "s#__HOME__#${HOME}#g" -e "s#__INCOMING_DIR__#${INCOMING_DIR}#g" \
  "$SCRIPT_DIR/$LABEL.plist.template" > "$PLIST_DEST"

plutil -lint "$PLIST_DEST" >/dev/null

launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "インストール完了"
echo "  スクリプト: $SCRIPT_DEST"
echo "  plist:      $PLIST_DEST"
echo "  監視対象:   $INCOMING_DIR"
echo ""
echo "状態確認: launchctl print gui/\$(id -u)/$LABEL"
