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
