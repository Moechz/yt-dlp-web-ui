# Makefile - 便捷入口（实际逻辑都在 build.sh）
.PHONY: all fetch stage verify deb clean distclean info check amd64 arm64 aarch64 source compat

all: package

package:
	./build.sh

fetch:
	./build.sh fetch

stage:
	./build.sh stage

verify:
	./build.sh verify

deb:
	./build.sh deb

clean:
	./build.sh clean

distclean:
	./build.sh distclean

info:
	./build.sh info

# 语法检查 + 资产静态自检
check:
	sh -n makedeb.sh
	bash -n build.sh
	bash -n assets/preinst
	bash -n assets/postinst
	bash -n assets/prerm
	bash -n assets/postrm
	python3 -c "import json; json.load(open('assets/config.ini.in'))"
	python3 scripts/check_assets.py
	@echo "语法检查通过"

# 架构切换（make arm64 / make aarch64）
arm64:
	TARGET_ARCH=arm64 ./build.sh
aarch64: arm64
amd64:
	TARGET_ARCH=amd64 ./build.sh

# 构建模式：source=可提交商店；compat=本地迭代
source:
	BUILD_MODE=source ./build.sh
compat:
	BUILD_MODE=compat ./build.sh
