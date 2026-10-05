#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（make check 调用）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后）
  2. assets/ytdlpwebui.lang 含 23 语节点、无残留 @@ 占位符、无 beta 字样
  3. assets/ 下所有文本资产无 CRLF / BOM
  4. 图标 SVG 合法：XML 可解析、viewBox 存在、≤50KB、节点≤50、
     无 filter/use/metadata/sodipodi/inkscape
  5. 生命周期脚本无在线安装迹象（S8 红线）
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt",
                  "ar-sa", "cs-cz", "he-il", "id-id", "nb-no", "nl-nl", "sv-se",
                  "th-th", "vi-vn"]

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64"))
try:
    cfg = json.loads(rendered)
    print("config.ini.in: JSON 合法 ✓")
    for k in ("help", "official"):
        if not str(cfg.get(k, "")).startswith("https://github.com/"):
            print(f"config.ini.in: {k} 必须是 github.com 链接 ✗")
            fail = 1
    if cfg.get("beta") is not False:
        print("config.ini.in: beta 必须为 false ✗")
        fail = 1
    if "type" in cfg:
        print("config.ini.in: External Open 模式下不得有 type 字段 ✗")
        fail = 1
except Exception as e:  # noqa: BLE001
    print(f"config.ini.in: JSON 非法 ✗ ({e})")
    fail = 1

# ---------- 2. lang ----------
lang_path = ROOT / "assets/ytdlpwebui.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    print("lang: 含 BOM ✗")
    fail = 1
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    print(f"lang: 缺少语言节 ✗ {missing}")
    fail = 1
else:
    print(f"lang: {len(REQUIRED_LANGS)} 语言齐全 ✓（共 {len(found)} 节）")
if "@@" in text.replace("@@VERSION@@", ""):
    print("lang: 含非 VERSION 的 @@ 占位符 ✗")
    fail = 1
if re.search(r"\bbeta\b", text, re.I):
    print("lang: 含 'beta' 字样（V11 门禁）✗")
    fail = 1

# ---------- 3. CRLF / BOM 扫描 ----------
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".svg", ".md", ".yml", ".yaml"}:
        continue
    b = p.read_bytes()
    rel = p.relative_to(ROOT)
    if b.startswith(b"\xef\xbb\xbf"):
        print(f"{rel}: 含 BOM ✗")
        fail = 1
    if b"\r\n" in b or b"\r" in b:
        print(f"{rel}: 含 CR ✗")
        fail = 1

# ---------- 4. 图标 SVG ----------
icon_path = ROOT / "assets/images/icons/ytdlpwebui.svg"
try:
    icon_bytes = icon_path.read_bytes()
    icon_text = icon_bytes.decode("utf-8")
    root = ET.fromstring(icon_text)
    problems = []
    if len(icon_bytes) > 50 * 1024:
        problems.append(f"体积 {len(icon_bytes)} > 50KB")
    if "viewBox" not in root.attrib:
        problems.append("缺 viewBox")
    if len(list(root.iter())) > 50:
        problems.append(f"节点数 {len(list(root.iter()))} > 50")
    if not re.search(r'fill="#[0-9a-fA-F]{3,8}"', icon_text):
        problems.append("无填充色")
    for bad in ("filter", "use", "namedview", "metadata", "sodipodi", "inkscape"):
        if bad in icon_text:
            problems.append(f"含禁用元素 {bad}")
    if problems:
        print(f"icon: {'; '.join(problems)} ✗")
        fail = 1
    else:
        print(f"icon: 合法 ✓（{len(icon_bytes)}B, {len(list(root.iter()))} 节点）")
except ET.ParseError as e:
    print(f"icon: SVG 非法 XML（截断/损坏）✗ ({e})")
    fail = 1

# ---------- 5. S8：生命周期脚本无在线安装 ----------
for name in ("preinst", "postinst", "prerm", "postrm"):
    p = ROOT / "assets" / name
    body = "\n".join(l for l in p.read_text(encoding="utf-8").splitlines()
                     if not l.strip().startswith("#"))
    if re.search(r"(pip[0-9]? install|apt(-get)? install|curl .*\| *(ba)?sh|wget .*\| *(ba)?sh|urlopen|--index-url)", body):
        print(f"{name}: 含在线安装/下载迹象（S8）✗")
        fail = 1
print("S8 脚本扫描: 完成 ✓" if fail == 0 else "S8 脚本扫描: 有问题（见上）")

sys.exit(fail)
