#!/bin/zsh
# Sonuvi first-open helper, GPL-3.0. Only the official v0.4.19 build is accepted.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u

SUPPORTED_VERSION='0.4.19'
EXPECTED_SHA256='d6cbf5cf0e2ad77849caffca6bcd94ec81a0b8d05fa30a77001c1e666d256058'
DOWNLOAD_URL='https://github.com/davidai1024/Sonuvi/releases/download/v0.4.19/Sonuvi-Mac-Offline.dmg'
APP=''
CHECK_ONLY=0
NO_OPEN=0

pause_if_interactive() {
    if [[ -t 0 ]]; then
        print ''
        read -r '?按回车键结束 / Press Return to finish…' || true
    fi
}
fail() {
    print -u2 -- "未完成 / Not completed: $1"
    print -u2 -- "官方安装包 / Official download: $DOWNLOAD_URL"
    pause_if_interactive
    exit 1
}

while (( $# )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || fail '缺少应用路径 / Missing app path.'
            APP="$2"; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --no-open) NO_OPEN=1; shift ;;
        *) fail '无法识别的参数 / Unknown argument.' ;;
    esac
done

if [[ -z "$APP" ]]; then
    for candidate in '/Applications/Sonuvi.app' "$HOME/Applications/Sonuvi.app"; do
        if [[ -d "$candidate" ]]; then APP="$candidate"; break; fi
    done
fi
[[ -n "$APP" && -d "$APP" ]] || fail '请先将 Sonuvi 拖入“应用程序”，再双击本脚本。 / Install Sonuvi in Applications first.'
APP="${APP:A}"
[[ "${APP:t}" == 'Sonuvi.app' && "$APP" != /Volumes/* ]] || fail '请选择已复制到本机的 Sonuvi.app，不要直接处理安装磁盘中的应用。 / Use the installed Sonuvi.app, not the app on a disk image.'

INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/Sonuvi"
[[ -f "$INFO" && -f "$EXECUTABLE" ]] || fail '应用文件不完整，请重新下载。 / The app is incomplete; download it again.'
IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null) || fail '无法读取应用信息。 / Cannot read app information.'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null) || fail '无法读取版本。 / Cannot read app version.'
[[ "$IDENTIFIER" == 'com.wusir.musetranslate' ]] || fail '目标不是 Sonuvi。 / This is not Sonuvi.'
[[ "$VERSION" == "$SUPPORTED_VERSION" ]] || fail "本脚本适用于 v$SUPPORTED_VERSION，检测到 v$VERSION。 / This helper supports v$SUPPORTED_VERSION; found v$VERSION."

print -- "正在核对原版 Sonuvi v$VERSION… / Checking the official Sonuvi build…"
DIGEST=$(/usr/bin/shasum -a 256 "$EXECUTABLE") || fail '无法校验应用。 / Cannot verify the app.'
[[ "${DIGEST%% *}" == "$EXPECTED_SHA256" ]] || fail '应用与官方发行包不一致，请重新下载。 / The app does not match the official release; download it again.'
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail '应用完整性检查失败，请重新下载。 / App integrity check failed; download it again.'

if (( CHECK_ONLY )); then
    print -- '检查通过；未修改任何属性，也未启动应用。 / Check passed; nothing changed or launched.'
    exit 0
fi

print -- '正在清除 Sonuvi 的下载隔离标记… / Removing the download quarantine flag from Sonuvi…'
if ! /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
    # Read-only model weights can produce delete errors even without this
    # attribute. Ask for authorization only if quarantine flags remain.
    REMAINING=$(/usr/bin/xattr -r -p com.apple.quarantine "$APP" 2>/dev/null)
    if [[ -n "$REMAINING" ]]; then
    print -- '需要管理员授权以修改应用属性；请按系统提示操作。 / Administrator authorization is required to update the app attributes.'
    /usr/bin/osascript - "$APP" <<'APPLESCRIPT' || fail '未完成授权，或应用属性无法修改。 / Authorization was cancelled or app attributes could not be updated.'
on run argv
    do shell script "/usr/bin/xattr -dr com.apple.quarantine " & quoted form of (item 1 of argv) with administrator privileges
end run
APPLESCRIPT
    fi
fi
REMAINING=$(/usr/bin/xattr -r -p com.apple.quarantine "$APP" 2>/dev/null)
[[ -z "$REMAINING" ]] || fail '仍有隔离标记未能清除，请到“隐私与安全性”手动选择“仍要打开”。 / Some quarantine flags remain; use Open Anyway in Privacy & Security.'

if (( NO_OPEN )); then
    print -- '处理完成；未启动应用。 / Finished; the app was not launched.'
else
    /usr/bin/open "$APP" || fail '无法启动，请从“应用程序”再次打开 Sonuvi。 / Could not launch; open Sonuvi from Applications.'
    print -- '处理完成，已请求打开 Sonuvi。 / Finished; Sonuvi has been requested to open.'
    print -- '辅助功能和屏幕录制仍需你在系统设置中授权。 / Accessibility and Screen Recording permissions still require your approval in System Settings.'
fi
pause_if_interactive
