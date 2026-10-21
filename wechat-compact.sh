#!/bin/bash
# 回收 sparsebundle 中已删除数据占用的空间。
# sparsebundle 只增不减，在微信里删聊天记录不会把空间还给 SSD，要靠这一步。
set -euo pipefail

CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请创建 $CONF 并写入 WECHAT_IMAGE=/Volumes/你的盘名/WeChatData.sparsebundle}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
MOUNT_SCRIPT="${WECHAT_MOUNT_SCRIPT:-$HOME/bin/wechat-mount.sh}"

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请 Cmd+Q 完全退出后重试。"; exit 1; }
[ -d "$IMG" ] || { echo "找不到镜像：${IMG}（SSD 没插？）"; exit 1; }

echo "压缩前: $(du -sh "$IMG" | cut -f1)"

if mount | grep -qF " on ${MNT} ("; then
  echo "卸载镜像..."
  hdiutil detach "$MNT" >/dev/null
fi

echo "压缩中，几分钟，中途别拔盘别 Ctrl-C..."
hdiutil compact "$IMG"

echo "压缩后: $(du -sh "$IMG" | cut -f1)"

echo "重新挂载..."
bash "$MOUNT_SCRIPT" >/dev/null 2>&1 || true
if mount | grep -qF " on ${MNT} ("; then
  echo "完成，微信可以打开了。"
else
  echo "警告：重新挂载失败，手动跑  bash $MOUNT_SCRIPT"
  exit 1
fi
