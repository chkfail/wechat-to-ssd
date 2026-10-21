#!/bin/bash
# 冒烟测试：临时 HOME + 临时 sparsebundle，在真实 macOS 上走一遍
# install → migrate → mount → compact → restore。
#
# 会注册和注销 com.local.wechatmount 这个 LaunchAgent，在本机跑会影响真实安装，所以只在 CI 里跑。
set -euo pipefail
[ -n "${CI:-}" ] || { echo "只在 CI 里跑：会动 com.local.wechatmount 这个 LaunchAgent。"; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
export HOME="${WORK}/home"
unset WECHAT_TO_SSD_CONF WECHAT_IMAGE WECHAT_MOUNT WECHAT_MOUNT_SCRIPT
VOL="${WORK}/ssd"
IMG="${VOL}/WeChatData.sparsebundle"
CONF="${HOME}/.config/wechat-to-ssd.conf"
PLIST="${HOME}/Library/LaunchAgents/com.local.wechatmount.plist"
SERVICE="gui/$(id -u)/com.local.wechatmount"
D="${HOME}/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
ORIG="${WORK}/orig"
EXCL=(-x .fseventsd -x .Spotlight-V100 -x .Trashes -x .TemporaryItems -x .DocumentRevisions-V100)

trap 'echo "== wechatmount.log =="; cat "${HOME}/Library/Logs/wechatmount.log" 2>/dev/null || true' EXIT

# t <期望退出码> <说明> <标准输入> <命令...>
t() {
  local want="$1" what="$2" input="$3" got=0
  shift 3
  echo
  echo "======== ${what}"
  "$@" <<< "$input" || got=$?
  [ "$got" = "$want" ] || { echo "FAIL ${what}：退出码 ${got}，期望 ${want}"; exit 1; }
}
# check <说明> <命令...>
check() {
  local what="$1"
  shift
  "$@" || { echo "FAIL ${what}"; exit 1; }
  echo "ok   ${what}"
}
not() { ! "$@"; }
mounted() { mount | grep -qF " on ${D} ("; }
loaded() { launchctl print "$SERVICE" >/dev/null 2>&1; }
uchg() { stat -f %Sf "$D" | grep -qw uchg; }

# --- 假的微信数据 ---------------------------------------------------------
mkdir -p "${VOL}" "${D}/wxid_abc/db_storage/message" "${D}/wxid_abc/msg/file" "${D}/all_users/config"
echo db > "${D}/wxid_abc/db_storage/message/message_0.db"
echo wal > "${D}/wxid_abc/db_storage/message/message_0.db-wal"
head -c 3000000 /dev/urandom > "${D}/wxid_abc/msg/file/a b.bin"
echo cfg > "${D}/all_users/config/global.ini"
echo h > "${D}/.hidden"
ln -s wxid_abc "${D}/link_top"
ln -s ../db_storage "${D}/wxid_abc/msg/link_inner"

# --- install --------------------------------------------------------------
t 0 "install（卷路径带结尾 /）" yes /bin/bash "${REPO}/install.sh" "${VOL}/" 1g
check "配置里的镜像路径没有 //" grep -qxF "WECHAT_IMAGE=\"${IMG}\"" "$CONF"
check "镜像已创建" test -d "$IMG"
check "日志在 ~/Library/Logs" grep -qF "${HOME}/Library/Logs/wechatmount.log" "$PLIST"
check "LaunchAgent 已加载" loaded

echo "WECHAT_WAIT_SECONDS=5" >> "$CONF"
t 0 "重跑 install（bootout 后再 bootstrap）" yes /bin/bash "${REPO}/install.sh" "$VOL" 1g
check "重跑后用户配置还在" grep -qx "WECHAT_WAIT_SECONDS=5" "$CONF"
check "重跑后 WECHAT_IMAGE 只有一行" test "$(grep -c '^WECHAT_IMAGE=' "$CONF")" = 1
check "重跑后 LaunchAgent 仍已加载" loaded

# --- migrate --------------------------------------------------------------
t 1 "迁移前 mount.sh 拒绝挂到有数据的目录上" "" /bin/bash "${HOME}/bin/wechat-mount.sh"
check "迁移前没挂上" not mounted

t 1 "迁移在第二道 yes 处中止" $'yes\nno' /bin/bash "${REPO}/wechat-migrate.sh"
check "中止后原目录没动" not test -e "${D}.bak"

rm "${D}/wxid_abc/db_storage/message/message_0.db-wal"     # 模拟微信 checkpoint 后删掉 -wal
cp -Rp "$D" "$ORIG"
t 0 "重跑迁移：先清空镜像里的旧副本" $'yes\nyes\nyes' /bin/bash "${REPO}/wechat-migrate.sh"
check "迁移后已挂上" mounted
check "备份在" test -d "${D}.bak"
check "镜像里没有残留的旧 -wal" not test -e "${D}/wxid_abc/db_storage/message/message_0.db-wal"
check "镜像内容和原数据一致" diff -r "${EXCL[@]}" "$ORIG" "$D"

t 1 "已挂载时重跑迁移被拒绝" $'yes\nyes' /bin/bash "${REPO}/wechat-migrate.sh"
t 0 "已挂载时 mount.sh 幂等" "" /bin/bash "${HOME}/bin/wechat-mount.sh"

# --- 拔盘 / 重挂 ----------------------------------------------------------
hdiutil detach "$D"
check "挂载点带 uchg" uchg
t 1 "未挂载的 uchg 挂载点上重跑迁移被拒绝" yes /bin/bash "${REPO}/wechat-migrate.sh"
t 0 "卸载后 mount.sh 重新挂上" "" /bin/bash "${HOME}/bin/wechat-mount.sh"
check "重新挂上了" mounted

hdiutil detach "$D"
mkdir -p "${WORK}/elsewhere"
hdiutil attach "$IMG" -mountpoint "${WORK}/elsewhere" -nobrowse -owners on
t 1 "镜像挂在别处时 mount.sh 不报成功" "" /bin/bash "${HOME}/bin/wechat-mount.sh"
check "没挂到挂载点上" not mounted
hdiutil detach "${WORK}/elsewhere"
t 0 "镜像放回来后 mount.sh 挂上" "" /bin/bash "${HOME}/bin/wechat-mount.sh"

# --- compact --------------------------------------------------------------
t 0 "compact" "" /bin/bash "${HOME}/bin/wechat-compact.sh"
check "compact 后重新挂上" mounted

# --- restore --------------------------------------------------------------
t 0 "回退" $'yes\nyes' /bin/bash "${REPO}/wechat-restore.sh"
check "回退后不再挂载" not mounted
check "回退后数据和原来一致（没有卷元数据）" diff -r "$ORIG" "$D"
check "回退后挂载点没有 uchg" not uchg
check "plist 已删" not test -e "$PLIST"
check "LaunchAgent 已注销" not loaded
t 1 "回退后 mount.sh 拒绝" "" /bin/bash "${HOME}/bin/wechat-mount.sh"
t 1 "回退后重跑回退被拒绝" "" /bin/bash "${REPO}/wechat-restore.sh"

echo
echo "全部通过"
