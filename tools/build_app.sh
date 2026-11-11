#!/bin/zsh
# Builds Macarum.app (release), signs it, installs it to ~/Applications and restarts it.
# Runs at low priority with one job so the Mac stays responsive.
#   tools/build_app.sh            build, install, relaunch
#   tools/build_app.sh --no-run   build and install only
#   tools/build_app.sh --bundle   build and sign build/Macarum.app only (used by build_dmg.sh)
#   tools/build_app.sh --no-install   build and sign build/Macarum.app for this Mac only;
#                                     the installed copy keeps running untouched
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.4.1"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Macarum.app"
INSTALL_DIR="$HOME/Applications"

# A stable signing identity keeps macOS permissions (Accessibility, clipboard access)
# across rebuilds; an ad-hoc signature would reset them every time.
# Without any certificate the app is signed ad hoc: it runs, but macOS asks for the
# permissions again after every build.
IDENTITY="${MACARUM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { IDENTITY="-"; echo "No Apple Development certificate: signing ad hoc" >&2; }

# Universal (Apple silicon and Intel) only for builds that leave this Mac; local ones stay fast.
ARCHS=()
[[ "${1:-}" == "--bundle" ]] && ARCHS=(--arch arm64 --arch x86_64)
nice -n 19 swift build -c release -j 1 --product Macarum "${ARCHS[@]}"
BIN="$(swift build -c release --show-bin-path "${ARCHS[@]}")/Macarum"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macarum"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>id.hundredengine.macarum</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Macarum</string>
    <key>CFBundleDisplayName</key><string>Macarum</string>
    <key>CFBundleExecutable</key><string>Macarum</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Convert with Macarum</string></dict>
            <key>NSMessage</key><string>convertFiles</string>
            <key>NSPortName</key><string>Macarum</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.image</string><string>com.adobe.pdf</string><string>public.movie</string><string>public.audio</string><string>org.openxmlformats.wordprocessingml.document</string><string>com.microsoft.word.doc</string><string>public.rtf</string><string>public.html</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Notarization needs a secure timestamp; local development builds skip it (no network).
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == *"Developer ID"* ]] && TIMESTAMP="--timestamp"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
[[ "${1:-}" == "--bundle" || "${1:-}" == "--no-install" ]] && { echo "Built $APP ($VERSION build $BUILD_NUMBER)"; exit 0; }

pkill -x Macarum 2>/dev/null && sleep 0.5 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Macarum.app"
cp -R "$APP" "$INSTALL_DIR/Macarum.app"
echo "Installed $INSTALL_DIR/Macarum.app ($VERSION build $BUILD_NUMBER)"

[[ "${1:-}" == "--no-run" ]] || open "$INSTALL_DIR/Macarum.app"
