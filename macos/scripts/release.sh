#!/bin/bash
# 新しい版を GitHub の Releases に公開する (アプリの「更新を確認」はここを見る)
#   ./scripts/release.sh 0.2.0 "更新点 (改行は \n)"
#   1. bundle.sh の VERSION / BUILD_NUMBER を上げる
#   2. 公証済みの DMG を作る (bundle.sh --dmg)
#   3. コミットして push、タグ v<版> の Release を作り、DMG を付ける
#   4. 公開された DMG の sha256 が手元と同じか確かめる
# GitHub のトークンは ~/git に置いたものを使う (表示しない)
set -euo pipefail
cd "$(dirname "$0")/.."

VER="${1:?版を指定してください (例 0.2.0)}"
NOTES="${2:-}"
REPO="satorunet/winscp_mac"
TOKEN="$(tr -d ' \r\n' < "$HOME/git")"
API="https://api.github.com/repos/$REPO"
auth=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")

# 1. 版を上げる
OLD_BUILD=$(sed -n 's/^BUILD_NUMBER="\([0-9]*\)"/\1/p' scripts/bundle.sh)
sed -i '' "s/^VERSION=\".*\"/VERSION=\"$VER\"/; s/^BUILD_NUMBER=\".*\"/BUILD_NUMBER=\"$((OLD_BUILD + 1))\"/" scripts/bundle.sh

# 2. DMG
./scripts/bundle.sh --dmg
DMG="build/WinSCPMac-$VER.dmg"
[ -f "$DMG" ] || { echo "DMG がありません: $DMG" >&2; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# 3. コミット・push・Release
git add scripts/bundle.sh
git commit -q -m "WinSCP Mac $VER

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" || true
git -c http.https://github.com/.extraheader="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64)" push -q origin HEAD:master

BODY=$(python3 -c 'import json,sys; print(json.dumps({"tag_name": "v"+sys.argv[1], "target_commitish": "master", "name": "WinSCP Mac "+sys.argv[1], "body": sys.argv[2].replace("\\n", "\n")}))' "$VER" "$NOTES")
REL=$(curl -sS "${auth[@]}" -X POST "$API/releases" -d "$BODY")
UPLOAD=$(printf '%s' "$REL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')
curl -sS "${auth[@]}" -H "Content-Type: application/x-apple-diskimage" --data-binary @"$DMG" \
    "$UPLOAD?name=WinSCPMac-$VER.dmg" > /dev/null

# 4. 確認
sleep 3
PUB=$(curl -sSL "https://github.com/$REPO/releases/download/v$VER/WinSCPMac-$VER.dmg" | shasum -a 256 | cut -d' ' -f1)
if [ "$PUB" = "$SHA" ]; then echo "released v$VER (sha256 $SHA)"; else echo "公開された DMG が手元と違います" >&2; exit 1; fi
