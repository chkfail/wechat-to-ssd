# AGENTS.md

**给「使用这套脚本」的 agent**：看 [README.md](README.md) 后半部分《以下是给 agent 看的操作说明》，那里有完整流程、故障排查和设计约束。本文件不重复。

**本文件只管「改这个仓库的代码」。**

## 动手前

README 里《设计约束（改代码前必读）》那四条是硬约束：`uchg` 保护、免 root、`wechat-mount.sh` 幂等、配置不写死。改之前先读，别在这里重复一遍 —— 单一来源。

## 代码约定

每个脚本顶部的配置读取是固定四行，新增脚本照抄：

```bash
CONF="${WECHAT_TO_SSD_CONF:-$HOME/.config/wechat-to-ssd.conf}"
[ -f "$CONF" ] && . "$CONF"
IMG="${WECHAT_IMAGE:?...}"
MNT="${WECHAT_MOUNT:-$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files}"
```

plist 用 `.template` + 占位符，由 `install.sh` 里的 `sed` 填充。这是公开仓库，写死卷名或 home 路径会泄露个人信息 —— 之前踩过，`com.local.wechatmount.plist` 里展开后的 home 绝对路径差点被推上去。

`wechat-migrate.sh` 那两道 `yes` 确认不要合并或去掉。第二道的位置是关键：`ditto` 完成、校验结果打印之后、`mv` 之前。`wechat-restore.sh` 同理：第二道在拷回并校验之后、卸载镜像之前。

## 中文脚本特有的坑

**`$VAR` 紧跟多字节字符会被吞进变量名。** bash 解析 `$LOG）` 时找的是变量 `LOG）`。开了 `set -u` 的脚本直接崩，没开的静默取空值 —— 后者更难发现。全部用 `${VAR}` 显式界定。

提交前扫一遍：

```bash
perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_]\w*[^\x00-\x7F]/' *.sh
```

## 发布前检查

CI（`.github/workflows/check.yml`）每次 push 都会跑下面这些，本地提交前也可以先跑一遍：

```bash
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "FAIL $f"; done
git ls-files -z '*.sh' | xargs -0 perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_]\w*[^\x00-\x7F]/'
git ls-files -z '*.sh' | xargs -0 shellcheck -s bash -e SC1090
git grep -niE '/User[s]/|Mac-min[i]|ts\.ne[t]' -- .      # 个人信息，应无输出（方括号防止匹配到这行自己）
git ls-files -s '*.sh' | grep -v '^100755'                # 脚本应为 100755，应无输出
```

最后一条踩过：`install.sh` 被创建时没带执行位，clone 下来是 `permission denied`。

用 `grep -r` 扫个人信息不可靠（漏过一次），一律用 `git grep` 只扫跟踪文件。

## 测试

改挂载逻辑时，拿临时 sparsebundle 挂到 `$TMPDIR` 下的目录验证，别拿真实微信数据试：

```bash
hdiutil create -size 1g -type SPARSEBUNDLE -fs APFS -volname T "$TMPDIR/t.sparsebundle"
hdiutil attach "$TMPDIR/t.sparsebundle" -mountpoint "$TMPDIR/m" -nobrowse -owners on
```

注意你自己的 shell 多半没有完全磁盘访问权限，容器相关的命令必须交给用户在「终端」App 里跑。

CI 的 macOS job 会跑 `tests/smoke.sh`：临时 HOME + 临时 sparsebundle，用 `/bin/bash` 3.2 把 install → migrate → mount → compact → restore 走一遍。改了流程就同步改它。它会注册和注销 `com.local.wechatmount` 这个 LaunchAgent，所以只在 CI 里跑（没有 `CI` 环境变量会直接退出），别在装着真实方案的 Mac 上跑。
