# yt-dlp Web UI for TOS (deb packaging)

把上游 [yt-dlp Web UI](https://github.com/marcopiovanello/yt-dlp-web-ui)（Go 后端 + 内嵌 React 前端的
yt-dlp 网页下载器）封装成 **TerraMaster TOS 7 应用中心**规范的 **deb** 包（amd64 / arm64）。

- **打开方式**：新标签页（External Open），路由 `/<appid>/`（默认 `/ytdlpwebui/`）
- **监听**：仅 `127.0.0.1:13033` 回环，唯一入口是 TOS nginx 网关，不额外开端口
- **运行用户**：专用非 root 用户 `ytdlpwebui`，systemd 沙箱加固
- **数据**：`/var/lib/ytdlpwebui`（队列库 / 下载文件 / 日志）；`apt remove` 保留，`apt purge` 删除

## 随包运行时（开箱即用）

| 组件 | 说明 |
|---|---|
| `bin/ytdlpwebui` | Go 后端（`source` 模式由本仓库公开 CI 从上游源码构建，前端内嵌） |
| `bin/yt-dlp` | yt-dlp 官方 **Python zipapp**（纯 `.py` 源码，可审计），由系统 `python3` 运行 |
| `bin/qjs` | quickjs-ng（yt-dlp 解 YouTube 签名挑战所需 JS 运行时） |
| `ffmpeg` | 使用 TOS 系统软件包（`Depends: ffmpeg`），**不随包分发预编译 ELF**（V6 合规） |

## 构建

生产包**全部在公开 CI 从源码构建**（`.github/workflows/build-upstream.yml`）：
上游 Go 源码（应用 TOS 子路径补丁 + pnpm 构建前端）+ quickjs-ng 源码（CMake）。
构建产物发布到 Release `build-v<上游版本>`，`config.env` 用 sha256 双重钉死。

```bash
./build.sh            # 默认 BUILD_MODE=compat：本地迭代（拉上游预编译二进制，禁止提交商店）
BUILD_MODE=source ./build.sh   # 从本仓库 CI Release 拉源码构建产物（可提交）
make arm64            # 构建 aarch64
make check            # 语法 + 资产静态自检
./build.sh info       # 查看当前版本/架构/模式
```

阶段：`fetch → stage → verify → deb`（可单独运行：`./build.sh fetch` 等）。

产物：
- `out/ytdlpwebui_<版本>_<arch>.deb` — 本地 `apt install` 测试用
- `out/ytdlpwebui_<platform>.deb` + `.sha256` — 上架资产（`platform` = `x86_64` / `aarch64`，版本由 Release tag 表达）

## 安装到 TOS

```bash
cat out/ytdlpwebui_x86_64.deb | ssh <user>@<nas> "cat > /tmp/ytdlpwebui.deb"   # 传包单独一条命令
ssh <user>@<nas>
apt install -y /tmp/ytdlpwebui.deb     # 会自动装齐 python3 / ffmpeg
```

打开：TOS 桌面 → **yt-dlp Web UI** 图标（新标签页 `http://<NAS的IP>:8181/ytdlpwebui/`），或在应用中心
「手动安装」页上传 `ytdlpwebui_x86_64.deb`。

## 配置

| 文件 | 说明 |
|---|---|
| `/usr/local/ytdlpwebui/config.yml` | 随包默认配置（回环地址/端口/路径），升级会被覆盖 |
| `/usr/local/ytdlpwebui/ytdlpwebui.env` | **用户级覆盖**（首装从 `.example` 复制，升级不覆盖），`APP_*` 环境变量优先级更高 |

常用覆盖项（修改后 `systemctl restart ytdlpwebui`）：

```ini
# 下载目录（默认 /var/lib/ytdlpwebui/downloads；改为共享卷前先给应用用户授权）
APP_PATHS_DOWNLOAD_PATH=/Volume1/media/downloads
# 并发下载数
APP_SERVER_QUEUE_SIZE=2
# 出网代理（NAS 不能直连目标站点时需要；例如国内直连不了 YouTube）
# ⚠️ 写在 /etc/profile.d/*.sh 里只对登录 shell 生效，systemd 服务不会继承——
#    必须写在本文件里，应用派生的 yt-dlp 子进程才会用到。
HTTP_PROXY=http://192.168.1.10:7890
HTTPS_PROXY=http://192.168.1.10:7890
http_proxy=http://192.168.1.10:7890
https_proxy=http://192.168.1.10:7890
```

> 说明：应用自身不做鉴权，访问由 TOS 网页服务（8181/5443）统一登录保护；后端只监听回环。

## 相关文档

- `AGENTS.md` — 项目宪法（新会话阅读顺序与硬性约束）
- `HANDOFF.md` — 交接清单
- `docs/TASK_STATE.md` — 状态快照
- `docs/DESIGN_DECISIONS.md` — 决策台账
- `docs/SOURCE-AUDIT.md` — 组件来源与 V6 审计链
- `docs/CHANGELOG.md` — 变更记录
- 跨项目知识库：`~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`
