#!/usr/bin/env bash
# build-boot.sh — 把原厂 boot.img 里的内核换成 Faiz 内核
#
# 做法：magiskboot 解包原厂 boot.img → 把 kernel 段替换为 Faiz Image →
# 打包回 boot.img。ramdisk、cmdline、DTB 等其余部分原样保留。
#
# 用法：
#   ./build-boot.sh --stock-boot work/SM-S918N/boot.img \
#       --kernel Image --out work/SM-S918N/boot-patched.img \
#       [--magiskboot /path/to/magiskboot]
#
# magiskboot 获取：优先用系统里的；没有时自动从官方 Magisk APK 里提取
# libmagiskboot.so（https://github.com/topjohnwu/Magisk/releases）。
# 获取失败就直接报错退出，不用 ksud 兜底——ksud boot-patch 往 boot.img
# 里塞 KernelSU LKM 并新建 ramdisk，不是纯换内核，语义不对。
set -euo pipefail

STOCK_BOOT=""
KERNEL=""
OUT=""
MAGISKBOOT="${MAGISKBOOT:-}"

die() { echo "build-boot: ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stock-boot) STOCK_BOOT="$2"; shift 2 ;;
    --kernel)     KERNEL="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --magiskboot) MAGISKBOOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$STOCK_BOOT" ]] || die "--stock-boot 必填"
[[ -n "$KERNEL" ]]     || die "--kernel 必填（Faiz 内核 Image）"
[[ -n "$OUT" ]]        || die "--out 必填"
[[ -f "$STOCK_BOOT" ]] || die "原厂 boot.img 不存在：$STOCK_BOOT"
[[ -f "$KERNEL" ]]     || die "Faiz 内核不存在：$KERNEL"

# 注意：下面脚本会 cd 进临时目录再操作，相对路径会失效（2026-11-09
# 第 8 次构建就栽在这里：cd 后 cp new-boot.img 到相对路径的 $OUT，
# 报错 No such file or directory）。所以先全部转成绝对路径。
STOCK_BOOT="$(realpath -m "$STOCK_BOOT")"
KERNEL="$(realpath -m "$KERNEL")"
OUT="$(realpath -m "$OUT")"

# --- 校验 Faiz 内核是未压缩 ARM64 Image（magic "ARMd" 在偏移 0x38 处）---
if ! python3 - "$KERNEL" <<'EOF'
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(0x38)
    magic = f.read(4)
sys.exit(0 if magic == b"ARMd" else 1)
EOF
then
  die "内核文件不是 ARM64 Image（偏移 0x38 处没有 ARMd magic）：$KERNEL"
fi
echo "build-boot: Faiz 内核校验通过（ARM64 Image）"

# --- 找 magiskboot ---
# 三种方式按顺序尝试（2026-11-09 第 6 次构建教训：只靠未认证的
# GitHub API 会在偶发情况下返回无 .apk 资产的 JSON，导致 IndexError；
# 而 ksud 备选方案不能用——ksud boot-patch 往 boot.img 里塞 KernelSU
# LKM 并新建 ramdisk，不是纯换内核，语义不对，故已删掉该备选）：
#   1. gh（Runner 自带认证，配额高，最稳）
#   2. GitHub API + curl（未认证，可能限流）
#   3. 固定版本直链 v29.0
get_magiskboot() {
  if [[ -n "$MAGISKBOOT" && -x "$MAGISKBOOT" ]]; then echo "$MAGISKBOOT"; return 0; fi
  if command -v magiskboot >/dev/null 2>&1; then command -v magiskboot; return 0; fi
  echo "build-boot: 未找到 magiskboot，从官方 Magisk APK 提取 ..." >&2
  local tmp apk
  tmp="$(mktemp -d)"
  apk="$tmp/Magisk.apk"
  # 方法 1：gh
  if command -v gh >/dev/null 2>&1; then
    if (cd "$tmp" && gh release download --repo topjohnwu/Magisk --pattern 'Magisk-v*.apk' >/dev/null 2>&1); then
      apk="$(ls "$tmp"/Magisk-v*.apk 2>/dev/null | head -n 1)"
      [[ -n "$apk" ]] || apk="$tmp/Magisk.apk"
    fi
  fi
  # 方法 2：GitHub API + curl（assets 为空时不报错，继续往下走）
  if [[ ! -f "$apk" ]]; then
    local url
    url="$(curl -fsSL "https://api.github.com/repos/topjohnwu/Magisk/releases/latest" 2>/dev/null \
      | python3 -c "import sys, json; print([a['browser_download_url'] for a in json.load(sys.stdin).get('assets', []) if a['name'].startswith('Magisk-v') and a['name'].endswith('.apk')][0])" 2>/dev/null)" || url=""
    if [[ -n "$url" ]]; then
      curl -fsSL -o "$apk" "$url" 2>/dev/null || rm -f "$apk"
    fi
  fi
  # 方法 3：固定版本直链
  if [[ ! -f "$apk" ]]; then
    echo "build-boot: gh 与 API 均未取到 APK，尝试固定版本 v29.0 直链 ..." >&2
    curl -fsSL -o "$apk" "https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk" 2>/dev/null || rm -f "$apk"
  fi
  [[ -f "$apk" ]] || { echo "build-boot: 三种方式都未取到 Magisk APK" >&2; rm -rf "$tmp"; return 1; }
  unzip -o -q "$apk" 'lib/x86_64/libmagiskboot.so' -d "$tmp" || { rm -rf "$tmp"; return 1; }
  cp "$tmp/lib/x86_64/libmagiskboot.so" "$tmp/magiskboot"
  chmod +x "$tmp/magiskboot"
  echo "$tmp/magiskboot"
}

MB="$(get_magiskboot)" || die "无法获取 magiskboot，无法替换内核（已尝试 gh / GitHub API / v29.0 直链）"
echo "build-boot: magiskboot = $MB"

# --- 解包、换内核、打包 ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$STOCK_BOOT" "$WORK/boot.img"
cp "$KERNEL" "$WORK/Image"

cd "$WORK"
"$MB" unpack boot.img || die "magiskboot 解包原厂 boot.img 失败"
[[ -f kernel ]] || die "解包后没有 kernel 文件，boot.img 格式异常"
echo "build-boot: 原厂 kernel 大小 $(stat -c%s kernel) 字节 → 换成 Faiz Image $(stat -c%s Image) 字节"
cp Image kernel
"$MB" repack boot.img || die "magiskboot 打包失败"
[[ -f new-boot.img ]] || die "打包后没有 new-boot.img"
cp new-boot.img "$OUT"

# --- 校验产出：重新解包一次，确认内核确实是 Faiz 内核 ---
CHECK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$CHECK"' EXIT
cp "$OUT" "$CHECK/boot.img"
cd "$CHECK"
"$MB" unpack boot.img >/dev/null || die "校验：产出的 boot.img 无法解包"
if ! python3 - kernel <<'EOF'
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(0x38)
    magic = f.read(4)
sys.exit(0 if magic == b"ARMd" else 1)
EOF
then
  die "校验：产出的 boot.img 里内核不是 ARM64 Image"
fi
echo "build-boot: 完成并校验通过：$OUT"
