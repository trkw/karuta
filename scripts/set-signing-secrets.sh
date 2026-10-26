#!/bin/bash
# 署名と公証の鍵を GitHub Actions の Secrets に入れる（docs/signing.md の 4）。手元の Mac で gh にログインして動かす。
# 使い方: scripts/set-signing-secrets.sh <developer-id.p12> <AuthKey_XXXXXXXXXX.p8> [owner/repo]
# パスワードと ID は画面に出さずに尋ねる。値はこの Mac から GitHub に直接送り、ほかには残さない
set -euo pipefail

p12=${1:-}
p8=${2:-}
repo=${3:-trkw/karuta}
[[ -f "$p12" && -f "$p8" ]] || { echo "使い方: $0 <developer-id.p12> <AuthKey_XXXXXXXXXX.p8> [owner/repo]" >&2; exit 1; }
command -v gh > /dev/null || { echo "gh が無い: brew install gh してから gh auth login" >&2; exit 1; }
gh auth status > /dev/null 2>&1 || { echo "gh にログインしていない: gh auth login" >&2; exit 1; }

read -r -s -p ".p12 のパスワード: " password
echo
# ファイル名の AuthKey_<キー ID>.p8 からキー ID を取る。取れたら画面には出さない
key_id=$(basename "$p8" .p8)
if [[ "$key_id" =~ ^AuthKey_([A-Z0-9]+)$ ]]; then
    key_id=${BASH_REMATCH[1]}
    echo "キー ID はファイル名から取った"
else
    read -r -s -p "キー ID: " key_id
    echo
fi
read -r -s -p "Issuer ID: " issuer
echo
[[ -n "$key_id" && -n "$issuer" ]] || { echo "キー ID と Issuer ID が要る" >&2; exit 1; }

base64 -i "$p12" | gh secret set APPLE_DEVELOPER_ID_P12 -R "$repo"
printf '%s' "$password" | gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD -R "$repo"
gh secret set APPLE_NOTARY_KEY -R "$repo" < "$p8"
printf '%s' "$key_id" | gh secret set APPLE_NOTARY_KEY_ID -R "$repo"
printf '%s' "$issuer" | gh secret set APPLE_NOTARY_ISSUER_ID -R "$repo"
gh secret list -R "$repo"
echo "== 入れた。.p12 と .p8 はパスワード管理などに移し、デスクトップやダウンロードからは消す"
