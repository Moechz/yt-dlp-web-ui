# 组件来源与 V6 审计链（SOURCE-AUDIT）

> 面向平台审核（V6：不得携带无审计来源的预编译二进制）与后续维护。
> 包内同名文件为 `/usr/local/ytdlpwebui/PROVENANCE.md`（坑 50：放应用目录，`/usr/share/doc` 会被 TOS dpkg 剥离）。

## 1. 审计链总览

```
上游源码 tag
  └─ 本仓库公开 workflow  .github/workflows/build-upstream.yml
       ├─ checkout marcopiovanello/yt-dlp-web-ui @ <tag> + patches/0001-tos-mount-prefix.patch
       │    └─ frontend: pnpm install --frozen-lockfile && pnpm build
       │    └─ backend : CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"
       └─ quickjs-ng/quickjs @ <tag>  → cmake --build --target qjs_exe
  └─ 公开 Actions 日志（run id 记录在 Release 说明）
  └─ Release build-v<上游版本>：ytdlpwebui-linux-*.tar.gz / qjs-linux-*.tar.gz + SHA256SUMS
       └─ deb 构建 fetch 阶段：SHA256SUMS 校验 + config.env pin 二次校验
```

## 2. 包内可执行载荷来源

| 路径 | 组件 | 来源 | 构建方式 | 是否 ELF |
|---|---|---|---|---|
| `bin/ytdlpwebui` | 后端 + 内嵌前端 | 上游 Go 源码 tag + TOS 补丁 | CI：pnpm 构建前端 + `go build` 静态 | 是（Go 静态） |
| `bin/qjs` | quickjs-ng | `quickjs-ng/quickjs` 源码 tag | CI：CMake `qjs_exe`，strip | 是（C，静态） |
| `bin/yt-dlp` | yt-dlp 下载器 | yt-dlp 官方 Release 的 **Python zipapp** | 上游官方构建（纯 `.py` 源码，可审计） | **否**（zipapp，系统 python3 运行） |

## 3. 不随包分发的系统依赖（避免 V6）

| 组件 | 声明 | 说明 |
|---|---|---|
| `ffmpeg` | `Depends: ffmpeg` | TOS 系统包（Ubuntu 22.04 universe，真机预装）；不复制其 ELF |
| `python3` | `Depends: python3` | TOS 系统包（3.10.x）；运行 yt-dlp zipapp |
| `systemd` | `Depends: systemd` | 服务生命周期与沙箱 |

## 4. 安装期零外联（S8）

所有 deb 维护脚本（`preinst/postinst/prerm/postrm`）不做在线安装或下载：
缺依赖只打印提示，不 `apt install` / `pip install` / `curl | bash`。
`build.sh verify` 与 `scripts/check_assets.py` 均内置该断言（与审查员同款扫法）。

## 5. 运行期外联（用户主动发起，非安装期）

- 提交下载 URL → `bin/yt-dlp` 直连目标站点（用户指定）。
- 点击更新按钮 → `yt-dlp -U` 访问其官方发布渠道。
- 处理 YouTube → 可能按 `--remote-components ejs:github` 拉取辅助求解组件（不含个人数据）。

## 6. 许可证

| 组件 | 许可证 |
|---|---|
| yt-dlp Web UI（上游） | GPL-3.0（全文随包 `/usr/share/doc/ytdlpwebui/copyright`） |
| yt-dlp | Unlicense / ISC / MIT |
| quickjs-ng | MIT |
| ffmpeg（系统包） | 由 TOS 发行版提供 |
