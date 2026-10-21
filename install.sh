#!/bin/bash
# 安装 wechat-to-ssd：创建镜像、写配置、装脚本、装 LaunchAgent。
# 不迁移数据 —— 装完再单独跑 ./wechat-migrate.sh。
#
# 用法：./install.sh /Volumes/你的SSD [镜像上限]
#   例：./install.sh /Volumes/MySSD 500g
set -euo pipefail

VOL="${1:-}"
VOL="${VOL%/}"          # Tab 补全会带上结尾的 /
SIZE="${2:-500g}"

if [ -z "$VOL" ]; then
  echo "用法: $0 /Volumes/你的SSD [镜像上限，默认 500g]"
  echo
  echo "当前已挂载的卷："
  ls -1 /Volumes
  exit 1
fi

[ -d "$VOL" ] || { echo "找不到卷：$VOL"; exit 1; }

FS="$(mount | sed -n "s|^.* on ${VOL} (\([^,)]*\).*|\1|p" | head -1)"
case "$FS" in
  apfs|hfs) ;;
  "") echo "警告：无法判断 $VOL 的文件系统类型，请自行确认是 APFS 或 HFS+。" ;;
  *)  echo "注意：$VOL 是 ${FS}。sparsebundle 内层是独立的 APFS 卷，所以 exFAT 外壳也能用，"
      echo "      但拔盘风险更高，务必遵守「拔盘前先退微信」。" ;;
esac

# 传成了内置盘上的目录就白搬了
disk_of() { df "$1" | awk 'NR == 2 { print $1 }' | sed -n 's|^/dev/\(disk[0-9]*\).*|\1|p'; }
if [ -n "$(disk_of "$VOL")" ] && [ "$(disk_of "$VOL")" = "$(disk_of "$HOME")" ]; then
  echo "警告：${VOL} 和主目录在同一块盘上，搬过去省不了内置盘空间。"
fi

CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
IMG="$VOL/WeChatData.sparsebundle"
BIN="$HOME/bin"
LOG="$HOME/Library/Logs/wechatmount.log"
PLIST="$HOME/Library/LaunchAgents/com.local.wechatmount.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "镜像:   $IMG"
echo "配置:   $CONF"
echo "脚本:   $BIN/"
echo "Agent:  $PLIST"
echo
read -r -p "继续？输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已中止。"; exit 1; }

# 1. 镜像
if [ -d "$IMG" ]; then
  echo "镜像已存在，跳过创建。"
else
  echo "创建镜像（上限 ${SIZE}，稀疏按需增长，不会立刻占满）..."
  hdiutil create -size "$SIZE" -type SPARSEBUNDLE -fs APFS -volname WeChatData "$IMG"
fi

# 2. 配置（重跑时只换镜像路径，用户改过的其他项保留）
mkdir -p "$(dirname "$CONF")"
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# wechat-to-ssd 配置
WECHAT_IMAGE="$IMG"
# WECHAT_MOUNT="\$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
# WECHAT_WAIT_SECONDS=180
EOF
  echo "已写入 ${CONF}"
elif grep -qxF "WECHAT_IMAGE=\"$IMG\"" "$CONF"; then
  echo "配置已存在，保持不变：${CONF}"
else
  { grep -v '^WECHAT_IMAGE=' "$CONF" || true; echo "WECHAT_IMAGE=\"$IMG\""; } > "${CONF}.new"
  mv "${CONF}.new" "$CONF"
  echo "已更新 ${CONF} 里的 WECHAT_IMAGE，其他配置保留"
fi

# 3. 脚本
mkdir -p "$BIN"
install -m 755 "$HERE/wechat-mount.sh" "$BIN/wechat-mount.sh"
install -m 755 "$HERE/wechat-compact.sh" "$BIN/wechat-compact.sh"
echo "已安装 $BIN/wechat-mount.sh 和 $BIN/wechat-compact.sh"

# 4. LaunchAgent
DOMAIN="gui/$(id -u)"
LABEL="com.local.wechatmount"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
sed -e "s|__SHELL__|/bin/bash|" \
    -e "s|__MOUNT_SCRIPT__|$BIN/wechat-mount.sh|" \
    -e "s|__LOG__|$LOG|" \
    "$HERE/com.local.wechatmount.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# 已加载的先卸掉，等它真的消失再加载：紧接着 bootstrap 偶尔会报 Input/output error
if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${DOMAIN}/${LABEL}" || true
  for _ in 1 2 3 4 5; do
    launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || break
    sleep 1
  done
fi
if err="$(launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1)"; then
  echo "已加载 LaunchAgent（日志 ${LOG}）"
else
  echo "LaunchAgent 已写入，但现在没能加载：${err}"
  echo "（通过 SSH 跑、没有图形登录会话时会这样。下次登录时会自动加载。）"
fi

cat <<EOF

────────────────────────────────────────────────────────────
装完了。还有两件事必须你手动做：

1. 给 /bin/bash 完全磁盘访问权限
   系统设置 → 隐私与安全性 → 完全磁盘访问权限 → +
   → 在文件选择器里按 Cmd+Shift+G，输入 /bin/bash → 添加并打开

   不做这步，开机自动挂载会报 Permission denied。原因见 README。

2. 迁移数据（在有完全磁盘访问权限的「终端」App 里，先 Cmd+Q 退微信）
   bash "$HERE/wechat-migrate.sh"
────────────────────────────────────────────────────────────
EOF
