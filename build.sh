#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x Resources/uv ]]; then
  bash scripts/prepare-uv.sh
fi
app_dir="${MUSE_BUILD_DIR:-$PWD/build}/Sonuvi.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$PWD/build/module-cache"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/*.swift \
  -framework AVFoundation -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Carbon -framework LocalAuthentication -framework Security -framework NaturalLanguage -framework Vision -framework ServiceManagement -framework CoreText -framework Charts \
  -o "$app_dir/Contents/MacOS/Sonuvi"
cp Resources/*.py Resources/uv Resources/UV-LICENSE-* LICENSE THIRD_PARTY_NOTICES.txt "$app_dir/Contents/Resources/"
cp Resources/Brand/AppIcon.icns Resources/Brand/MenuBar*.png "$app_dir/Contents/Resources/"
cp Resources/Brand/icon_128x128@2x.png "$app_dir/Contents/Resources/BrandIcon.png"
/usr/bin/codesign --force --sign - "$app_dir/Contents/Resources/uv"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sonuvi</string>
<key>CFBundleDisplayName</key><string>Sonuvi</string>
<key>CFBundleIdentifier</key><string>com.wusir.musetranslate</string>
<key>CFBundleExecutable</key><string>Sonuvi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSServices</key><array>
<dict><key>NSMenuItem</key><dict><key>default</key><string>用 Sonuvi 翻译</string></dict>
<key>NSMessage</key><string>translateService</string><key>NSPortName</key><string>Sonuvi</string>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
<key>NSRequiredContext</key><dict/></dict>
<dict><key>NSMenuItem</key><dict><key>default</key><string>用 Sonuvi 朗读</string></dict>
<key>NSMessage</key><string>readService</string><key>NSPortName</key><string>Sonuvi</string>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
<key>NSRequiredContext</key><dict/></dict>
</array>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>读取你主动选中的文字，用于中英翻译和本地英文朗读。</string>
<key>NSScreenCaptureUsageDescription</key><string>仅在你使用截图翻译时截取所选区域，在本机识别文字。</string>
</dict></plist>
PLIST
# Reuse an existing code-signing identity across updates when supplied.
# Never broaden designated requirements or change the system trust store.
/usr/bin/codesign --force --sign "${MUSE_SIGNING_IDENTITY:--}" "$app_dir"
"$app_dir/Contents/MacOS/Sonuvi" --self-test
printf '\n构建完成：%s\n' "$app_dir"
