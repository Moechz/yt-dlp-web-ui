# 决策台账（DESIGN_DECISIONS）

> 记录不可回退 / 有取舍的决策，含背景、结论、理由与替代方案。新增决策追加编号。

## D-001：打开方式 = 新标签页（External Open）

**Decision**：`config.ini` 用 `open_path: true` + `path: /ytdlpwebui/`，**不出现 `type` 字段**。

**理由**：上游前端为整页 SPA，iframe 集成需处理 frame 高度/X-Frame-Options；
新标签页零适配（参考 beszel/navidrome/alist）。`type` 与 `open_path` 互斥，混用被驳回。

## D-002：前端补丁 + nginx 剥离前缀反代（本项目的关键适配）

**背景**：上游前端在 `frontend/src/atoms/settings.ts` 用
`window.location.hostname` + `window.location.port` 拼 API/WebSocket 绝对地址
（`serverURL`、`rpcHTTPEndpoint`、`rpcWebSocketEndpoint`），**不含任何路径前缀**。
TOS 强制应用走 `/<appid>/` 网关路由，因此浏览器停在 `/ytdlpwebui/` 时，
前端会把请求发到 `http://<nas>:8181/api/v1/...`（**丢掉 /ytdlpwebui 前缀**）→ 404。

**候选方案**：
1. 让用户在前端设置里手填「反向代理 + 子目录」——但首屏登录/取版本就会 404，用户到不了设置页；且 TOS 非标准端口（8181/5443）下还会丢端口。**否决**。
2. nginx 在 TOS 根命名空间再代理 `/api/`、`/rpc/` 等——污染全局路由，且可能撞 TOS 自身接口。**否决**。
3. 前端补丁：从 `window.location.pathname` 推导挂载前缀并附加到 API base。**采用**。

**Decision**：
- `patches/0001-tos-mount-prefix.patch` 修改 `serverAddressAndPortState`：
  当应用挂在子路径时，把 `window.location.pathname`（去掉尾斜杠）附加到 host:port 之后。
  站点根运行时前缀为空，行为与上游一致（对其它部署无副作用）。
- CI 构建前端时应用该补丁；nginx `location /ytdlpwebui/ { proxy_pass http://127.0.0.1:13033/; }`
  **剥离**前缀转发。前端资源用相对路径（Vite `base: ''`）+ 哈希路由，路径前缀恒为 `/ytdlpwebui/`，
  REST / RPC(HTTP) / WebSocket(`/rpc/ws`) 全部自洽。

**验证点**：`browser → /ytdlpwebui/`；`fetch('/ytdlpwebui/api/v1/version')`；
`ws://<nas>:8181/ytdlpwebui/rpc/ws`。补丁可 `git apply --check` 于上游 tag。

## D-003：监听安全双层（config.yml + env 活动默认值）

**Decision**：`config.yml`（随包，升级覆盖）写死 `host: 127.0.0.1` / `port: 13033` /
`js_runtime_path` / `downloader_path`；`ytdlpwebui.env`（首装复制，升级不覆盖）再设
`APP_SERVER_HOST` / `APP_SERVER_PORT` 等活动默认值。删任一层都不会端口外泄。

**理由**：上游 v4 只解析 `--conf`，无 CLI 级监听参数；viper 环境变量仅对「已知键」生效，
故把全部键写进 `config.yml` 保证 override 生效。ExecStart 只写
`--conf /usr/local/ytdlpwebui/config.yml`（无 `$`，遵守坑 1）。

## D-004：端口 = 13033（回环）

**Decision**：`127.0.0.1:13033`。上游默认 3033 不在官方推荐段（8000-19999）；
13033 为其易记变体。端口在 config.yml / env / nginx / 文档 / 自检多处联动，**不可中途更改**。

## D-005：不启用应用内账号，由 TOS 网关鉴权

**Decision**：`authentication.require_auth: false`，不预置用户名/密码。

**理由**：应用仅监听回环，唯一入口是 TOS nginx（自带 TOS 账号登录），符合坑 38 的
「回环 + 网关鉴权」安全口径；上游前端的登录页只在 `/login` 路由，若开启鉴权首屏无提示会
让用户困惑（无「需要登录」四态）。metube 等同为无鉴权下载器。**不使用** F10 敏感信息落盘，
因为根本没有初始密码。

## D-006：ffmpeg 走 TOS 系统包（V6 合规）

**Decision**：`Depends: ffmpeg`，不随包分发 ffmpeg/ffprobe 预编译 ELF。

**理由**：audiobookshelf 真机实证 TOS 7 基座（Ubuntu 22.04 universe）预装 ffmpeg 4.4.x 且
`Depends: ffmpeg` 安装正常；V6 一票否决「无审计来源的预编译 ELF」。yt-dlp 通过 PATH 找到
`/usr/bin/ffmpeg` 做合流，无需额外配置。

## D-007：捆绑 yt-dlp（官方 Python zipapp）+ quickjs-ng，不自带 CPython

**Decision**：
- `bin/yt-dlp` = yt-dlp 官方 Release 的 **Python zipapp**（纯 `.py` + `yt_dlp_ejs`，非 ELF），
  由 TOS 系统 `python3`（3.10.x）运行；`Depends: python3`。
- `bin/qjs` = quickjs-ng，`source` 模式源码 CMake 构建；`--js-runtimes quickjs:<path>`。
- **不**捆绑 CPython 运行时（metube 路线），因 yt-dlp zipapp 在系统 Python 3.10 上实测可用，
  且系统 Python 是 dpkg 正规包（区别于坑 54 的 git）。

**理由 / 实测**：yt-dlp 2026.08.19 zipapp 在 Python 3.10.12 上 `--version` 正常，
`-v` 识别 `JS runtimes: quickjs-ng-0.17.0`；缺失 requests/brotli 等可选依赖仅降级个别站点功能，
默认 `Request Handlers: urllib` 足以覆盖主流站点。zipapp 内嵌 `yt_dlp_ejs`，无需联网取求解器。
**风险与缓解**：Python 3.10 被 yt-dlp 标记为 deprecated（仍可用）；若未来上游弃用 3.10，
改用 metube 的 CPython 源码捆绑方案（D-007 备选）。

## D-008：23 语超集

**Decision**：`ytdlpwebui.lang` 覆盖真机 14 语 + 官方英文文档口径的补集，共 23 节；
未翻译节点回退英文；zh-cn / zh-hk 为中文。`auth` = 上游作者 `marcopiovanello`。

**理由**：两套 14 语口径不一致（详见打包指南 §二），23 语超集同时满足。

## D-009：appid = ytdlpwebui；显示名 = yt-dlp Web UI

**Decision**：`id/system_id/package/user` 全用 `ytdlpwebui`（无连字符，规避 systemd 单元名
与用户名中的连字符问题）；`config.ini.publisher` = `Moechz`（坑 49：publisher 归打包者），
lang `auth` = `marcopiovanello`（作者归上游）。显示名带品牌 + 完整描述，避免与商店同名应用冲突（坑 12）。

## D-010：source / compat 双构建模式

**Decision**：`config.env` 的 `BUILD_MODE`：
- `source`（默认提交口径）：拉本仓库 CI Release `build-v<上游版本>` 的 Go 与 qjs 源码构建产物，
  双层 sha256 校验（CI SHA256SUMS + config.env pin）。审计链完整，**可提交商店**。
- `compat`（默认本地口径）：拉上游官方预编译 Go 二进制与 quickjs-ng 官方 release 二进制，
  仅供无 Go/Node 工具链的开发机做结构验证；产物在 `PROVENANCE.md` 标注 compat，**禁止提交**。

**理由**：本机（macOS/容器）无 Go/Node，无法本地源码构建；CI 承担真正的 V6 合规构建。
与 metube 的 `source/compat` 一致。

## D-011：数据目录与下载路径

**Decision**：`/var/lib/ytdlpwebui`（bolt.db 队列库 + 日志 + `downloads/` 默认下载目录）。
`apt remove` 保留，`apt purge` 删除。默认用应用内「文件浏览」取回文件；如需写入共享卷，
需先在 TOS 共享文件夹里给应用用户 `ytdlpwebui` 授权，再改 `APP_PATHS_DOWNLOAD_PATH`
（unit 用 `ProtectSystem=full` + `ProtectHome=read-only`，不锁死 /Volume）。

## D-012：systemd 沙箱

**Decision**：`NoNewPrivileges=true`、`ProtectSystem=full`、`ProtectHome=read-only`、
`CapabilityBoundingSet=`（空集）、`RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`、
`RestrictSUIDSGID`、`PrivateTmp` 等；**不配 `Restart`**（S05）。
`postinst` 内置 NNP 探测 + 最小降级 drop-in（坑 23）。

## D-013：应用图标留白 —— 可见图形占画布 81–84%（用户定稿）

**Decision**：`images/icons/ytdlpwebui.svg` 的背景圆角方块边长 = 画布 82.8%
（`x=y=5.5 width=height=53 viewBox=0 0 64 64`），居中，四周透明留白；
字形在方块内收。**禁止满幅 100%。**

**背景 / 证据**：用户指出「图标占背景方块的 81–84%，不要全部占满」。
交叉参照：`docker/authentik`（“图形缩至画布 84%、左右各留 8%”）、
`pi-agent-desktop-fork`（“可见区 824/1024 ~80% 居中、四角全透明”）。
满幅会让图标在 TOS 桌面上比其它应用大一圈。

**与 caseconvert D-010 的差异**：caseconvert 曾把 87.5% 的图标改成满幅（100%）——
那是当时「比别的图标显小」的过度修正；本规则为最新定稿，满幅不再采用。
以后新项目一律按 81–84% 出图。

**门禁**：`scripts/check_assets.py` 与 `build.sh verify` 双层断言
「背景 rect 边长 / viewBox 边长 ∈ [0.81, 0.84] 且居中」。

## D-014：应用中心安装报 `Command execute error / App state will be deleted` = 平台缺 SmackFS（与包无关）

**现象（2026-10-06 真机 strace 实锤）**：应用中心「手动安装」本包后，
`journalctl -u application` 出现：

```
DEBUG /usr/bin/systemctl disable ytdlpwebui
Shell execute error. ... Unit file ... does not exist.   ← 首次安装必现的非致命噪音
dpkg -i 成功 + postinst 成功
Command execute error. Error=exit status 1
App state will be deleted. AppID=ytdlpwebui
```

界面表现为「安装中」卡住/失败，但**注册产物其实齐全**（23 个 `@desktop/yt-dlp Web UI.*.oexe`、
`/etc/sc.d/ytdlpwebui`、`install_data.json`、`accesses.d` 行），`dpkg -l` = ii、
服务 active、`https://<nas>:5443/ytdlpwebui/` = 200 → **安装实际成功**。

**确切失败命令（strace 抓到）**：

```
sh -c 'echo "tos-1297 ytdlpweb-1297 rwxlta" | /usr/sbin/spcackload'
→ /usr/sbin/spcackload: "SmackFS is not mounted."  rc=1
```

**根因**：平台安装收尾无条件把应用访问行喂给 `spcackload`（SMACK 加载器）；
本 NAS 内核无 SMACK/SmackFS（`/proc/filesystems` 无 smack、无 `/sys/fs/smackfs`、无 smack 模块），
`spcackload` 必 exit 1 → 平台回滚内存状态。**mediamtx 同机 sideload 也报同一条** → 平台缺陷，非本包问题。

**处置**：不动包；刷新应用中心页面即可（图标/入口会正常出现）。
不改 `/usr/sbin/spcackload`、不挂 smackfs。已回灌打包指南坑 11b。

**关键取证手法**：`application` 是 **UPX 加壳**的 Go 程序，磁盘 `strings` 搜不到这些提示句；
必须 `strace -f -p $(pgrep -x application) -e trace=execve,exit_group -s 3000` 抓运行期。

## D-015：出网代理必须写进服务的 EnvironmentFile（/etc/profile.d 无效）

**现象（2026-10-06 真机）**：用户给 NAS 配了代理（`/etc/profile.d/profile_extend.sh` 里
`export http_proxy=http://<lan-ip>:7890`），但应用里建 YouTube 任务仍然失败，日志表现为
`yt-dlp process error: … Deprecated Feature: …`。

**根因**：`/etc/profile.d/*.sh` 只被**登录 shell** source；systemd 服务不读它，
因此 `ytdlpwebui` 进程（及其派生的 `yt-dlp`）环境里**没有 proxy**，
`yt-dlp` 直连 YouTube 超时（`rc=124`）。

**Decision**：代理写在 `/usr/local/ytdlpwebui/ytdlpwebui.env`（服务的 `EnvironmentFile`），
并同时给出大小写四种变量名（`HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy`）。
随包模板已加注释示例；README 配置节同步说明。

**验证**：改后 `/proc/<pid>/environ` 可见 proxy；`yt-dlp <youtube> -J` 走代理 `rc=0`
（标题 + 48 个格式）；经应用 RPC 建 YouTube 任务 → 文件持续增长、后续 ffmpeg 合流。

**同时发现并记录的两个自研/上游问题（待办）**：
- **P1（自研，影响体验）**：TOS 系统 Python 3.10 → yt-dlp 每次运行都往 **stderr** 打
  `Deprecated Feature: Support for Python version 3.10 has been deprecated…`
  （`yt_dlp/update.py:_get_system_deprecation()`，`to_stderr(force=True)`，
  `--no-warnings`/`--quiet` 均压不掉，已实测）。应用把 stderr 全文当错误返回
  （`metadata/fetchers.go`），于是这句警告**顶在真错误前面**、日志每跑一次就一条红。
  修法二选一：① 构建期给 zipapp 打一行补丁（`return None`）+ 记录到 PROVENANCE；
  ② 随包 CPython 3.12+/3.13（metube 路线），彻底消除。
- **P2（上游，影响 YouTube 画质）**：应用的**取元数据**命令是 `yt-dlp <url> -J`，
  **没有**传 `--js-runtimes quickjs:…`（只有下载那条传了）→ 日志出现
  `WARNING: [youtube] No supported JavaScript runtime could be found…`，
  部分格式可能缺失。修法：构建期给 `metadata.DefaultFetcher` 补 `--js-runtimes`
  （自研补丁，需随 PROVENANCE 记录）。

## D-016：P1 选「补丁 zipapp」而非「随包 CPython」；P2 给取元数据补 JS 运行时

**P1（消除 Python 3.10 弃用警告）→ 方案 A：构建期给随包 yt-dlp zipapp 打一行可复现补丁。**

- 现象：TOS 系统 Python 3.10 → yt-dlp **每次实例化 `YoutubeDL`** 都往 stderr 打
  `Deprecated Feature: Support for Python version 3.10 has been deprecated…`
  （`yt_dlp/update.py:_get_system_deprecation()`，上游 `to_stderr(force=True)`，
  `--no-warnings`/`--quiet` 压不掉，真机实测）。应用把子进程 stderr **全文**当错误文案
  返回（`metadata/fetchers.go`），该警告因此顶在真错误前、日志每次一条红。
- 补丁：`build.sh: patch_ytdlp_zipapp()` 把 `_get_system_deprecation()` 首行改为
  `return None`（等价于上游在 Python>3.11 时的行为）。保留原 zip 条目元数据 → 输出确定。
- **为何不选方案 B（随包 CPython）**：B 会给 deb 增加 50+ 个 ELF（python3/libpython/
  各 stdlib 扩展 .so），**直接命中 V6**（判据是"源码+配方位级可复现"，不是"供应链可信"；
  metube 全源码 CI 后仍被列 V6，alist 整改后仍是 On Hold+仅剩 V6）。
  而 zipapp 是纯 `.py`，打补丁**不引入任何 ELF → V6 中性**，用户可见效果与 B 相同。
- 门禁：`verify` 断言包内 `update.py` 含注入的 `return None`，并**离线实测**
  （`python3 bin/yt-dlp --simulate http://127.0.0.1:1/x` → stderr 不得出现
  `Deprecated Feature`；该路径会实例化 YoutubeDL，故必触发）。上游原件 sha256 仍在
  fetch 阶段按 pin 校验；补丁与原因记入 `PROVENANCE.md` §1.5。

**P2 → 构建期补丁 `patches/0002-metadata-js-runtimes.patch`。**

- 现象：上游取元数据命令是 `yt-dlp <url> -J`，**没传** `--js-runtimes`（只有下载那条传）
  → 日志出现 `WARNING: [youtube] No supported JavaScript runtime could be found…`，
  部分格式可能缺失。
- 补丁：`metadata.DefaultFetcher` 读 `Paths.JSRuntimePath` 并追加 `--js-runtimes <path>`。
- CI 构建期断言：`grep -q 'Paths.JSRuntimePath' server/internal/metadata/fetchers.go`。

**真机验证（tnas-57）**：新包安装后新建 YouTube 任务 → 新增日志里
`Deprecated Feature` / `No supported JavaScript runtime` / `yt-dlp process error` 均为 **0 次**；
此前的 YouTube 任务已完成（`.webm`，203 MB）。

**附带记录（环境，非包问题）**：代理配在 `/etc/profile.d/*.sh` 对 systemd 服务无效，
必须写进服务的 EnvironmentFile——见 D-015 与打包指南坑 11c。

## D-017：单元必须引用 TOS 系统环境 `/etc/systemd/tos_env.conf`（系统代理由此下发）

**背景（2026-10-06 真机）**：用户用 TOS 控制面板配了代理，但应用建任务仍然超时。
逐层排查后定位：控制面板代理同时写 `/etc/systemd/tos_env.conf`
（`HTTP_PROXY/HTTPS_PROXY/FTP_PROXY`）与 `/etc/profile.d/profile_extend.sh`；
TOS 自己的服务（`application`/`TOSDaemon`/`clouddisk`/`filemanage`）都以
`EnvironmentFile=-/etc/systemd/tos_env.conf` 读它，而**第三方应用单元一律没有引用**
（实测 8 个已装应用引用次数全为 0），官方 deb/服务规范也从未提及。

**Decision**：`assets/init.d/ytdlpwebui.service` 增加
`EnvironmentFile=-/etc/systemd/tos_env.conf`，位置在自有 `ytdlpwebui.env` **之前**
（systemd 后读覆盖先读 → 系统代理自动生效、自有 env 仍可单应用覆盖）。
随包 `ytdlpwebui.env` 的代理段保留为「显式覆盖」用途，并注明系统代理来自 `tos_env.conf`。

**真机验证**：删掉手工写在 `ytdlpwebui.env` 的代理行后重装，`/proc/<pid>/environ`
仍可见三（大写）proxy 变量（来源即 `tos_env.conf`），gateway 200、YouTube 端到端可用。

**同步动作**：已把该坑写进打包指南**坑 11e**（并标明「存量已封项目同样中招，需回灌单元模板」），
另向 TerraMaster 提交平台侧报告
（`.tdp/TOS-AppCenter-system-proxy-not-passed-to-apps.md`，建议平台为应用单元注入受管 drop-in
或 `DefaultEnvironment` 全局下发，并把这些写进官方规范）。

## D-018：下载目录改为数据卷共享文件夹（`ter_share_add`），修正 D-011

**背景（2026-10-06 真机实测）**：D-011 把默认下载目录设为 `/var/lib/ytdlpwebui/downloads`，
而该路径**在系统分区上**——实测本机 `/` = `/dev/md9` 仅 **7.5 GB 总 / 2.0 GB 可用**，
下载两部视频就吃掉 256 MB。根分区写满会连带拖垮系统服务/数据库/日志，后果远超"下不了"。

同时发现**官方 best-practices 明确规定了布局**（本地镜像
`hermes-agent-webui/docs/official/best-practices.txt`）：

- 应用运行时数据 → `/Volume*/@apps/<appid>/data/`（数据卷）
- **用户业务数据 → 共享文件夹 `/Volume*/<appid>/`**，postinst 里用
  **`ter_share_add -name <appid> -owner <appid>`** 创建（可 `ln -s` 到 `data/`）
- "Deb Applications: Runtime data is stored in /Volume*/@apps/<appid>/data/"

而我们此前既没落数据卷、也没建共享夹——**违反规范**，这也是用户在 TOS 文件管理器里
找不到下载文件的原因（`/var/lib` 不在共享夹命名空间内）。

**Decision**：下载目录 = **数据卷上的共享文件夹 `/<Volume N>/<appid>`**（下载的视频是用户数据）：

1. postinst 由平台镜像 `/Volume*/@apps/<appid>` 反推卷号（逐机不同），
   调官方 `ter_share_add -device <卷> -name <appid> -owner <appid>` 创建共享夹；
   工具缺失/失败则 `mkdir` 兜底（仍在数据卷）；再不行才回落系统分区私有目录**并醒目告警**。
2. 实际路径由 postinst 写进 `ytdlpwebui.env` 的 `APP_PATHS_DOWNLOAD_PATH`（env > config.yml）；
   `config.yml` 保留 `/var/lib/...` 仅作"env 被误删"的兜底。
3. **升级迁移**：若 env 里仍是旧默认值 `/var/lib/ytdlpwebui/downloads`（说明用户没自定义），
   则切到共享夹并把已有文件 `mv` 过去；**迁移失败则保持原目录并告警**（绝不让文件变得看不见）。
4. **purge 不删共享夹**（用户数据），只打印位置提示。
5. 23 语 `important` / `release_note` 已写明新下载目录；postinst 输出实际路径。
6. verify 新增门禁：postinst 必须含 `ter_share_add` / env 落值 / 系统分区告警，lang 必须写明共享夹，
   postrm 必须声明不删共享夹。

**真机验证（tnas-57）**：首装即建 `/Volume1/ytdlpwebui`（属主 ytdlpwebui），
env 落值 `/Volume1/ytdlpwebui`，3 个已有文件迁移成功，系统分区可用 2.0G→2.2G，
服务 active、gateway 200，新建任务 `sample-10s.mp4` 正确落到共享夹。
