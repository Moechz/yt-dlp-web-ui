#!/usr/bin/env bash
# ============================================================
# build.sh - 把 yt-dlp Web UI 打包成 TOS 7 应用中心规范的 deb
#            （WebUI External Open / 新标签页 + 回环监听模式）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification（目录结构/config.ini/nginx/systemd/生命周期）
#   - Package Specification（版本号三处一致、资产命名）
#
# 运行时组成（上游是"Go 后端 + 内嵌前端"，下载能力靠外部进程）:
#   1) bin/ytdlpwebui  Go 后端（source 模式由本仓库公开 CI 从上游源码构建，
#                      V6 审计链：源码 tag → workflow → Actions → build-v* Release）
#   2) bin/yt-dlp      yt-dlp 官方 Python zipapp（纯 .py 源码，源码可审计，
#                      由 TOS 系统 python3 运行；Depends: python3）
#   3) bin/qjs         quickjs-ng（yt-dlp 解 YouTube n/sig 签名挑战所需 JS 运行时，
#                      source 模式从源码 CMake 构建，约 2.5MB，无 V8 风险）
#   4) ffmpeg          TOS 系统软件包（Depends: ffmpeg；V6 合规：不随包分发预编译 ELF）
#
# 子路径适配: 上游前端把 API/WebSocket 地址写死为 hostname:port，不含挂载前缀；
#   patches/0001-tos-mount-prefix.patch 让前端从 window.location.pathname
#   推导前缀（CI 构建前端时应用该补丁），nginx 再剥离 /ytdlpwebui/ 前缀转发。
#
# 产物（out/）:
#   ytdlpwebui_<版本>_<arch>.deb        完整版本名 deb（本地 apt 安装/测试用）
#   ytdlpwebui_<platform>.deb           Release 资产名 deb（上架上传用，版本由 Release tag 表达）
#   ytdlpwebui_<platform>.deb.sha256    上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

VERSION_FULL="${YTDLPWEBUI_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台映射（集中一次，四处口径不写死） ----------------
case "$TARGET_ARCH" in
  amd64)
    GOARCH="amd64"
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    QJS_ARCH="x86_64"
    PINNED_TARBALL="$SHA256_TARBALL_AMD64"
    PINNED_UPSTREAM="$SHA256_UPSTREAM_AMD64"
    PINNED_QJS="$SHA256_QUICKJS_AMD64"
    ;;
  arm64)
    GOARCH="arm64"
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    QJS_ARCH="aarch64"
    PINNED_TARBALL="$SHA256_TARBALL_ARM64"
    PINNED_UPSTREAM="$SHA256_UPSTREAM_ARM64"
    PINNED_QJS="$SHA256_QUICKJS_ARM64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

TAG="v$YTDLPWEBUI_VERSION"
BUILD_MODE="${BUILD_MODE:-compat}"

# source 模式产物源：本仓库 CI 的 Release build-v<上游版本>
BIN_SOURCE_BASE="https://github.com/Moechz/yt-dlp-web-ui/releases/download/build-v$YTDLPWEBUI_VERSION"
# compat 模式产物源：上游官方 Release
UPSTREAM_BASE="https://github.com/marcopiovanello/yt-dlp-web-ui/releases/download/$TAG"
QJS_BASE="https://github.com/quickjs-ng/quickjs/releases/download/$QUICKJS_VERSION"
YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"

# 下载缓存按 tag/架构/模式隔离（坑 48 陷阱 4：按文件名键控会复用旧 tag 产物）
DL_DIR="$BUILD_DIR/downloads/$VERSION_FULL-$TARGET_ARCH-$BUILD_MODE"
STAGE_DIR="$BUILD_DIR/pkgroot"

DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TARGET_ARCH}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"       # Release 资产命名（无版本）
MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file>（多次重试 + 断点续传）
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "已缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"
    warn "下载失败(第 $attempt 次): $(basename "$dest")，10 秒后重试..."
    sleep 10
  done
  die "下载失败: $url"
}

fetch_soft() { # 与 fetch 相同但失败不致命（可选资产，如第三方许可证）
  local url=$1 dest=$2 attempt=0
  [ -s "$dest" ] && return 0
  while [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 2 --retry-delay 3 --retry-all-errors \
         --connect-timeout 15 --max-time 60 -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"; return 0
    fi
    rm -f "$dest.part"; sleep 3
  done
  warn "可选资产下载失败（忽略）: $url"
  return 0
}

sha256_of() { # sha256_of <file> -> 64 位哈希（macOS/Linux 兼容）
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

verify_sha256() { # verify_sha256 <file> <pin> <label>
  local f=$1 pin=$2 label=$3 got
  [ -s "$f" ] || die "缺少文件: $f"
  [ -n "$pin" ] || die "$label: config.env 中未设置 sha256 pin"
  got=$(sha256_of "$f")
  [ "$got" = "$pin" ] || die "$label sha256 不符（want=$pin got=$got；升级后请同步更新 pin）"
  log "  sha256 ok（$label）"
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM（构建时统一清洗）
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

# ============================================================
# 阶段: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"

  # 缓存 tag 标记（变更即整体失效，防跨 tag 复用旧产物）
  if [ -f "$DL_DIR/.fetch.tag" ] && [ "$(cat "$DL_DIR/.fetch.tag")" != "$VERSION_FULL-$BUILD_MODE" ]; then
    warn "下载缓存 tag 变更，清空重建: $DL_DIR"
    rm -rf "$DL_DIR"
    mkdir -p "$DL_DIR"
  fi
  printf '%s' "$VERSION_FULL-$BUILD_MODE" > "$DL_DIR/.fetch.tag"

  if [ "$BUILD_MODE" = "source" ]; then
    # 1. 本仓库 CI 从上游源码构建的 Go 二进制（V6 审计链）
    fetch "$BIN_SOURCE_BASE/ytdlpwebui-linux-$GOARCH.tar.gz" "$DL_DIR/ytdlpwebui.tar.gz"
    fetch "$BIN_SOURCE_BASE/SHA256SUMS" "$DL_DIR/SHA256SUMS"
    # 2. CI 从 quickjs-ng 源码构建的 qjs
    fetch "$BIN_SOURCE_BASE/qjs-linux-$GOARCH.tar.gz" "$DL_DIR/qjs.tar.gz"

    log "校验 source 模式 sha256（对照 CI SHA256SUMS 与 config.env pin）..."
    local want got
    want=$(grep -a "[ /]ytdlpwebui-linux-$GOARCH.tar.gz\$" "$DL_DIR/SHA256SUMS" | tail -1 | awk '{print $1}')
    [ -n "$want" ] || die "SHA256SUMS 中找不到 ytdlpwebui-linux-$GOARCH.tar.gz"
    got=$(sha256_of "$DL_DIR/ytdlpwebui.tar.gz")
    [ "$got" = "$want" ] || die "ytdlpwebui 与 CI SHA256SUMS 不符（want=$want got=$got）"
    verify_sha256 "$DL_DIR/ytdlpwebui.tar.gz" "$PINNED_TARBALL" "ytdlpwebui config.env pin"

    want=$(grep -a "[ /]qjs-linux-$GOARCH.tar.gz\$" "$DL_DIR/SHA256SUMS" | tail -1 | awk '{print $1}')
    [ -n "$want" ] || die "SHA256SUMS 中找不到 qjs-linux-$GOARCH.tar.gz"
    got=$(sha256_of "$DL_DIR/qjs.tar.gz")
    [ "$got" = "$want" ] || die "qjs 与 CI SHA256SUMS 不符（want=$want got=$got）"
  else
    # compat 模式：上游官方预编译二进制 + quickjs-ng 官方 release 二进制
    warn "BUILD_MODE=compat：使用上游预编译二进制，仅供本地迭代；禁止提交商店（V6）"
    fetch "$UPSTREAM_BASE/yt-dlp-webui_linux-$GOARCH" "$DL_DIR/ytdlpwebui.bin"
    verify_sha256 "$DL_DIR/ytdlpwebui.bin" "$PINNED_UPSTREAM" "上游 yt-dlp-webui 二进制"
    fetch "$QJS_BASE/qjs-linux-$QJS_ARCH" "$DL_DIR/qjs.bin"
    verify_sha256 "$DL_DIR/qjs.bin" "$PINNED_QJS" "quickjs-ng qjs"
  fi

  # 3. yt-dlp 官方 Python zipapp（纯 .py 源码，可审计）
  fetch "$YTDLP_BASE/yt-dlp" "$DL_DIR/yt-dlp.zipapp"
  verify_sha256 "$DL_DIR/yt-dlp.zipapp" "$SHA256_YTDLP" "yt-dlp zipapp"

  # 4. 许可证（主程序 GPL-3.0；随包组件许可证，第三方文件可选）
  fetch "https://raw.githubusercontent.com/marcopiovanello/yt-dlp-web-ui/$TAG/LICENSE" "$DL_DIR/LICENSE-main"
  fetch_soft "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/LICENSE" "$DL_DIR/LICENSE-ytdlp"
  fetch_soft "https://raw.githubusercontent.com/quickjs-ng/quickjs/$QUICKJS_VERSION/LICENSE" "$DL_DIR/LICENSE-quickjs"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  [ -d "$DL_DIR" ] || die "缺少下载缓存，请先运行: ./build.sh fetch"

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin"
  mkdir -p "$APP/images/icons"
  mkdir -p "$APP/nginx"
  mkdir -p "$APP/init.d"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  mkdir -p "$STAGE_DIR/etc/systemd/system"

  # --- 1. Go 后端 ---
  log "  + bin/ytdlpwebui（$YTDLPWEBUI_VERSION，$BUILD_MODE 模式）"
  if [ "$BUILD_MODE" = "source" ]; then
    tar xzOf "$DL_DIR/ytdlpwebui.tar.gz" ytdlpwebui > "$APP/bin/ytdlpwebui"
  else
    cp "$DL_DIR/ytdlpwebui.bin" "$APP/bin/ytdlpwebui"
  fi
  chmod 0755 "$APP/bin/ytdlpwebui"

  # --- 2. quickjs 运行时 ---
  log "  + bin/qjs（quickjs-ng $QUICKJS_VERSION）"
  if [ "$BUILD_MODE" = "source" ]; then
    tar xzOf "$DL_DIR/qjs.tar.gz" qjs > "$APP/bin/qjs"
  else
    cp "$DL_DIR/qjs.bin" "$APP/bin/qjs"
  fi
  chmod 0755 "$APP/bin/qjs"

  # --- 3. yt-dlp zipapp ---
  log "  + bin/yt-dlp（$YTDLP_VERSION，Python zipapp）"
  cp "$DL_DIR/yt-dlp.zipapp" "$APP/bin/yt-dlp"
  chmod 0755 "$APP/bin/yt-dlp"

  # --- 4. config.ini（严格 JSON；@@...@@ 占位符渲染） ---
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # --- 5. 多语言文件（文件名必须等于 app id） ---
  log "  + $APP_ID.lang（23 语超集）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # --- 6. 应用配置（回环 + 端口 + 下载/JS 运行时路径） ---
  log "  + config.yml（默认配置，升级会覆盖；用户覆盖走 .env）"
  cp "$ASSETS_DIR/config.yml.in" "$APP/config.yml"

  # --- 7. 环境变量模板（首装复制为正式文件，升级不覆盖） ---
  log "  + $APP_ID.env.example"
  cp "$ASSETS_DIR/$APP_ID.env" "$APP/$APP_ID.env.example"

  # --- 8. 图标 ---
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # --- 9. nginx 路由（双落盘） ---
  log "  + nginx/ + /etc/nginx/conf.d/（127.0.0.1:$APP_PORT 回环反代，剥离前缀）"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$APP/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # --- 10. systemd 服务（双落盘） ---
  log "  + init.d/ + /etc/systemd/system/"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # --- 11. webui.bz2（WebUI 类应用必填；解压含可打开 .html） ---
  log "  + webui.bz2（占位前端，跳转 /$APP_ID/）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  # 坑 8：macOS 扩展属性会变成 AppleDouble ._ 条目打进归档；坑 46/S11：
  # 嵌套归档条目必须 root:root —— 用 python3 tarfile 跨平台归一化
  export COPYFILE_DISABLE=1
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYW'
import sys, tarfile
from pathlib import Path
src_dir, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:bz2") as tf:
    for p in sorted(Path(src_dir).iterdir()):
        ti = tf.gettarinfo(str(p), arcname=p.name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        if ti.isfile():
            with open(p, "rb") as f:
                tf.addfile(ti, f)
        else:
            tf.addfile(ti)
PYW

  # --- 12. 隐私政策（审核 C3） ---
  log "  + privacy-policy.html（双语隐私政策）"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"

  # --- 13. 溯源文档（坑 50：放应用目录，/usr/share/doc 会被 TOS dpkg 剥离） ---
  log "  + PROVENANCE.md（组件来源与构建方式）"
  python3 - "$ASSETS_DIR/PROVENANCE.md.in" "$APP/PROVENANCE.md" \
    "$VERSION_FULL" "$BUILD_MODE" "$YTDLPWEBUI_VERSION" "$YTDLP_VERSION" \
    "$QUICKJS_VERSION" "$TARGET_ARCH" <<'PYV'
import sys
src, dst, ver, mode, up, ytdlp, qjs, arch = sys.argv[1:9]
t = open(src, encoding="utf-8").read()
for k, v in {"@@VERSION@@": ver, "@@BUILD_MODE@@": mode, "@@UPSTREAM_VERSION@@": up,
             "@@YTDLP_VERSION@@": ytdlp, "@@QUICKJS_VERSION@@": qjs,
             "@@TARGET_ARCH@@": arch}.items():
    t = t.replace(k, v)
open(dst, "w", encoding="utf-8").write(t)
PYV

  # --- 14. 文档（只放版权/变更，doc 目录其余文件会被 TOS dpkg 剥离） ---
  cat "$DL_DIR/LICENSE-main" > "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo ""
    echo "Bundled third-party components:"
    echo "  - yt-dlp $YTDLP_VERSION (Python zipapp; Unlicense/ISC/MIT)"
    echo "  - quickjs-ng $QUICKJS_VERSION (MIT)"
    echo "  - ffmpeg: TOS system package (Depends: ffmpeg), not redistributed"
    echo ""
    echo "See /usr/local/$APP_ID/PROVENANCE.md for the full provenance table."
  } >> "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于上游 yt-dlp Web UI $YTDLPWEBUI_VERSION 打包（$BUILD_MODE 构建模式）"
    echo "  * 后端 Go 静态二进制 + 内嵌前端；随包 yt-dlp $YTDLP_VERSION 与 quickjs-ng $QUICKJS_VERSION"
    echo "  * WebUI External Open：新标签页经 /$APP_ID/ 路由访问，后端仅监听回环 127.0.0.1:$APP_PORT"
    echo "  * ffmpeg 使用 TOS 系统软件包（Depends: ffmpeg）"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # --- 15. 规范清洗：LF 行尾 + 去 BOM ---
  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" "$APP/config.yml" "$APP/$APP_ID.env.example" \
    "$APP/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
    "$APP/PROVENANCE.md" "$APP/privacy-policy.html" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"

  # --- 16. 清理 macOS 扩展属性 ---
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  # --- 17. 权限归一化（构建机 umask 差异不应影响包内权限） ---
  # 目录 0755；普通文件 0644（nginx worker 需读取 privacy-policy.html）；
  # 可执行载荷 0755。生命周期脚本由 makedeb.sh 单独置 0755。
  find "$STAGE_DIR" -type d -exec chmod 0755 {} +
  find "$STAGE_DIR" -type f -exec chmod 0644 {} +
  chmod 0755 "$APP/bin/ytdlpwebui" "$APP/bin/qjs" "$APP/bin/yt-dlp"

  log "组装完成"
}

# ============================================================
# 阶段: verify —— 目标架构与规范关键项校验
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/config.yml" "$APP/$APP_ID.env.example" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/$APP_ID.service" \
           "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/ytdlpwebui" "$APP/bin/qjs" "$APP/bin/yt-dlp" \
           "$APP/webui.bz2" "$APP/privacy-policy.html" "$APP/PROVENANCE.md" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id, app_user = sys.argv[1:6]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path 必须为 /{app_id}/")
if cfg.get("user") != app_user: errs.append(f"user 应为 {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
if cfg.get("beta") is not False: errs.append("beta 必须为 false")
for k in ("help", "official"):
    if not str(cfg.get(k, "")).startswith("https://github.com/"):
        errs.append(f"{k} 必须为 github.com 链接（机器验链）")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语节点 + 版本一致 + 无残留占位符）..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" "$VERSION_FULL" <<'PYEOF'
import sys
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
            "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se","th-th","vi-vn"]
text = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in required if f"[{t}]" not in text]
if f'version      = "{sys.argv[2]}"' not in text:
    missing.append(f"version != {sys.argv[2]}")
if "@@" in text:
    missing.append("残留 @@ 占位符")
if "beta" in text.lower():
    missing.append("lang 全文含 'beta'（V11 门禁）")
print(",".join(missing))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang 问题: $lang_missing"; fail=1; }

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开）..."
  local svc
  for svc in "$APP/init.d/"*.service "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（曾致全环境 502）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "必须 User=$APP_USER: $svc"; fail=1; }
    grep -q 'NoNewPrivileges=true' "$svc" || { warn "缺少 NoNewPrivileges: $svc"; fail=1; }
    grep -q 'CapabilityBoundingSet=' "$svc" || { warn "缺少 CapabilityBoundingSet: $svc"; fail=1; }
  done
  local n_units
  n_units=$(find "$APP/init.d" -name '*.service' | wc -l | tr -d ' ')
  [ "$n_units" = "1" ] || { warn "init.d/ 必须只放一个主服务单元（当前 $n_units 个）"; fail=1; }

  log "校验监听安全（config.yml + env 双保险均为回环/端口）..."
  grep -Eq "^  host: 127\.0\.0\.1" "$APP/config.yml" || { warn "config.yml 必须 host 127.0.0.1"; fail=1; }
  grep -Eq "^  port: $APP_PORT" "$APP/config.yml" || { warn "config.yml 必须 port $APP_PORT"; fail=1; }
  grep -q "^APP_SERVER_HOST=127\.0\.0\.1" "$APP/$APP_ID.env.example" \
    || { warn "env 必须含活动默认值 APP_SERVER_HOST=127.0.0.1"; fail=1; }
  grep -q "^APP_SERVER_PORT=$APP_PORT" "$APP/$APP_ID.env.example" \
    || { warn "env 必须含活动默认值 APP_SERVER_PORT=$APP_PORT"; fail=1; }
  grep -q "js_runtime_path: quickjs:/usr/local/$APP_ID/bin/qjs" "$APP/config.yml" \
    || { warn "config.yml 必须设置 quickjs JS 运行时路径"; fail=1; }
  grep -q "downloader_path: /usr/local/$APP_ID/bin/yt-dlp" "$APP/config.yml" \
    || { warn "config.yml 必须设置 yt-dlp 路径"; fail=1; }

  log "校验 nginx（剥离前缀转发 + WebSocket + 回环 + 隐私政策精确路由）..."
  grep -q "proxy_pass http://127.0.0.1:$APP_PORT/;" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 必须剥离前缀转发到 127.0.0.1:$APP_PORT/"; fail=1; }
  grep -q 'proxy_set_header Upgrade' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 WebSocket 升级头"; fail=1; }
  grep -q 'absolute_redirect off;' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 absolute_redirect off（301 丢端口坑）"; fail=1; }
  grep -q "location = /$APP_ID/privacy-policy.html" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺隐私政策精确路由"; fail=1; }

  log "校验图标（SVG + viewBox + ≤50KB + 节点≤50 + 无 filter/use/metadata）..."
  python3 - "$APP/images/icons/$APP_ID.svg" <<'PYI' || fail=1
import sys, re
import xml.etree.ElementTree as ET
p = sys.argv[1]
data = open(p, "rb").read()
errs = []
if len(data) > 50 * 1024:
    errs.append(f"体积超 50KB: {len(data)}")
text = data.decode("utf-8")
try:
    root = ET.fromstring(text)
except ET.ParseError as e:
    errs.append(f"XML 非法: {e}")
    root = None
if root is not None:
    if "viewBox" not in root.attrib:
        errs.append("缺 viewBox")
    nodes = list(root.iter())
    if len(nodes) > 50:
        errs.append(f"节点数 {len(nodes)} > 50")
    if not re.search(r'fill="#[0-9a-fA-F]{3,8}"', text):
        errs.append("无填充色")
for bad in ("filter", "use", "namedview", "metadata", "sodipodi", "inkscape"):
    if bad in text:
        errs.append(f"含禁用元素 {bad}")
for e in errs:
    print(f"    icon: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYI

  log "校验 webui.bz2（解压含 .html / 条目属主 root:root / 无 ._ 污染）..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 缺少 html"; fail=1; }
  if tar tjf "$APP/webui.bz2" | grep -qE '(^|/)\._'; then
    warn "webui.bz2 含 AppleDouble ._ 垃圾条目（macOS 污染）"; fail=1
  fi
  python3 - "$APP/webui.bz2" <<'PYW2' || fail=1
import sys, tarfile
with tarfile.open(sys.argv[1], "r:bz2") as tf:
    bad = [m.name for m in tf.getmembers() if m.uid != 0 or m.gid != 0]
    if bad:
        print(f"S11: webui.bz2 存在非 root 属主条目: {bad}")
        sys.exit(1)
PYW2

  log "校验随包 ELF（架构 / 静态 / 非 UPX / 无 Mach-O 混入）..."
  local f elfinfo
  for f in "$APP/bin/ytdlpwebui" "$APP/bin/qjs"; do
    elfinfo=$(file "$f")
    if echo "$elfinfo" | grep -q "ELF.*$ELF_ARCH"; then
      log "  ok 架构: $(basename "$f")"
    else
      warn "错误架构: ${f#$STAGE_DIR/} -> $elfinfo"; fail=1
    fi
    if echo "$elfinfo" | grep -q "no section header"; then
      warn "无 section header（UPX 加壳特征，V6 一票否决项！）: $elfinfo"; fail=1
    fi
  done
  # Go 二进制必须静态（musl/纯静态），qjs 允许 static-pie
  if file "$APP/bin/ytdlpwebui" | grep -q "statically linked"; then
    log "  ok ytdlpwebui 静态链接"
  else
    warn "ytdlpwebui 非静态链接（V6 要求）: $(file "$APP/bin/ytdlpwebui")"; fail=1
  fi

  log "校验 yt-dlp 载荷（必须是可审计的 Python zipapp，不得是 ELF）..."
  if file "$APP/bin/yt-dlp" | grep -q "ELF"; then
    warn "bin/yt-dlp 是 ELF 二进制（V6 风险）：应使用官方 Python zipapp"; fail=1
  fi
  head -c 2 "$APP/bin/yt-dlp" | grep -q '#!' || { warn "bin/yt-dlp 缺 shebang"; fail=1; }
  python3 - "$APP/bin/yt-dlp" <<'PYZ' || fail=1
import sys, zipfile
if not zipfile.is_zipfile(sys.argv[1]):
    print("bin/yt-dlp 不是 zipapp", file=sys.stderr)
    sys.exit(1)
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    if not any(n.startswith("yt_dlp/") for n in names):
        print("bin/yt-dlp 缺少 yt_dlp 包", file=sys.stderr)
        sys.exit(1)
    if not any(n.endswith("__main__.py") or n == "__main__.py" for n in names):
        print("bin/yt-dlp 缺少 __main__.py", file=sys.stderr)
        sys.exit(1)
PYZ

  log "S8 零在线安装自检（deb 脚本不得出现 pip/curl/apt install 等）..."
  local sc
  for sc in "$ASSETS_DIR/preinst" "$ASSETS_DIR/postinst" "$ASSETS_DIR/prerm" "$ASSETS_DIR/postrm"; do
    if grep -vE '^\s*#' "$sc" | grep -Eq '(pip[0-9]? install|apt(-get)? install|curl .*\| *(ba)?sh|wget .*\| *(ba)?sh|urlopen|--index-url)'; then
      warn "S8: $sc 含在线安装/下载迹象"; fail=1
    fi
  done

  log "检查 macOS Mach-O 混入（应为 0）..."
  local n_macho
  n_macho=$(find "$STAGE_DIR" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件！"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  cp "$DEB_FILE" "$STORE_DEB"
  sha256_of "$STORE_DEB" | awk -v f="$(basename "$STORE_DEB")" '{print $1"  "f}' > "$STORE_DEB.sha256"
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_info() {
  cat <<EOF
yt-dlp Web UI  : $YTDLPWEBUI_VERSION (完整版本 $VERSION_FULL)
目标架构       : $TARGET_ARCH (TOS:$TOS_PLATFORM)
构建模式       : $BUILD_MODE（source=可提交；compat=仅本地迭代）
TOS app id     : $APP_ID（新标签页 /$APP_ID/，后端 127.0.0.1:$APP_PORT）
随包运行时     : yt-dlp $YTDLP_VERSION + quickjs-ng $QUICKJS_VERSION
外部依赖       : python3, ffmpeg（TOS 系统包）
产物           : $DEB_FILE
上架资产       : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "已清理 stage（保留下载缓存）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存"
}

# ============================================================
# 入口
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info）" ;;
esac
