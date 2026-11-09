#!/usr/bin/env bash
# patch-vbmeta.sh — vbmeta 处理（本项目数据安全的核心环节）
#
# 适用范围：仅国行（SM-S9180）等需要处理 vbmeta 的 build。
# 韩版（SM-S918N）的 AP 不考虑 vbmeta：不含、不打补丁、不做起飞前检查，
# 工作流里直接跳过本脚本（见 .github/workflows/build-ap.yml 的 vbmeta_policy）。
#
# 背景：
#   改过的 boot/init_boot 只有在 vbmeta 校验被禁用（flags=2）时才能启动。
#   但 Android 在 vbmeta 状态变化（flags 0 → 2）后首次启动可能清空数据。
#   已经 root 过且 vbmeta 已是 flags=2 的手机，之后不再变化 → 不清数据。
#   目标手机（SM-S918N）的 vbmeta 状态目前未知，用户须先用
#   scripts/check-vbmeta.sh 做起飞前检查（见 README）。
#
# 四种模式（--mode）：
#   omit（默认，最安全）：
#     AP 里不放任何 vbmeta，vbmeta 分区原样不动，不可能因 vbmeta 清数据。
#     要求：目标手机的 vbmeta 必须已经是 flags=2。
#     产出：不生成任何文件，只写 VBMETA_OMITTED 标记。
#   reuse：
#     把用户提供的手机当前 vbmeta（--phone-vbmeta，用 dd 从
#     /dev/block/by-name/vbmeta 导出）原样放进 AP。
#     脚本用 avbtool 校验其 flags 必须为 2；不是 2 则直接失败，
#     绝不悄悄产出会清数据或无法启动的包。
#   disable（显式 opt-in）：
#     从原厂 vbmeta 生成 flags=2 的禁用校验版。必须同时满足：
#       --allow-disable（或环境变量 ALLOW_VBMETA_DISABLE=1），
#     否则直接失败。产出的 Release 必须标注“首次刷入可能清空数据”。
#     生成方式：优先用 libxzr/vbmeta-disable-verification 原地改 flags；
#     没有该工具时，用 avbtool 生成同尺寸的空 flags=2 vbmeta 作为 fallback。
#   stock（仅供测试的备用方案）：
#     把原厂 vbmeta 原样（flags 不变）放进 AP。
#     警告：如果手机上校验仍在强制执行（flags=0 的原厂状态），
#     改过的 boot/init_boot 会被拒绝启动——这个包可能开不了机。
#     仅用于“手机 vbmeta 未知、不想冒险改 flags”的测试场景，
#     绝不能作为默认出包模式。
#
# 无论哪种模式，只要手头有原厂 vbmeta，脚本都会把它的 flags 记录到
# $OUT/vbmeta-flags.json（构建日志 + Release notes 的依据）。
# 构建绝不能默默假设“不会清数据”：不清空数据的保证只在以下两种情况成立——
#   (a) 手机 vbmeta 已是 flags=2；或
#   (b) AP 里 vbmeta 的 flags 与手机当前一致（omit / reuse / stock 模式）。
#
# 用法：
#   ./patch-vbmeta.sh --mode omit --out work/SM-S918N/vbmeta
#   ./patch-vbmeta.sh --mode reuse --phone-vbmeta vbmeta-phone.img --out work/.../vbmeta
#   ./patch-vbmeta.sh --mode disable --stock-vbmeta vbmeta.img \
#       --stock-vbmeta-system vbmeta_system.img --allow-disable --out work/.../vbmeta
#   ./patch-vbmeta.sh --mode stock --stock-vbmeta vbmeta.img --out work/.../vbmeta
#       （仅供测试：原厂 vbmeta 原样放进 AP，flags 不变；若手机校验仍在强制执行可能开不了机）
set -euo pipefail

MODE="omit"
STOCK_VBMETA=""
STOCK_VBMETA_SYSTEM=""
STOCK_VBMETA_VENDOR=""
PHONE_VBMETA=""
OUT=""
ALLOW_DISABLE="${ALLOW_VBMETA_DISABLE:-0}"

die() { echo "patch-vbmeta: ERROR: $*" >&2; exit 1; }
warn() { echo "patch-vbmeta: WARNING: $*" >&2; }

# --- 找 avbtool（AOSP external/avb 的 avbtool.py，纯 Python）---
get_avbtool() {
  if command -v avbtool >/dev/null 2>&1; then command -v avbtool; return 0; fi
  local tmp
  tmp="$(mktemp -d)"
  # 先试纯文本源（aosp-mirror），再试 googlesource（?format=TEXT 返回 base64）
  if curl -fsSL -o "$tmp/avbtool.py" \
      "https://raw.githubusercontent.com/aosp-mirror/platform_external_avb/master/avbtool.py" 2>/dev/null \
      && head -n 1 "$tmp/avbtool.py" | grep -q "python"; then
    chmod +x "$tmp/avbtool.py"
    echo "$tmp/avbtool.py"
    return 0
  fi
  if curl -fsSL -o "$tmp/avbtool.b64" \
      "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT" 2>/dev/null \
      && python3 -c "import base64,sys; open('$tmp/avbtool.py','wb').write(base64.b64decode(open('$tmp/avbtool.b64','rb').read()))" 2>/dev/null \
      && head -n 1 "$tmp/avbtool.py" | grep -q "python"; then
    chmod +x "$tmp/avbtool.py"
    echo "$tmp/avbtool.py"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

vbmeta_flags() { # $1=镜像路径 → 输出 Flags 数字；失败返回非 0
  local img="$1" avb="$2"
  "$avb" info_image --image "$img" 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*Flags:/ {print $2; exit}'
}

# 把给定 vbmeta 镜像的 flags 记录到 $OUT/vbmeta-flags.json，
# 供构建日志和 Release notes 引用。flags 读不到时记为 null，不致命。
record_flags() { # $1=标签（如 stock / phone / output） $2=镜像路径 $3=avbtool
  local label="$1" img="$2" avb="$3" flags="null"
  [[ -f "$img" ]] || return 0
  flags="$("$avb" info_image --image "$img" 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*Flags:/ {print $2; exit}')" || flags="null"
  [[ -n "$flags" ]] || flags="null"
  echo "patch-vbmeta: 记录 $label vbmeta flags=$flags（$img）"
  python3 - "$OUT/vbmeta-flags.json" "$label" "$flags" <<'EOF'
import json, os, sys
path, label, flags = sys.argv[1:4]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
try:
    flags = int(flags)
except (TypeError, ValueError):
    flags = None
data[label] = {"flags": flags}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --stock-vbmeta) STOCK_VBMETA="$2"; shift 2 ;;
    --stock-vbmeta-system) STOCK_VBMETA_SYSTEM="$2"; shift 2 ;;
    --stock-vbmeta-vendor) STOCK_VBMETA_VENDOR="$2"; shift 2 ;;
    --phone-vbmeta) PHONE_VBMETA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --allow-disable) ALLOW_DISABLE=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$OUT" ]] || die "--out 必填"
mkdir -p "$OUT"

case "$MODE" in
  omit)
    echo "patch-vbmeta: 模式=omit：AP 不含 vbmeta，vbmeta 分区原样不动（不清空数据）。"
    echo "要求：目标手机 vbmeta 必须已是 flags=2（已 root 的手机满足）。"
    : > "$OUT/VBMETA_OMITTED"
    # 只要手头有原厂 vbmeta，就记录它的 flags，供 Release notes 引用。
    if [[ -n "$STOCK_VBMETA" && -f "$STOCK_VBMETA" ]]; then
      AVB="$(get_avbtool)" || warn "找不到 avbtool，无法记录原厂 vbmeta flags"
      [[ -n "${AVB:-}" ]] && record_flags "stock" "$STOCK_VBMETA" "$AVB"
    fi
    ;;

  stock)
    # 仅供测试的备用方案：原厂 vbmeta 原样放进 AP，flags 不变。
    [[ -n "$STOCK_VBMETA" ]] || die "stock 模式需要 --stock-vbmeta"
    [[ -f "$STOCK_VBMETA" ]] || die "原厂 vbmeta 不存在：$STOCK_VBMETA"
    AVB="$(get_avbtool)" || die "找不到 avbtool，无法读取原厂 vbmeta flags"
    FLAGS="$(vbmeta_flags "$STOCK_VBMETA" "$AVB")" || die "无法读取原厂 vbmeta 的 flags"
    record_flags "stock" "$STOCK_VBMETA" "$AVB"
    echo "patch-vbmeta: 原厂 vbmeta flags=$FLAGS，原样放进 AP（不做任何修改）。"
    warn "stock 模式是仅供测试的备用方案：如果手机上校验仍在强制执行（flags=0），改过的 boot/init_boot 会被拒绝启动，这个包可能开不了机。绝不能作为默认出包模式。"
    cp "$STOCK_VBMETA" "$OUT/vbmeta.img"
    for pair in "$STOCK_VBMETA_SYSTEM:vbmeta_system.img" "$STOCK_VBMETA_VENDOR:vbmeta_vendor.img"; do
      src="${pair%%:*}"; name="${pair##*:}"
      [[ -n "$src" && -f "$src" ]] || continue
      cp "$src" "$OUT/$name"
      echo "patch-vbmeta: 已原样采用 $name"
    done
    record_flags "output" "$OUT/vbmeta.img" "$AVB"
    ;;

  reuse)
    [[ -n "$PHONE_VBMETA" ]] || die "reuse 模式需要 --phone-vbmeta（手机当前 vbmeta 的 dd 导出）"
    [[ -f "$PHONE_VBMETA" ]] || die "手机 vbmeta 文件不存在：$PHONE_VBMETA"
    AVB="$(get_avbtool)" || die "找不到 avbtool，无法校验 vbmeta flags"
    FLAGS="$(vbmeta_flags "$PHONE_VBMETA" "$AVB")" || die "无法读取手机 vbmeta 的 flags"
    echo "patch-vbmeta: 手机当前 vbmeta flags=$FLAGS"
    if [[ "$FLAGS" != "2" ]]; then
      die "手机 vbmeta flags=$FLAGS（不是 2），原样放进 AP 会导致无法启动或清空数据。构建已停止。请先确认手机已 root 且 vbmeta 已禁用校验（flags=2），或改用 --mode disable 并显式确认接受首次清空数据的风险。"
    fi
    cp "$PHONE_VBMETA" "$OUT/vbmeta.img"
    record_flags "phone" "$PHONE_VBMETA" "$AVB"
    record_flags "output" "$OUT/vbmeta.img" "$AVB"
    echo "patch-vbmeta: 已原样采用手机当前 vbmeta（flags=2），AP 刷入不会改变 vbmeta 状态，不清空数据。"
    ;;

  disable)
    if [[ "$ALLOW_DISABLE" != "1" ]]; then
      die "disable 模式会把 vbmeta flags 从 0 改成 2，首次刷入可能清空数据。必须显式传入 --allow-disable（或 ALLOW_VBMETA_DISABLE=1）才会继续。构建已停止，未产出任何包。"
    fi
    [[ -n "$STOCK_VBMETA" ]] || die "disable 模式需要 --stock-vbmeta"
    [[ -f "$STOCK_VBMETA" ]] || die "原厂 vbmeta 不存在：$STOCK_VBMETA"
    AVB="$(get_avbtool)" || die "找不到 avbtool"
    record_flags "stock" "$STOCK_VBMETA" "$AVB"
    STOCK_FLAGS="$(vbmeta_flags "$STOCK_VBMETA" "$AVB")" || STOCK_FLAGS="?"
    echo "patch-vbmeta: 原厂 vbmeta flags=$STOCK_FLAGS → 将生成 flags=2 的禁用校验版。"
    echo "patch-vbmeta: 模式=disable（已显式确认）：生成 flags=2 的禁用校验 vbmeta，原厂尺寸 $SIZE 字节。"
    # 首选：libxzr 工具原地改 flags（保留原厂描述符，只改 flags 位）
    if command -v vbmeta-disable-verification >/dev/null 2>&1; then
      cp "$STOCK_VBMETA" "$OUT/vbmeta.img"
      vbmeta-disable-verification "$OUT/vbmeta.img" \
        || die "vbmeta-disable-verification 执行失败"
    else
      warn "未找到 vbmeta-disable-verification，改用 avbtool 生成同尺寸空 flags=2 vbmeta（无描述符，Samsung 惯用做法）。"
      "$AVB" make_vbmeta_image --flags 2 --padding_size "$SIZE" \
        --output "$OUT/vbmeta.img" || die "avbtool 生成禁用校验 vbmeta 失败"
    fi
    # vbmeta_system / vbmeta_vendor 同理（如原厂包里有）
    for pair in "$STOCK_VBMETA_SYSTEM:vbmeta_system.img" "$STOCK_VBMETA_VENDOR:vbmeta_vendor.img"; do
      src="${pair%%:*}"; name="${pair##*:}"
      [[ -n "$src" && -f "$src" ]] || continue
      sz="$(stat -c%s "$src")"
      "$AVB" make_vbmeta_image --flags 2 --padding_size "$sz" \
        --output "$OUT/$name" || die "生成 $name 失败"
      echo "patch-vbmeta: 已生成 $name（flags=2，$sz 字节）"
    done
    # 复核产出 flags
    OUT_FLAGS="$(vbmeta_flags "$OUT/vbmeta.img" "$AVB")" || die "无法读取产出 vbmeta 的 flags"
    [[ "$OUT_FLAGS" == "2" ]] || die "产出 vbmeta flags=$OUT_FLAGS（期望 2），构建失败"
    record_flags "output" "$OUT/vbmeta.img" "$AVB"
    warn "产出 vbmeta flags=2。提醒：首次把 flags 从 0 改成 2 刷入手机可能清空数据，Release 必须标注此警告。"
    ;;

  *)
    die "--mode 只能是 omit / reuse / disable / stock，当前：$MODE"
    ;;
esac

echo "patch-vbmeta: 完成（模式=$MODE），输出目录：$OUT"
ls -la "$OUT"
