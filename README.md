# wechat-to-ssd

把 Mac 微信的聊天数据挪到外置 SSD 上，微信照常用。不用重签名，也不用装 macFUSE 之类的内核扩展。

<details>
<summary>English</summary>

WeChat for Mac keeps its chat history inside its sandbox container and has no
setting to move it. Symlinks fail because the sandbox checks the resolved path,
and re-signing the app breaks on every update. This project keeps the path and
swaps the filesystem behind it: an APFS sparsebundle on an external SSD is
mounted directly at the container's data directory. Mounting needs no root, so a
user LaunchAgent remounts it at boot and when the drive is plugged back in.

</details>

## 用法

最省事的是交给 AI agent。把这句话发给 Claude、Codex、Zcode，或者别的能在你电脑上跑命令的 agent：

```
读 https://github.com/chkfail/wechat-to-ssd 的 README，帮我把 Mac 微信数据迁到外置 SSD
```

README 后半部分是写给 agent 的说明。中间有两个系统设置得你自己点，它会提示你。

自己装的话：

```bash
git clone https://github.com/chkfail/wechat-to-ssd.git
cd wechat-to-ssd
./install.sh /Volumes/你的SSD
```

装完给 `/bin/bash` 完全磁盘访问权限，再在「终端」里跑 `./wechat-migrate.sh`。具体见下面的安装流程。

## 须知

- 只支持微信 4.x。
- 能省多少看 `xwechat_files` 有多大，一般 10–50 GB。
- SSD 要一直接着。拔掉时微信打不开，但数据不会丢，插回去会自动挂上。
- 拔盘前先退出微信，不然数据库可能写坏。
- 开机自动挂载需要给 `/bin/bash` 完全磁盘访问权限。
- 适合常年接着盘的台式机，比如 Mac mini、Mac Studio。笔记本得考虑线被碰掉的情况。
- 手机上的记录才是主备份，Mac 这边当缓存看。

## 给 agent 的操作说明

### 权限

微信的容器目录受 TCC 保护。你的 shell（Claude Code 的 bash、IDE 里的终端等）多半没有完全磁盘访问权限，碰容器的命令都会报 `Operation not permitted`，关掉沙盒也没用。先测一下：

```bash
ls ~/Library/Containers/com.tencent.xinWeChat/Data >/dev/null 2>&1 && echo 有权限 || echo 无权限
```

没有权限的话，迁移和回退要让用户在「终端」App 里跑，你负责给命令、看输出。不要反复重试，也不要想办法绕过。所有步骤都不需要 sudo。

### 原理

沙盒按解析后的真实路径校验，软链接指到 `/Volumes/...` 会被拒，所以网上的教程才要重签名。挂载不改路径，只换掉路径背后的文件系统，沙盒规则照样匹配。macOS 没有 bind mount，所以用 sparsebundle 造一个卷挂上去：

```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files   挂载点，底下是带 uchg 的空目录
  └─ 内层 APFS 卷 WeChatData
       └─ /Volumes/你的SSD/WeChatData.sparsebundle
```

### 安装流程

1. 确认 SSD 已挂载（`ls /Volumes`），记下内置盘可用空间（`df -h /System/Volumes/Data`），确认微信已退出（`pgrep -x WeChat`）。
2. 运行 `./install.sh /Volumes/你的SSD`。它会建镜像、写 `~/.config/wechat-to-ssd.conf`、把脚本装到 `~/bin/`、加载 LaunchAgent，不动数据。
3. 让用户打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，点 `+`，按 Cmd+Shift+G 输入 `/bin/bash` 添加。LaunchAgent 靠它挂载，不加的话开机挂载会报 `Permission denied`。「终端」App 也要加，加完 Cmd+Q 退出再重新打开，授权对已经在运行的进程不生效。
4. 让用户退出微信，在「终端」里运行 `./wechat-migrate.sh`。脚本会拷贝数据、逐个文件对比，中间要输入两次 `yes`。对不上会自己中止，原数据不动。
5. 让用户打开微信，看聊天记录、历史图片、文件、搜索是不是都正常。图片和文件最容易暴露拷贝问题。都没问题再删备份：

   ```bash
   rm -rf ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files.bak
   df -h /System/Volumes/Data
   ```

   备份删掉之前空间不会释放，别提前告诉用户省了多少。

6. 让用户重启，再打开微信。历史记录还在，就说明开机挂载正常。不正常的话看 `~/Library/Logs/wechatmount.log` 和 `mount | grep xwechat`。

### 常见问题

| 现象 | 原因 |
|---|---|
| 读容器报 `Operation not permitted` | 没有完全磁盘访问权限，或者授权后没重启那个进程 |
| `hdiutil: attach failed - Permission denied` | `/bin/bash` 没有完全磁盘访问权限 |
| `hdiutil: attach failed - Resource busy` | 镜像已经挂在别处了。用 `hdiutil info` 找到它，`hdiutil detach` 后再挂 |
| 微信打不开，或者要求重新登录 | 镜像没挂上。运行 `bash ~/bin/wechat-mount.sh`，数据还在 |
| 日志里有「不是迁移后留下的空挂载点」 | 还没迁移，或者已经回退了，这时不挂载是对的 |

### 日常维护

```bash
mount | grep xwechat           # 看有没有挂上
bash ~/bin/wechat-mount.sh     # 手动挂载
bash ~/bin/wechat-compact.sh   # 回收空间，先退出微信
```

sparsebundle 只会变大。在微信里删了聊天记录，空间也不会还给 SSD，要跑一次 `wechat-compact.sh`。

如果用 Time Machine 备份这块 SSD，记得把 sparsebundle 加进排除列表，不然每次都要备份一堆 band 文件。

### 回退

让用户退出微信，在「终端」里运行 `./wechat-restore.sh`。它会先检查内置盘空间，把数据拷回来并对比，然后卸载镜像、删掉 LaunchAgent。镜像本身不删，确认没问题后再手动删。

## 设计约束

改代码前先看这四条：

1. 挂载点是一个带 `uchg` 标志的空目录。挂载失败时微信写不进去，只会报错。没有这个标志，微信会在内置盘上新建一套数据，下次挂载成功时这套数据就被盖住了（这一点在真实的挂载失败里验证过）。`wechat-mount.sh` 也靠它判断能不能挂：目录非空或者没有 `uchg` 就不挂，免得把真实数据遮住。
2. 方案的前提是 `hdiutil attach -mountpoint` 不需要 root，所以才能用 LaunchAgent。想换成 `diskutil` 或别的挂载方式，先确认它还是不需要 root。
3. `wechat-mount.sh` 必须幂等。`StartOnMount` 在任何卷挂载时都会触发。
4. 配置从 `~/.config/wechat-to-ssd.conf` 读，环境变量可以覆盖。脚本里不要写死卷名或 home 路径。

## 文件

- `install.sh`：建镜像、写配置、装脚本和 LaunchAgent
- `wechat-migrate.sh`：一次性迁移
- `wechat-mount.sh`：挂载，LaunchAgent 在开机和插盘时调用
- `wechat-compact.sh`：回收镜像空间
- `wechat-restore.sh`：回退到内置盘
- `com.local.wechatmount.plist.template`：LaunchAgent 模板
- `tests/smoke.sh`：CI 里跑的冒烟测试
- `AGENTS.md`：改代码的约定和检查清单

## 其他方案

- 软链接加重签名：每次微信更新都得重签，截图这类依赖签名的功能会失效。
- macFUSE 加 bindfs：要装第三方内核扩展，Apple Silicon 上还得降低启动安全策略。
- 在 SSD 的 APFS 容器里直接加一个卷：存储更干净，但挂到自定义路径需要 root，得改用 LaunchDaemon。没试过。

## License

MIT
