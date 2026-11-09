#!/usr/bin/env bash
# pack-ap.sh — 把处理好的分区镜像打成 Odin 可用的 AP_*.tar.md5
#
# 三星 lz4 格式要求（Odin 认的才算）：
#   必须用 lz4 -B6 --content-size 压缩，产出文件的 magic 须以
#   04 22 4d 18 6c 开头（其中 6c 即 --content-size 标志），
#   否则 Odin 报 "LZ4 is invalid"。
#
# AP tar 要求：
#   普通 ustar 格式；tar.md5 是在 tar 末尾追加一行
#   "<md5>  <文件名>"（md5sum 的输出）后改名。
#   AP 里只放 boot / init_boot / vbmeta*，绝不放 CSC / BL / CP，
#   绝不做 repartition。
#
# 用法：
#   ./pack-ap.sh --dir work/SM-S918N/ap \
#       --out out/AP_SM-S918N_FZDP_Faiz_ksu3.3.1.tar.md5
#   其中 --dir 里应有：boot.img、init_boot.img，
#   以及可选的 vbmeta.img、vbmeta_system.img、vbmeta_vendor.img。
set -euo pipefail

DIR=""
OUT=""

die() { echo "pack-ap: ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$DIR" ]] || die "--dir 必填（放有待打包镜像的目录）"
[[ -n "$OUT" ]] || die "--out 必填（输出的 AP_*.tar.md5 路径）"
[[ -f "$DIR/boot.img" ]]      || die "缺少 boot.img：$DIR"
[[ -f "$DIR/init_boot.img" ]] || die "缺少 init_boot.img：$DIR"

# 注意：下面打包时要 cd 进临时目录，相对路径会失效（2026-11-09
# 第 9 次构建就栽在这里：cd 后 tar 写相对路径的 $TAR，
# 报错 Cannot open: No such file or directory）。先转成绝对路径。
DIR="$(realpath -m "$DIR")"
OUT="$(realpath -m "$OUT")"

command -v lz4 >/dev/null 2>&1 || die "未找到 lz4，请安装（apt install liblz4-tool / lz4）"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 逐个压缩，并校验三星 lz4 magic（04 22 4d 18 6c）---
for img in boot.img init_boot.img vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
  [[ -f "$DIR/$img" ]] || continue
  echo "pack-ap: 压缩 $img ..."
  lz4 -B6 --content-size -f "$DIR/$img" "$WORK/$img.lz4" || die "lz4 压缩 $img 失败"
  MAGIC="$(xxd -p -l 5 "$WORK/$img.lz4")"
  [[ "$MAGIC" == "04224d186c" ]] || die "$img.lz4 的 magic 不是 04224d186c（实际 $MAGIC），Odin 会报 LZ4 is invalid"
done

mkdir -p "$(dirname "$OUT")"
TAR="${OUT%.md5}"  # 先写成 .tar，再追加 md5 行后改名
# 只打包 .lz4 文件；用 ustar 格式；文件名排序固定，保证可复现
# 注意：成员名不要带 ./ 前缀——三星原厂 tar 和 Fede2782 的发布文件里
# 成员都是 boot.img.lz4 / init_boot.img.lz4，带 ./ 会让 verify-ap.sh
# 的白名单认不出来（2026-11-09 对照参考实现时发现的未爆弹）。
(cd "$WORK" && tar --format=ustar --sort=name -cf "$TAR" *.img.lz4) \
  || die "打包 tar 失败"
# 追加 md5 行：md5sum 输出格式 "<md5>  <文件名>"，Odin 靠它校验
(cd "$(dirname "$TAR")" && md5sum "$(basename "$TAR")" >> "$(basename "$TAR")") \
  || die "追加 md5 失败"
mv "$TAR" "$OUT"

echo "pack-ap: 完成：$OUT（$(stat -c%s "$OUT") 字节）"
# 文件尾已追加 md5 行，tar 读到尾部会报多余数据，忽略该警告只列内容
tar -tf "$OUT" 2>/dev/null | sed 's/^/pack-ap:   /' || true
