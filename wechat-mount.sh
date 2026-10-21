#!/bin/bash
# 把微信数据镜像挂载到容器内的数据目录。
# 由 LaunchAgent 在开机和插盘时调用，也可手动执行。幂等。

CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请创建 $CONF 并写入 WECHAT_IMAGE=/Volumes/你的盘名/WeChatData.sparsebundle}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
WAIT="${WECHAT_WAIT_SECONDS:-180}"

mount | grep -qF " on ${MNT} (" && exit 0

# 只往迁移后留下的空 uchg 目录上挂。目录非空说明还没迁移（或已回退），
# 这时挂上去会遮住真实数据，微信转头往镜像里写一套新的。
if ! entries="$(ls -A "$MNT" 2>&1)"; then
  echo "$(date): 读不了挂载点 ${MNT}：${entries}"
  exit 1
fi
if [ -n "$entries" ] || ! stat -f %Sf "$MNT" | grep -qw uchg; then
  echo "$(date): ${MNT} 不是迁移后留下的空挂载点（非空或没有 uchg 标志），不挂载"
  exit 1
fi

for _ in $(seq 1 "$WAIT"); do
  [ -d "$IMG" ] && break
  sleep 1
done
[ -d "$IMG" ] || { echo "$(date): 等待 ${WAIT}s 后仍未找到镜像 ${IMG}，放弃"; exit 1; }

# 以 mount 表为准，不只看 hdiutil 的退出码：镜像已挂在别处时它可能照样返回成功
hdiutil attach "$IMG" -mountpoint "$MNT" -nobrowse -owners on
if mount | grep -qF " on ${MNT} ("; then
  echo "$(date): 挂载成功"
else
  echo "$(date): 挂载失败"
  exit 1
fi
