# 变更记录（CHANGELOG）

## 4.0.0-1 — 2026-10-05

首个封装版本（上游 yt-dlp Web UI 4.0.0）。

- 新增：TOS 7 应用中心 deb 打包工程（`config.env` / `build.sh` / `makedeb.sh` / `Makefile` /
  `assets/` / `patches/` / `scripts/`）。
- 架构：新标签页（External Open）+ 回环 `127.0.0.1:13033` + nginx 剥离前缀反代 `/ytdlpwebui/`。
- 关键适配：上游前端 API/WS 地址不含路径前缀 → 新增
  `patches/0001-tos-mount-prefix.patch`（从 `window.location.pathname` 推导挂载前缀）。
- 运行时：随包分发 yt-dlp 2026.08.19（官方 Python zipapp，系统 python3 运行）与
  quickjs-ng 0.17.0（`bin/qjs`，yt-dlp 解 YouTube 签名挑战）；ffmpeg 走 TOS 系统包
  （`Depends: ffmpeg`，不随包分发预编译 ELF，V6 合规）。
- 安全：专用非 root 用户 `ytdlpwebui`；systemd 沙箱（NNP / ProtectSystem=full /
  CapabilityBoundingSet= 空集 / RestrictAddressFamilies）；无应用内账号，由 TOS 网关鉴权；
  postinst 内置 NNP 探测与最小降级 drop-in。
- 合规：`config.ini`（help=issues、official=上游 wiki）、23 语 `ytdlpwebui.lang`、
  双语隐私政策（三处可达）、`PROVENANCE.md` 溯源文档（放应用目录）。
- 构建：`source`（本仓库公开 CI 从源码构建，可提交）/ `compat`（本地迭代，禁止提交）双模式；
  fetch 阶段 sha256 双层校验（CI SHA256SUMS + config.env pin）。
- 文档：`AGENTS.md` / `HANDOFF.md` / `docs/{TASK_STATE,DESIGN_DECISIONS,SOURCE-AUDIT,CHANGELOG}.md`。
