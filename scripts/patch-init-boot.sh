#!/usr/bin/env bash
# patch-init-boot.sh — 用官方 ksud 给原厂 init_boot.img 打 KernelSU 补丁
#
# ksud boot-patch 对 init_boot ramdisk 做的事（官方行为）：
#   - 原 init 改名 init.real，ksuinit 写成新的 init（开机先跑它）；
#   - 把对应 KMI 的 kernelsu.ko 写进 ramdisk，ksuinit 开机时 insmod；
#   - 写 ksu_config 配置文件。
# 完成后不需要管理器 App 再安装一次 LKM。
#
# 用法：
#   ./patch-init-boot.sh --init-boot work/SM-S918N/init_boot.img \
#       --kmi android13-5.15 --ksud ksud --module kernelsu.ko \
#       --out work/SM-S918N/init_boot-patched.img
#
# --module 可省略：省略时用 ksud 自带的对应 KMI 的内置模块。
# 产出校验：确认产出是合法 Android boot 镜像，且 ramdisk 里确实含 kernelsu.ko。
set -euo pipefail

INIT_BOOT=""
KMI="android13-5.15"
KSUD=""
MODULE=""
OUT=""

die() { echo "patch-init-boot: ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-boot) INIT_BOOT="$2"; shift 2 ;;
    --kmi)       KMI="$2"; shift 2 ;;
    --ksud)      KSUD="$2"; shift 2 ;;
    --module)    MODULE="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$INIT_BOOT" ]] || die "--init-boot 必填"
[[ -n "$KSUD" ]]      || die "--ksud 必填（官方 KernelSU Release 的 ksud 二进制）"
[[ -n "$OUT" ]]       || die "--out 必填"
[[ -f "$INIT_BOOT" ]] || die "原厂 init_boot.img 不存在：$INIT_BOOT"
[[ -x "$KSUD" ]]      || die "ksud 不可执行：$KSUD"
if [[ -n "$MODULE" ]]; then [[ -f "$MODULE" ]] || die "kernelsu.ko 不存在：$MODULE"; fi

# 幂等保护：如果输入已经打过补丁，ksud 会拒绝重复打，直接报错退出，
# 避免把 init 埋深一层。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARGS=("$KSUD" boot-patch -b "$INIT_BOOT" --kmi "$KMI" -o "$WORK")
[[ -n "$MODULE" ]] && ARGS+=(-m "$MODULE")

echo "patch-init-boot: 执行：${ARGS[*]}"
"${ARGS[@]}" || die "ksud boot-patch 失败"

# ksud 把产出写到 -o 指定的目录，文件名一般为 kernelsu_patched*.img
PRODUCED="$(find "$WORK" -maxdepth 1 -type f -name '*.img' | head -n 1)"
[[ -n "$PRODUCED" ]] || die "ksud 未产出打好补丁的镜像（-o 目录为空）"
cp "$PRODUCED" "$OUT"

# --- 校验 1：合法 Android boot 镜像（ANDROID! magic）---
if ! python3 - "$OUT" <<'EOF'
import sys
with open(sys.argv[1], "rb") as f:
    magic = f.read(8)
sys.exit(0 if magic == b"ANDROID!" else 1)
EOF
then
  die "产出不是合法 Android boot 镜像：$OUT"
fi

# --- 校验 2：ramdisk 里确实含 kernelsu.ko ---
# 用 magiskboot 解包产出镜像，再用 cpio 列出 ramdisk 内容；没有 magiskboot
# 时退化为在镜像字节里搜索 kernelsu.ko 字符串（弱校验，仅作兜底）。
if command -v magiskboot >/dev/null 2>&1; then
  CHECK="$(mktemp -d)"
  trap 'rm -rf "$WORK" "$CHECK"' EXIT
  cp "$OUT" "$CHECK/init_boot.img"
  (cd "$CHECK" && magiskboot unpack init_boot.img >/dev/null) || die "校验：产出的 init_boot.img 无法解包"
  if [[ -f "$CHECK/ramdisk.cpio" ]]; then
    if command -v cpio >/dev/null 2>&1; then
      cpio -it < "$CHECK/ramdisk.cpio" 2>/dev/null | grep -qx "kernelsu.ko" \
        || die "校验：打补丁后的 ramdisk 里没有 kernelsu.ko"
    else
      grep -aq "kernelsu.ko" "$CHECK/ramdisk.cpio" || die "校验：ramdisk 里没有 kernelsu.ko"
    fi
  else
    grep -aq "kernelsu.ko" "$OUT" || die "校验：镜像里没有 kernelsu.ko"
  fi
else
  grep -aq "kernelsu.ko" "$OUT" || die "校验：镜像里没有 kernelsu.ko（弱校验）"
fi

echo "patch-init-boot: 完成并校验通过：$OUT（KMI=$KMI）"
