#!/bin/bash
# release ビルドして build/WinSCP Mac.app を作る
#   ./scripts/bundle.sh             … この Mac 用 (開発用。速い)
#   ./scripts/bundle.sh --universal … Apple Silicon と Intel の両対応
#   ./scripts/bundle.sh --dmg       … 両対応でビルドし、配布用のインストーラー (DMG) を作って公証まで行う
#                                     DMG にはアプリとアプリケーションフォルダへのリンクが入る
#                                     (アンインストールはインストール後のアプリのメニューから)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="${BUNDLE_ID:-net.satoru.winscpmac}"
NAME="WinSCP Mac"

UNIVERSAL=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --dmg) UNIVERSAL=1; DMG=1 ;;
        *) echo "知らないオプション: $arg" >&2; exit 1 ;;
    esac
done

if [ "$UNIVERSAL" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINDIR=".build/apple/Products/Release"
else
    swift build -c release
    BINDIR=".build/release"
fi

# Info.plist を書く: plist <出力> <実行ファイル名> <バンドル ID> <表示名> <アイコン名> <追加の XML>
plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleName</key><string>$4</string>
    <key>CFBundleDisplayName</key><string>$4</string>
    <key>CFBundleIconFile</key><string>$5</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 satorunet. GPL v3. https://github.com/satorunet/winscp_mac</string>
$6
</dict>
</plist>
PLIST
}

APP="build/${NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/WinSCPMac" "$APP/Contents/MacOS/WinSCPMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# WinSCP の画面定義 (.dfm) と日本語訳 (JP.ini)。画面はこれから組み立てる
mkdir -p "$APP/Contents/Resources/winscp"
cp ../source/forms/*.dfm ../translations/JP.ini "$APP/Contents/Resources/winscp/"
# ライセンス (GPL v3。アイコンは WinSCP のもの)
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
plist "$APP/Contents/Info.plist" WinSCPMac "$BUNDLE_ID" "$NAME" AppIcon '    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>WinSCP の設定</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleTypeExtensions</key><array><string>ini</string><string>reg</string></array>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>'

# 署名: 「Developer ID Application」の証明書があればそれで (なければ ad-hoc)
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
for A in "$APP"; do
    if [ -n "$SIGN_ID" ]; then
        codesign --force --options runtime --timestamp -s "$SIGN_ID" "$A"
        codesign --verify --strict "$A"
    else
        codesign --force --deep -s - "$A" >/dev/null 2>&1 || true
    fi
done
echo "signed: ${SIGN_ID:-ad-hoc}"
echo "built: $(pwd)/$APP"
lipo -archs "$APP/Contents/MacOS/WinSCPMac" | sed 's/^/arch: /'

if [ "$DMG" = 1 ]; then
    STAGE="build/dmg"
    VOL="${NAME} ${VERSION}"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/.background"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    BG="build/dmg-bg"
    mkdir -p "$BG"
    swift scripts/make_dmg_bg.swift "$BG/bg.png" 1 >/dev/null
    swift scripts/make_dmg_bg.swift "$BG/bg@2x.png" 2 >/dev/null
    tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null 2>&1
    rm -rf "$BG"

    OUT="build/WinSCPMac-${VERSION}.dmg"
    RW="build/dmg-rw.dmg"
    rm -f "$OUT" "$RW"
    [ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
    rm -rf "$STAGE"
    DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
    sleep 2
    # Finder に窓の大きさ・背景・アイコンの位置を覚えさせる (.DS_Store に残る)
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 542}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:bg.tiff"
        set position of item "${NAME}.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    sync
    rm -rf "/Volumes/$VOL/.fseventsd" 2>/dev/null || true
    hdiutil detach "$DEV" >/dev/null
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
    rm -f "$RW"
    if [ -n "$SIGN_ID" ]; then
        codesign --force --timestamp -s "$SIGN_ID" "$OUT"
        PROFILE="${NOTARY_PROFILE:-satoru-notary}"
        if [ "${SKIP_NOTARY:-0}" = 1 ]; then
            echo "公証はとばしました (SKIP_NOTARY=1)"
        elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
            xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
            xcrun stapler staple "$OUT"
            spctl -a -t open --context context:primary-signature -v "$OUT" && echo "notarized: OK"
        else
            echo "公証はとばしました (notarytool の保存済み資格情報 '$PROFILE' がない)"
        fi
    fi
    echo "dmg: $(pwd)/$OUT"
fi
