#!/bin/bash
# 回退：把镜像里的数据拷回内置盘，换回普通目录，并移除 LaunchAgent。
# 镜像本身不删 —— 确认微信正常后自己删。
#
# 破坏性操作前有两道 yes 确认，任何一步不满意都可以中止，镜像照常挂着。
set -euo pipefail

CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请创建 $CONF 并写入 WECHAT_IMAGE=/Volumes/你的盘名/WeChatData.sparsebundle}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
PLIST="$HOME/Library/LaunchAgents/com.local.wechatmount.plist"
RESTORE="${MNT}.restore"
SRC_LIST="$(mktemp "${TMPDIR:-/tmp}/wcrestore.XXXXXX")"
DST_LIST="${SRC_LIST}.dst"
trap 'rm -f "$SRC_LIST" "$DST_LIST"' EXIT

# 卷根目录下的系统元数据，拷贝和对比时都跳过（在 cd 进卷根后的 find 里用）
PRUNE=()
for m in .fseventsd .Spotlight-V100 .Trashes .TemporaryItems .DocumentRevisions-V100; do
  PRUNE+=(-path "./${m}" -prune -o)
done
# 列出目录下所有非目录条目的「大小 相对路径」，排序后两边可直接对比
manifest() {
  (cd "$1" && find . "${PRUNE[@]}" ! -type d -exec stat -f '%z %N' {} +) | LC_ALL=C sort
}
summary() {
  awk '{ n++; s += $1 } END { printf "%d 个文件，共 %.2f GB\n", n, s / 1e9 }' "$1"
}
mounted() { mount | grep -qF " on ${MNT} ("; }

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请 Cmd+Q 完全退出后重试。"; exit 1; }
[ -e "$RESTORE" ] && { echo "${RESTORE} 已存在（上次回退没走完？）。确认不需要后删掉再重跑。"; exit 1; }

# --- 1. 确保镜像挂着 ---------------------------------------------------
if ! mounted; then
  stat -f %Sf "$MNT" 2>/dev/null | grep -qw uchg \
    || { echo "${MNT} 既没挂着镜像，也不是迁移后的挂载点，看起来没迁移过或已经回退过。"; exit 1; }
  [ -d "$IMG" ] || { echo "找不到镜像：${IMG}（SSD 没插？）"; exit 1; }
  echo "镜像没挂上，先挂载..."
  hdiutil attach "$IMG" -mountpoint "$MNT" -nobrowse -owners on >/dev/null
  mounted || { echo "镜像没能挂到 ${MNT}，可能已经挂在别处（hdiutil info 查看）。"; exit 1; }
fi

# --- 2. 拷回内置盘 -----------------------------------------------------
manifest "$MNT" > "$SRC_LIST"
need_kb="$(awk '{ s += $1 } END { printf "%d", s / 1024 }' "$SRC_LIST")"
avail_kb="$(df -k "$(dirname "$MNT")" | awk 'NR == 2 { print $4 }')"
echo "镜像里: $(summary "$SRC_LIST")"
echo "内置盘可用: $((avail_kb / 1024 / 1024)) GB"
[ "$need_kb" -lt "$avail_kb" ] || { echo "内置盘空间不够，先腾出空间再来。"; exit 1; }
echo
echo "将拷回: ${RESTORE}"
read -r -p "继续？输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已中止，未做任何修改。"; exit 1; }

echo "== 拷贝中（ditto，保留 ACL/xattr）=="
mkdir "$RESTORE"
# 逐个顶层条目拷，跳过卷元数据（有的归 root 所有，整卷 ditto 会读不了而中断）。
# 顶层的符号链接用 cp -RP 原样拷，免得被当成目录跟进去
(cd "$MNT" && find . -mindepth 1 -maxdepth 1 "${PRUNE[@]}" \
    -type l -exec cp -RP {} "${RESTORE}/{}" \; -o -exec ditto {} "${RESTORE}/{}" \;)

echo "== 校验（逐个对比文件路径和大小）=="
manifest "$RESTORE" > "$DST_LIST"
echo "镜像:   $(summary "$SRC_LIST")"
echo "内置盘: $(summary "$DST_LIST")"
if ! cmp -s "$SRC_LIST" "$DST_LIST"; then
  echo
  echo "不一致（< 只在镜像里，> 只在内置盘副本里，最多显示 20 行）："
  diff "$SRC_LIST" "$DST_LIST" | grep '^[<>]' | head -20 || true
  echo
  echo "已中止。镜像照常挂着，微信可以继续用。拷出来的副本可以删掉："
  echo "  rm -rf \"${RESTORE}\""
  exit 1
fi
echo "一致。"
echo
read -r -p "卸载镜像、移除 LaunchAgent、换回普通目录？输入 yes 继续: " ok
[ "$ok" = "yes" ] || { echo "已中止。镜像照常挂着，拷好的副本在 ${RESTORE}，不要可以删掉。"; exit 1; }

# --- 3. 换回普通目录 ---------------------------------------------------
[ -f "$PLIST" ] && { launchctl unload "$PLIST" 2>/dev/null || true; }
if ! hdiutil detach "$MNT" >/dev/null; then
  [ -f "$PLIST" ] && { launchctl load "$PLIST" 2>/dev/null || true; }
  echo "卸载失败，可能有程序还占着（Finder 窗口、终端 cd 在里面等）。"
  echo "什么都没动：镜像照常挂着，LaunchAgent 已重新加载。"
  echo "关掉占用的程序，删掉 ${RESTORE} 后重跑。"
  exit 1
fi
chflags nouchg "$MNT"
rmdir "$MNT"
mv "$RESTORE" "$MNT"
rm -f "$PLIST"

echo
echo "完成。数据已回到 ${MNT}，LaunchAgent 已移除。"
echo
echo "现在打开微信，验证聊天记录 / 历史图片能否加载 / 文件能否打开 / 搜索。"
echo "确认无误后，这些可以删掉："
echo "  rm -rf \"${IMG}\""
echo "  rm -f \"${CONF}\" ~/bin/wechat-mount.sh ~/bin/wechat-compact.sh"
