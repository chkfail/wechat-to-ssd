#!/bin/bash
# 一次性迁移：把微信数据拷进 SSD 上的 sparsebundle，再把原目录换成挂载点。
# 只需跑一次。之后由 LaunchAgent + wechat-mount.sh 负责每次开机挂载。
# 只支持微信 4.x（数据在 Documents/xwechat_files）。
#
# 破坏性操作前有两道 yes 确认，任何一步不满意都可以中止，原数据不动。
set -euo pipefail

CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?未配置镜像路径。请先跑 ./install.sh，或手动创建 $CONF}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"

# 卷根目录下的系统元数据，对比和清空时都跳过（在 cd 进卷根后的 find 里用）
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

# --- 0. 环境诊断 -------------------------------------------------------
PARENT="$(dirname "$MNT")"
if ! ls "$PARENT" >/dev/null 2>&1; then
  err="$(ls "$PARENT" 2>&1 || true)"
  echo "无法读取微信容器目录。系统返回："
  echo "    ${err}"
  echo
  case "$err" in
    *"Operation not permitted"*)
      echo "→ 这是 TCC 权限问题，不是路径问题。"
      echo "  当前 shell 的宿主进程是："
      echo "    $(ps -o comm= -p $PPID 2>/dev/null || echo '(无法获取)')"
      echo "  需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里"
      echo "  给这个进程授权，然后完全退出它再重开。"
      echo "  建议直接用系统自带的「终端」App 跑本脚本。"
      ;;
    *"No such file"*)
      echo "→ 容器不存在。微信 4.x 可能从未在这台机器上启动过。"
      ;;
  esac
  exit 1
fi

pgrep -x WeChat >/dev/null && { echo "微信还在运行，请 Cmd+Q 完全退出后重试。"; exit 1; }
[ -d "$IMG" ] || { echo "找不到镜像：${IMG}。先跑 ./install.sh 创建它。"; exit 1; }

# --- 1. 确认数据目录 ---------------------------------------------------
if mount | grep -qF " on ${MNT} ("; then
  echo "${MNT} 已经挂着镜像，迁移早就做过了。"; exit 1
fi
if stat -f %Sf "$MNT" 2>/dev/null | grep -qw uchg; then
  echo "${MNT} 是带 uchg 的挂载点，迁移早就做过了，只是镜像没挂上。"
  echo "挂载请跑：bash ~/bin/wechat-mount.sh"
  exit 1
fi
[ -d "$MNT" ] || { echo "找不到 ${MNT}。只支持微信 4.x，3.x 请先升级。"; exit 1; }
[ -e "${MNT}.bak" ] && { echo "${MNT}.bak 已存在（上次迁移的备份？）。确认不需要后删掉再重跑。"; exit 1; }

echo "将迁移: ${MNT}  ($(du -sh "$MNT" 2>/dev/null | cut -f1))"
read -r -p "确认这个目录吗？输入 yes 继续: " ok
[ "$ok" = "yes" ] || { echo "已中止，未做任何修改。"; exit 1; }

# --- 2. 拷入镜像 -------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wcstage.XXXXXX")"
STAGE="$(cd "$STAGE" && pwd -P)"    # /var → /private/var，mount 表里记的是真实路径
SRC_LIST="${STAGE}.src"
DST_LIST="${STAGE}.dst"
hdiutil attach "$IMG" -mountpoint "$STAGE" -nobrowse -owners on >/dev/null
staged() { mount | grep -qF " on ${STAGE} ("; }
trap 'staged && hdiutil detach "$STAGE" >/dev/null 2>&1; rm -f "$SRC_LIST" "$DST_LIST"; rmdir "$STAGE" 2>/dev/null || true' EXIT
staged || { echo "镜像没挂到 ${STAGE}，可能已经挂在别处（hdiutil info 查看）。卸载后重跑。"; exit 1; }

# ditto 是合并拷贝：镜像里有上次中止留下的旧文件时会混在一起（比如残留的 SQLite -wal），必须先清空
manifest "$STAGE" > "$DST_LIST"
if [ -s "$DST_LIST" ]; then
  echo "镜像里已经有数据：$(summary "$DST_LIST")，多半是上次中止的迁移留下的。"
  echo "原数据还在 ${MNT}，镜像里这份可以丢掉。"
  read -r -p "清空镜像后重新拷？输入 yes 继续: " ok
  [ "$ok" = "yes" ] || { echo "已中止，未做任何修改。"; exit 1; }
  (cd "$STAGE" && find . -mindepth 1 -maxdepth 1 "${PRUNE[@]}" -exec rm -rf {} +)
fi

echo "== 拷贝中（ditto，保留 ACL/xattr）=="
ditto "$MNT" "$STAGE"

echo "== 校验（逐个对比文件路径和大小，排除 .fseventsd 等卷元数据）=="
manifest "$MNT" > "$SRC_LIST"
manifest "$STAGE" > "$DST_LIST"
echo "源:   $(summary "$SRC_LIST")"
echo "目标: $(summary "$DST_LIST")"
if ! cmp -s "$SRC_LIST" "$DST_LIST"; then
  echo
  echo "不一致（< 只在源里，> 只在目标里，最多显示 20 行）："
  diff "$SRC_LIST" "$DST_LIST" | grep '^[<>]' | head -20 || true
  echo
  echo "已中止，原数据未动。"
  exit 1
fi
echo "一致。"
echo
read -r -p "继续替换成挂载点请输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已中止，原数据未动。可以重跑，镜像里这份副本到时会提示清空。"; exit 1; }

hdiutil detach "$STAGE" >/dev/null; trap - EXIT
rmdir "$STAGE" 2>/dev/null || true
rm -f "$SRC_LIST" "$DST_LIST"

# --- 3. 换成挂载点 -----------------------------------------------------
mv "$MNT" "${MNT}.bak"
mkdir -p "$MNT"
chflags uchg "$MNT"        # 未挂载时阻止微信写入，避免数据分叉
hdiutil attach "$IMG" -mountpoint "$MNT" -nobrowse -owners on >/dev/null

echo
echo "完成。挂载状态："
mount | grep -F " on ${MNT} (" || echo "  (警告：没看到挂载记录)"
echo
echo "现在打开微信，验证聊天记录 / 历史图片能否加载 / 文件能否打开 / 搜索。"
echo "确认无误后删除备份："
echo "  rm -rf \"${MNT}.bak\""
