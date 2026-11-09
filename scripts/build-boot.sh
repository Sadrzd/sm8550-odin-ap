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
# 备选：如果 magiskboot 不可用，可用 ksud boot-patch -b boot.img -k Image
# 完成同样操作（ksud 自带 boot 镜像解析），见 KSUD_FALLBACK。
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
get_magiskboot() {
  if [[ -n "$MAGISKBOOT" && -x "$MAGISKBOOT" ]]; then echo "$MAGISKBOOT"; return 0; fi
  if command -v magiskboot >/dev/null 2>&1; then command -v magiskboot; return 0; fi
  echo "build-boot: 未找到 magiskboot，从官方 Magisk APK 提取 ..." >&2
  local tmp apk
  tmp="$(mktemp -d)"
  apk="$tmp/magisk.apk"
  local api="https://api.github.com/repos/topjohnwu/Magisk/releases/latest"
  local url
  url="$(curl -fsSL "$api" | python3 -c "import sys, json; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'] == 'Magisk.apk'][0])")" \
    || { rm -rf "$tmp"; return 1; }
  curl -fsSL -o "$apk" "$url" || { rm -rf "$tmp"; return 1; }
  unzip -o -q "$apk" 'lib/x86_64/libmagiskboot.so' -d "$tmp" || { rm -rf "$tmp"; return 1; }
  cp "$tmp/lib/x86_64/libmagiskboot.so" "$tmp/magiskboot"
  chmod +x "$tmp/magiskboot"
  echo "$tmp/magiskboot"
}

MB="$(get_magiskboot)" || {
  echo "build-boot: 无法获取 magiskboot，改用 ksud 备选方案（需要 KSUD 环境变量指向 ksud 二进制）" >&2
  [[ -n "${KSUD:-}" && -x "$KSUD" ]] || die "magiskboot 和 ksud 都不可用，无法继续"
  echo "build-boot: 用 ksud boot-patch -k 替换内核 ..."
  "$KSUD" boot-patch -b "$STOCK_BOOT" -k "$KERNEL" -o "$(dirname "$OUT")" \
    || die "ksud 替换内核失败"
  local produced
  produced="$(find "$(dirname "$OUT")" -maxdepth 1 -name 'kernelsu_patched*' -o -maxdepth 1 -name 'new-boot.img' | head -n 1)"
  [[ -n "$produced" ]] || die "ksud 未产出替换后的 boot.img"
  mv "$produced" "$OUT"
  echo "build-boot: 完成（ksud 备选方案）：$OUT"
  exit 0
}
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
