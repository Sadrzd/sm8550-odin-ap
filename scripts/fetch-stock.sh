#!/usr/bin/env bash
# fetch-stock.sh — 获取指定机型/渠道的原厂底包（boot/init_boot/vbmeta/vbmeta_system）
#
# 来源（按优先级）：
# 1. SamLoader-RS 从三星 FUS 服务器下载最新固件（不需要 IMEI），
# 解密解压后提取需要的分区镜像。
# 2. 用户提供的底包目录（--base-dir）：里面已有 boot.img / init_boot.img /
# vbmeta.img / vbmeta_system.img。
#
# 用法：
#./fetch-stock.sh --model SM-S918N --region KOO --out work/SM-S918N \
# [--base-dir base-images/SM-S918N] [--pda S918NKSU8GYJ1]
# [--skip-vbmeta]
#
# --skip-vbmeta：不要求 vbmeta.img（韩版 SM-S918N 的 AP 不考虑 vbmeta，
# 只需要 boot.img + init_boot.img）。国行等需要处理 vbmeta 的 build 不要加。
#
# 输出：$OUT/boot.img $OUT/init_boot.img $OUT/vbmeta.img
# $OUT/vbmeta_system.img（若原厂包里有；没有则跳过，不报错）
# 以及 $OUT/stock-info.json（记录来源、PDA、SHA256）
#
# 注意：整包固件约 8 GB，下载+解压峰值磁盘占用约 20 GB。
# 调用方（CI）必须先释放磁盘空间，并在提取完成后删除中间文件。
set -euo pipefail

MODEL=""
REGION=""
OUT=""
BASE_DIR=""
PDA=""
SKIP_VBMETA=0

die() { echo "fetch-stock: ERROR: $*" >&2; exit 1;}
warn() { echo "fetch-stock: WARNING: $*" >&2;}

while [[ $# -gt 0 ]]; do
case "$1" in
--model) MODEL="$2"; shift 2;;
--region) REGION="$2"; shift 2;;
--out) OUT="$2"; shift 2;;
--base-dir) BASE_DIR="$2"; shift 2;;
--pda) PDA="$2"; shift 2;;
--skip-vbmeta) SKIP_VBMETA=1; shift;;
-h|--help) sed -n '2,20p' "$0"; exit 0;;
*) die "未知参数：$1";;
esac
done

[[ -n "$MODEL" ]] || die "--model 必填，如 SM-S918N"
[[ -n "$REGION" ]] || die "--region 必填，如 KOO"
[[ -n "$OUT" ]] || die "--out 必填"
mkdir -p "$OUT"

need_imgs=(boot.img init_boot.img)
# 国行等需要处理 vbmeta 的 build 才要求 vbmeta.img；韩版（--skip-vbmeta）不需要。
[[ "$SKIP_VBMETA" == "1" ]] || need_imgs+=(vbmeta.img)

have_all() {
for f in "${need_imgs[@]}"; do [[ -f "$OUT/$f" ]] || return 1; done
return 0
}

write_stock_info() { # $1=来源 $2=PDA
local source="$1" pda="$2"
python3 - "$OUT" "$MODEL" "$REGION" "$pda" "$source" <<'EOF'
import hashlib, json, os, sys
out, model, region, pda, source = sys.argv[1:6]
info = {"source": source, "model": model, "region": region, "pda": pda, "files": {}}
for name in sorted(os.listdir(out)):
p = os.path.join(out, name)
if os.path.isfile(p) and name.endswith(".img"):
h = hashlib.sha256()
with open(p, "rb") as f:
for chunk in iter(lambda: f.read(1 << 20), b""):
h.update(chunk)
info["files"][name] = {"sha256": h.hexdigest(), "size": os.path.getsize(p)}
with open(os.path.join(out, "stock-info.json"), "w") as f:
json.dump(info, f, indent=2)
print("fetch-stock: 已记录", os.path.join(out, "stock-info.json"))
EOF
}

# ---------- 备用方案：用户提供的底包 ----------
# 仅在 SamLoader-RS 下载失败时调用；不作为默认来源。
use_base_dir() {
[[ -n "$BASE_DIR" && -d "$BASE_DIR" ]] || return 1
echo "fetch-stock: 下载失败，改用用户提供的备用底包：$BASE_DIR"
local missing=()
for f in "${need_imgs[@]}"; do
if [[ -f "$BASE_DIR/$f" ]]; then cp "$BASE_DIR/$f" "$OUT/$f"; else missing+=("$f"); fi
done
[[ -f "$BASE_DIR/vbmeta_system.img" ]] && cp "$BASE_DIR/vbmeta_system.img" "$OUT/vbmeta_system.img" || true
[[ -f "$BASE_DIR/vbmeta_vendor.img" ]] && cp "$BASE_DIR/vbmeta_vendor.img" "$OUT/vbmeta_vendor.img" || true
if [[ ${#missing[@]} -gt 0 ]]; then
echo "fetch-stock: 备用底包缺少：${missing[*]}（必需：${need_imgs[*]}）" >&2
return 1
fi
write_stock_info "user-provided-fallback" "${PDA:-unknown}"
echo "fetch-stock: 底包就绪（用户提供的备用底包）。"
return 0
}

# ---------- 首选：SamLoader-RS 下载 ----------
# 注意：当前版 samloader-rs（topjohnwu/samloader-rs，2026 年重构后）
# 的 --model/--region 不是全局参数，而是 check-update / download
# 各子命令自己的参数，必须放在子命令后面：
#   samloader check-update --model SM-S918N --region KOO
#   samloader download --model SM-S918N --region KOO --out-dir DIR
# 放在子命令前面（samloader --model ... check-update）会被 clap 拒绝：
#   error: unexpected argument '--model' found
# check-update 只打印一行最新版本号，格式为 PDA/CSC/MODEM（如
# S918NKSU8GYJ1/S918NOKR8GYJ1/S918NKSU8GYJ1），PDA 取第一段。
echo "fetch-stock: 从三星服务器下载 $MODEL / $REGION 的最新固件（SamLoader-RS，无需 IMEI）"

if ! command -v samloader >/dev/null 2>&1; then
if command -v cargo >/dev/null 2>&1; then
echo "fetch-stock: 未找到 samloader，尝试 cargo install samloader..."
if ! cargo install samloader; then
warn "安装 samloader 失败"
use_base_dir && exit 0
die "安装 samloader 失败；请预装 samloader（topjohnwu/samloader-rs）后重试，或用 --base-dir 提供备用底包"
fi
else
warn "未找到 samloader，且无 cargo 可安装"
use_base_dir && exit 0
die "未找到 samloader。请安装 topjohnwu/samloader-rs 的预编译版：https://github.com/topjohnwu/samloader-rs/releases，或用 --base-dir 提供备用底包"
fi
fi

echo "fetch-stock: 查询最新固件版本..."
CHECK_OUT="$OUT/check-update.txt"
if ! samloader check-update --model "$MODEL" --region "$REGION" > "$CHECK_OUT" 2>&1; then
cat "$CHECK_OUT" >&2 || true
warn "check-update 失败：请检查型号/渠道是否正确，或三星服务器暂时不可用"
use_base_dir && exit 0
die "check-update 失败，且无备用底包可用"
fi
cat "$CHECK_OUT"
# check-update 输出只有一行版本号 PDA/CSC/MODEM；PDA 取第一段
if [[ -z "$PDA" ]]; then
PDA="$(head -n 1 "$CHECK_OUT" | cut -d/ -f1 | tr -d '[:space:]' || true)"
fi
echo "fetch-stock: 目标 PDA：${PDA:-（未能解析，以实际下载为准）}"

DL_DIR="$OUT/download"
mkdir -p "$DL_DIR"
echo "fetch-stock: 开始下载（约 8 GB，多线程并行，边下边解密）..."
# download 支持 --out-dir（-d），不用 cd 进目录；--version 留空即下载最新版
if ! samloader download --model "$MODEL" --region "$REGION" --out-dir "$DL_DIR"; then
warn "固件下载失败"
rm -rf "$DL_DIR"
use_base_dir && exit 0
die "固件下载失败，且无备用底包可用"
fi

FW_ZIP="$(find "$DL_DIR" -maxdepth 1 -name '*.zip' | head -n 1)"
if [[ -z "$FW_ZIP" ]]; then
warn "下载目录里没找到固件 zip：$DL_DIR"
use_base_dir && exit 0
die "下载完成但没找到固件 zip，且无备用底包可用"
fi
echo "fetch-stock: 已下载 $FW_ZIP"

# 解压固件 zip，取出 AP tar（AP 里有 boot/init_boot/vbmeta_system；vbmeta 在 BL 里）
TMP="$OUT/unpack"
mkdir -p "$TMP"
unzip -o -q "$FW_ZIP" -d "$TMP" || die "解压固件 zip 失败"
rm -f "$FW_ZIP" # 立刻删掉大文件，腾磁盘

AP_TAR="$(find "$TMP" -maxdepth 1 -name 'AP_*.tar.md5' | head -n 1)"
BL_TAR="$(find "$TMP" -maxdepth 1 -name 'BL_*.tar.md5' | head -n 1)"
[[ -n "$AP_TAR" ]] || { use_base_dir && exit 0; die "固件包里没找到 AP_*.tar.md5";}
echo "fetch-stock: AP=$AP_TAR BL=$BL_TAR"

extract_lz4() { # $1=tar文件 $2=要找的成员名前缀 $3=输出img路径
local tar="$1" prefix="$2" out="$3"
local member
member="$(tar -tf "$tar" | grep -E "^${prefix}(\.lz4)?$" | head -n 1)"
[[ -n "$member" ]] || { echo "fetch-stock: $tar 里没有 $prefix"; return 1;}
tar -xf "$tar" -C "$TMP" "$member"
if [[ "$member" == *.lz4 ]]; then
lz4 -d -f "$TMP/$member" "$out" || die "lz4 解压 $member 失败"
rm -f "$TMP/$member"
else
mv "$TMP/$member" "$out"
fi
}

extract_lz4 "$AP_TAR" "boot.img" "$OUT/boot.img" || { use_base_dir && exit 0; die "提取 boot.img 失败";}
extract_lz4 "$AP_TAR" "init_boot.img" "$OUT/init_boot.img" || { use_base_dir && exit 0; die "提取 init_boot.img 失败";}
extract_lz4 "$AP_TAR" "vbmeta_system.img" "$OUT/vbmeta_system.img" || echo "fetch-stock: 注意：AP 里没有 vbmeta_system.img（可接受）"
if [[ "$SKIP_VBMETA" == "1" ]]; then
echo "fetch-stock: --skip-vbmeta：跳过 vbmeta 提取（韩版 AP 不需要 vbmeta）。"
elif [[ -n "$BL_TAR" ]]; then
extract_lz4 "$BL_TAR" "vbmeta.img" "$OUT/vbmeta.img" || { use_base_dir && exit 0; die "BL 里提取 vbmeta.img 失败";}
else
extract_lz4 "$AP_TAR" "vbmeta.img" "$OUT/vbmeta.img" || { use_base_dir && exit 0; die "提取 vbmeta.img 失败";}
fi

# 清理中间文件（AP/BL tar 各几 GB）
rm -rf "$TMP"

if ! have_all; then
warn "底包不完整，缺少必需镜像"
use_base_dir && exit 0
die "底包不完整，且无备用底包可用"
fi
write_stock_info "samloader-rs-download" "${PDA:-unknown}"
echo "fetch-stock: 底包就绪（SamLoader-RS 下载）。"
ls -la "$OUT"
