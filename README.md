# wechat-to-ssd

**Mac 微信吃掉几十 GB 内置盘？把聊天数据搬到外置 SSD，微信照常用。**

不重签名、不装任何第三方软件、不降低系统安全设置。

![platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![license](https://img.shields.io/badge/license-MIT-blue)

<details>
<summary>English summary</summary>

WeChat for Mac keeps tens of gigabytes of chat history inside its App Sandbox
container and, unlike the Windows client, offers no setting to move it. A symlink
does not work: the sandbox resolves symlinks and checks the *real* path, which then
lies outside the container. The popular workaround — stripping the code signature
with `codesign --force --deep --sign -` — breaks on every WeChat update and disables
entitlement-dependent features.

This project instead **mounts an APFS sparsebundle stored on an external SSD directly
at the container's data directory**. A mount does not change the path, only the
filesystem behind it, so the sandbox rule still matches and the signature is
untouched. No re-signing, no macFUSE/kext, no reduced startup security policy.
Because `hdiutil attach -mountpoint` needs no root, a plain user LaunchAgent handles
mounting at boot and on re-plug. An immutable (`chflags uchg`) mount point stops
WeChat from silently rebuilding a divergent data set while the SSD is absent.

</details>

---

## 最省事的用法

把下面这句话丢给 Claude、Codex、Zcode，或任何能在你电脑上跑命令的 AI agent：

```
读 https://github.com/chkfail/wechat-to-ssd 的 README，帮我把 Mac 微信数据迁到外置 SSD
```

本 README 后半部分就是写给它看的操作说明，它会照着做完，包括中途需要你手动点的两个系统设置。

## 自己动手

```bash
git clone https://github.com/chkfail/wechat-to-ssd.git
cd wechat-to-ssd
./install.sh /Volumes/你的SSD
```

然后按屏幕提示做两件事：给 `/bin/bash` 完全磁盘访问权限，再在「终端」App 里跑 `./wechat-migrate.sh`。详细步骤见下面的《安装流程》。

## 用之前先知道这几件事

| | |
|---|---|
| **能省多少** | 你的 `xwechat_files` 目录有多大就省多少，通常 10–50 GB |
| **SSD 要常年接着** | 拔掉时微信打不开（数据不会丢），插回自动恢复 |
| **拔盘前必须退微信** | 这是唯一的真实风险点，SQLite 写到一半断连会坏库 |
| **手机才是主备份** | Mac 端始终当缓存看待 |
| **适合谁** | Mac mini / Studio 这类常年接盘的台式机最合适；笔记本要掂量一下线被碰掉的概率 |
| **微信版本** | 只支持 4.x（数据在 `xwechat_files`），3.x 先升级 |

---

# 以下是给 agent 看的操作说明

## 先读这段：你多半干不了全部的活

微信数据目录受 **TCC（完全磁盘访问权限）** 保护。你所在的 shell —— 无论是 Claude Code 自己的 bash、`!` 命令模式还是 IDE 集成终端 —— **几乎肯定没有这个权限**，所有触碰容器的命令都会返回 `Operation not permitted`。这不是沙盒问题，关掉沙盒也没用。

开工前先测一下：

```bash
ls ~/Library/Containers/com.tencent.xinWeChat/Data >/dev/null 2>&1 && echo "有权限" || echo "无权限"
```

显示「无权限」时，**迁移那一步必须让用户自己在「终端」App 里执行**，你负责给出命令和判断输出。别反复重试，也别试图绕过。

## 原理

App Sandbox 校验的是**路径解析之后的真实位置**。软链接会解析到 `/Volumes/...`，落在容器外，直接被拒 —— 所以网上那些教程要靠重签名砸掉沙盒。

挂载不一样：它不改变路径，只替换路径背后的文件系统，沙盒的 `subpath` 规则照常匹配。macOS 没有 `mount --bind`，不能把目录挂到目录上，所以需要 sparsebundle 造出一个真正的块设备。

```
微信（沙盒进程）
 ▼  只认这一个路径
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files   ← 挂载点
 ▼  底下是 chflags uchg 的空目录，挂载时被盖住
/dev/diskNs1   内层 APFS 卷「WeChatData」
 ▼
/Volumes/你的SSD/WeChatData.sparsebundle
```

## 安装流程

### 0. 前置检查

```bash
ls /Volumes                                    # 确认 SSD 已挂载
df -h /System/Volumes/Data                     # 记下当前可用空间，迁移后对比
mount | grep -i "你的SSD"                       # 确认文件系统，APFS/HFS+ 最佳
pgrep -x WeChat && echo "微信在运行，需要退出"
```

### 1. 安装

```bash
./install.sh /Volumes/你的SSD
```

创建镜像、写配置到 `~/.config/wechat-to-ssd.conf`、装脚本到 `~/bin/`、生成并加载 LaunchAgent。**不碰数据。**

### 2. 让用户给 `/bin/bash` 完全磁盘访问权限

这步你做不了，必须用户手动操作：

> 系统设置 → 隐私与安全性 → 完全磁盘访问权限 → `+` → 文件选择器里按 **Cmd+Shift+G** → 输入 `/bin/bash` → 添加并打开

LaunchAgent 以 `/bin/bash` 身份访问受 TCC 保护的容器目录，不给权限开机挂载必然报 `Permission denied`。

同时也要让用户给「终端」App 加上同样的权限（下一步要用），**加完必须 Cmd+Q 退出终端再重开**，TCC 授权对已运行的进程不生效。

### 3. 迁移数据

让用户在**有完全磁盘访问权限的「终端」App** 里执行，先 Cmd+Q 完全退出微信：

```bash
./wechat-migrate.sh
```

脚本把 `xwechat_files` 拷进镜像，再逐个对比两边的文件路径和大小（自动排除 `.fseventsd` 等卷元数据）。**破坏性操作前有两道 `yes` 确认。**

核对要点：打印「一致」才会问第二道 `yes`；不一致会直接中止并列出差异，原数据不动。已经迁移过（挂载点已挂上、带 `uchg`，或 `.bak` 还在）会拒绝重跑。镜像里有上次中止留下的数据时会先问要不要清空 —— 原数据还在内置盘上，清空是安全的。

### 4. 验证

让用户打开微信，确认四项：聊天记录在、**历史图片能真正加载出来**、文件能打开、搜索能用。图片和文件最容易暴露拷贝问题。

确认无误后再删备份：

```bash
rm -rf ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files.bak
df -h /System/Volumes/Data     # 和第 0 步对比，空间应该降下来了
```

**删备份之前空间不会释放**，别在这之前就报告「迁移完成，省出了 X GB」。

### 5. 验证开机自动挂载

让用户重启，然后开微信看历史记录在不在 —— 数据只存在于镜像里，记录能显示就证明挂载成功了。

失败的话：

```bash
cat ~/Library/Logs/wechatmount.log      # 也可以在「控制台」App 的「日志报告」里看
mount | grep xwechat
```

日志里 `Permission denied` 或 `Operation not permitted` = 第 2 步的 `/bin/bash` 授权没做或没生效。

## 故障排查

| 现象 | 原因 |
|---|---|
| `Operation not permitted` 读容器 | TCC，不是沙盒。需要完全磁盘访问权限，且授权后要重启进程 |
| `hdiutil: attach failed - Permission denied` | LaunchAgent 跑的 `/bin/bash` 没有完全磁盘访问权限 |
| `hdiutil: attach failed - Resource busy` | 镜像已经挂在别处了（比如在 Finder 里双击打开过）。`hdiutil info` 找到它，`hdiutil detach` 掉再挂 |
| 微信打不开、提示重新登录 | 镜像没挂上。跑 `bash ~/bin/wechat-mount.sh`，数据没丢 |
| 日志里「不是迁移后留下的空挂载点」 | 挂载点非空或没有 `uchg`：还没迁移，或已经回退。这是保护，挂上去会遮住真实数据 |
| `unbound variable` | `$VAR` 紧跟全角标点会被 bash 吞进变量名，用 `${VAR}` |
| `sudo` + `<(...)` 报 `Bad file descriptor` | sudo 切断了进程替换的 fd。本项目所有操作都不需要 sudo |

## 日常维护

```bash
mount | grep xwechat                              # 查看挂载状态
bash ~/bin/wechat-mount.sh                        # 手动挂载
bash ~/bin/wechat-compact.sh                      # 回收空间（先退微信）
```

**sparsebundle 只增不减。** 在微信里删聊天记录不会把空间还给 SSD，要跑 `wechat-compact.sh`。

**如果用 Time Machine 备份那块外置盘**，记得把 sparsebundle 加进排除列表，否则每次备份都要传一堆 band 文件。

## 回退

先 Cmd+Q 退微信，在有完全磁盘访问权限的「终端」App 里：

```bash
./wechat-restore.sh
```

脚本先检查内置盘空间够不够，把镜像里的数据拷回内置盘并逐个对比，再卸载镜像、移除 LaunchAgent、把副本换回原位置。两道 `yes` 确认；中途中止的话镜像照常挂着，微信不受影响。

镜像本身不删，确认微信正常后按脚本最后的提示手动删。

## 设计约束（改代码前必读）

**`uchg` 不是装饰。** 挂载点空目录上的 immutable 标志是数据分叉保护：挂载失败时微信写不进去、只会报错。没有它，微信会在内置盘重建一套空数据，用户以为没事继续用，下次挂载成功时这套新数据被盖掉 —— 那才是真正丢数据的场景。已在真实的挂载失败中验证生效。`wechat-mount.sh` 也靠它认挂载点：只往空的、带 `uchg` 的目录上挂，否则拒绝 —— 迁移前或回退后那里是真实数据，挂上去会把它遮住。

**免 root 是整个方案成立的前提。** `hdiutil attach -mountpoint <用户目录>` 不需要 root，所以能用 LaunchAgent 而非 LaunchDaemon。任何改用 `diskutil` 或其他挂载方式的改动，都必须先验证免 root 是否还成立。

**`wechat-mount.sh` 必须幂等。** `StartOnMount` 会在任何文件系统挂载时触发，重复执行是常态。

**配置统一从 `~/.config/wechat-to-ssd.conf` 读**，环境变量可覆盖。别在脚本里写死卷名或 home 路径。

## 文件

| 文件 | 作用 |
|---|---|
| `install.sh` | 建镜像、写配置、装脚本和 LaunchAgent。不动数据 |
| `wechat-migrate.sh` | 一次性迁移。逐文件校验 + 两道确认 |
| `wechat-mount.sh` | 挂载。幂等，只往空的 `uchg` 挂载点上挂，等待 SSD 出现（默认最多 180 秒） |
| `wechat-compact.sh` | 回收 sparsebundle 空间 |
| `wechat-restore.sh` | 回退：数据拷回内置盘、移除 LaunchAgent。逐文件校验 + 两道确认 |
| `com.local.wechatmount.plist.template` | LaunchAgent 模板，`RunAtLoad` + `StartOnMount` |
| `AGENTS.md` | 改这个仓库代码时的约定和检查清单（`CLAUDE.md` 指向它） |

## 对比其他方案

| 方案 | 结论 |
|---|---|
| 软链接 + 重签名 | ❌ 破坏沙盒签名，微信每次更新都要重签，截图等功能失效 |
| macFUSE + bindfs | ❌ 需加载第三方 kext；Apple Silicon 必须降低启动安全策略 |
| SSD 的 APFS 容器里直接加卷 | ⚠️ 存储更干净，但挂到自定义路径需要 root → 得用 LaunchDaemon。未验证 |
| **sparsebundle + 挂载点** | ✅ 免 root、免 kext、不动签名 |

## License

MIT
