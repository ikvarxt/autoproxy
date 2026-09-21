#!/usr/bin/env bash
# 一把梭：测试 → 构建 → 装进 /Applications → 起起来。
set -euo pipefail

APP_NAME="AutoProxy"
BUNDLE_ID="me.ikvarxt.autoproxy"
DEST="/Applications"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

login_item=0
run_tests=1

usage() {
    cat <<USAGE
用法: scripts/deploy.sh [选项]

  --login        顺便设为登录启动（写 LaunchAgent）
  --no-login     取消登录启动
  --skip-tests   跳过单元测试
  -h, --help     显示这段说明
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --login) login_item=1 ;;
        --no-login) login_item=-1 ;;
        --skip-tests) run_tests=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

command -v swift >/dev/null || fail "找不到 swift，先装 Xcode 命令行工具：xcode-select --install"
[[ -w "$DEST" ]] || fail "$DEST 不可写，当前用户装不了"

if [[ $run_tests -eq 1 ]]; then
    step "跑测试"
    swift test --package-path "$REPO" >/dev/null || fail "测试没过，没装"
fi

step "构建 release 并签名"
make -C "$REPO" app >/dev/null || fail "构建失败"
BUILT="$REPO/build/$APP_NAME.app"
codesign --verify --deep "$BUILT" 2>/dev/null || fail "签名校验没过"

# 用 SIGTERM 而不是优雅退出：优雅退出会顺手清掉手机代理，
# 等于每次部署都把正在进行的代理给停了。直接杀掉，隧道和代理原样留着，
# 新实例起来探测到什么就接着管什么。
if pgrep -x "$APP_NAME" >/dev/null; then
    step "停掉在跑的实例（保留手机上的链路）"
    pkill -x "$APP_NAME" || true
    for _ in $(seq 20); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
fi

step "安装到 $DEST"
rm -rf "${DEST:?}/$APP_NAME.app"
cp -R "$BUILT" "$DEST/"
INSTALLED="$DEST/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")"

if [[ $login_item -eq 1 ]]; then
    step "设为登录启动"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED/Contents/MacOS/$APP_NAME</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST_EOF
    launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$PLIST"
elif [[ $login_item -eq -1 ]]; then
    step "取消登录启动"
    launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
    rm -f "$PLIST"
    open "$INSTALLED"
else
    open "$INSTALLED"
fi

for _ in $(seq 30); do pgrep -x "$APP_NAME" >/dev/null && break; sleep 0.1; done
pgrep -x "$APP_NAME" >/dev/null || fail "装好了但没起来，手动 open $INSTALLED 看看"

printf '\033[1;32m✓\033[0m %s\n' "$APP_NAME $VERSION 已就位：$INSTALLED"
[[ -f "$PLIST" ]] && printf '  登录启动：已开启\n' || printf '  登录启动：未开启（加 --login 打开）\n'
