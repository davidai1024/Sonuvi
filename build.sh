#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="${MUSE_BUILD_DIR:-$PWD/build}/Sonuvi.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$PWD/build/module-cache"
signing_profile="${SONUVI_SIGNING_PROFILE:-}"
if [[ -z "$signing_profile" && "${SONUVI_PREVIEW:-0}" != "1" && -f "$PWD/.release-local.json" ]]; then
  signing_profile="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("signing_profile", ""))' "$PWD/.release-local.json")"
fi
if [[ -n "$signing_profile" && ! -f "$signing_profile" ]]; then
  printf 'Configured fixed signing profile is missing; refusing to change signing identity.\n' >&2
  exit 1
fi
if [[ "${SONUVI_REQUIRE_FIXED_SIGNING:-0}" == "1" && -z "$signing_profile" ]]; then
  printf 'Fixed signing profile is required; refusing ad-hoc release signing.\n' >&2
  exit 1
fi
sign_code() {
  if [[ -n "$signing_profile" ]]; then
    /usr/bin/python3 "$PWD/Tools/sign_code.py" --profile "$signing_profile" "$1"
  else
    /usr/bin/codesign --force --sign "${MUSE_SIGNING_IDENTITY:--}" "$1"
  fi
}
/usr/bin/swiftc -j 4 -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/*.swift \
  -framework AVFoundation -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Carbon -framework LocalAuthentication -framework Security -framework NaturalLanguage -framework Vision -framework ServiceManagement -framework CoreText -framework Charts -framework ScreenCaptureKit \
  -o "$app_dir/Contents/MacOS/Sonuvi"
cp Resources/VoiceCatalog.json Resources/VoicePublicKey.txt "$app_dir/Contents/Resources/"
cp Resources/English.json "$app_dir/Contents/Resources/"
cp Resources/*.py Resources/uv Resources/UV-LICENSE-* LICENSE THIRD_PARTY_NOTICES.txt "$app_dir/Contents/Resources/"
cp Resources/Brand/AppIcon.icns Resources/Brand/MenuBar*.png "$app_dir/Contents/Resources/"
cp Resources/Brand/icon_128x128@2x.png "$app_dir/Contents/Resources/BrandIcon.png"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" Tools/Relaunch.swift -framework AppKit -o "$app_dir/Contents/MacOS/SonuviRelaunch"
sign_code "$app_dir/Contents/MacOS/SonuviRelaunch"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" Sources/TextLimits.swift Sources/BrowserProtocol.swift Tools/BrowserBridge.swift -framework AppKit -framework CoreFoundation -o "$app_dir/Contents/MacOS/SonuviBrowserBridge"
sign_code "$app_dir/Contents/MacOS/SonuviBrowserBridge"
/bin/cp -R BrowserExtension "$app_dir/Contents/Resources/"
# New build directories avoid mutating a previously signed payload.
if [[ -d "$app_dir/Contents/Resources/BundledVoice" ]]; then
  printf 'Build directory already contains BundledVoice; choose a fresh MUSE_BUILD_DIR.\n' >&2
  exit 1
fi
if [[ -n "${SONUVI_BUNDLED_VOICE:-}" ]]; then
  /bin/cp -cR "$SONUVI_BUNDLED_VOICE" "$app_dir/Contents/Resources/BundledVoice"
fi
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
<key>CFBundleShortVersionString</key><string>0.4.29</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
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
if [[ -n "${SONUVI_BUNDLED_VOICE:-}" ]]; then
  /usr/bin/python3 Resources/runtime_compat.py "$app_dir" --minimum 14.0
  /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SonuviIncludesVoice bool true' "$app_dir/Contents/Info.plist"
fi
if [[ -z "${SONUVI_BUNDLED_VOICE:-}" ]]; then
  /usr/libexec/PlistBuddy -c 'Add :SonuviIncludesVoice bool false' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SonuviVoiceDelivery string download' "$app_dir/Contents/Info.plist"
fi
# Preview fixtures must not publish Services or claim the production identity.
if [[ "${SONUVI_PREVIEW:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Delete :NSServices' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.wusir.sonuvi.preview' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :MusePreview bool true' "$app_dir/Contents/Info.plist"
fi
# Reuse an existing code-signing identity across updates when supplied.
# Never broaden designated requirements or change the system trust store.
sign_code "$app_dir"
"$app_dir/Contents/MacOS/Sonuvi" --self-test
printf '\n构建完成：%s\n' "$app_dir"
