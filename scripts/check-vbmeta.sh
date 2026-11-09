#!/usr/bin/env bash
# check-vbmeta.sh — 刷 AP 包之前的起飞前检查：确认手机 vbmeta 的 flags 状态
#
# 适用范围：仅国行（SM-S9180）等需要处理 vbmeta 的 build。
# 韩版（SM-S918N）的 AP 不考虑 vbmeta，不需要跑本脚本，也不需要发送 vbmeta 文件。
#
# 为什么必须先查：
#   改过的 boot/init_boot 只有在 vbmeta 校验被禁用（flags=2）时才能启动。
#   如果手机 vbmeta 还是出厂状态（flags=0），第一次刷入 flags=2 的 vbmeta
#   可能清空数据。本项目的“不清空数据”保证只在手机 vbmeta 已是 flags=2
#   时成立；flags 未知时，绝不能默默假设。
#
# 用法（二选一）：
#   1. 检查本地已导出的 vbmeta 镜像：
#        ./check-vbmeta.sh --image vbmeta.img
#   2. 直接连手机检查（需要 adb + root；会自动导出并拉取镜像）：
#        ./check-vbmeta.sh --adb [--serial <设备序列号>]
#
# 导出方法（手动，备用）：
#   手机上（有 root）：su -c 'dd if=/dev/block/by-name/vbmeta of=/sdcard/vbmeta.img bs=4096'
#   再 adb pull /sdcard/vbmeta.img，然后用方式 1 检查。
#   同理可查 vbmeta_system：dd if=/dev/block/by-name/vbmeta_system ...
#
# 判读：
#   Flags: 2 → 校验已禁用，可以直接刷默认 AP（AP 不含 vbmeta），不会因 vbmeta 清数据。
#   Flags: 0 → 校验仍在强制执行。先备份数据；第一次刷入 flags=2 的 vbmeta
#            可能清空数据，确认接受后再刷。
#   读不到 → 检查失败，不要刷，先排查（镜像是否完整、avbtool 是否可用）。
set -euo pipefail

IMAGE=""
USE_ADB=0
SERIAL=""

die() { echo "check-vbmeta: ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)  IMAGE="$2"; shift 2 ;;
    --adb)    USE_ADB=1; shift ;;
    --serial) SERIAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

# --- 找 avbtool（AOSP external/avb 的 avbtool.py，纯 Python）---
get_avbtool() {
  if command -v avbtool >/dev/null 2>&1; then command -v avbtool; return 0; fi
  local tmp
  tmp="$(mktemp -d)"
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

AVB="$(get_avbtool)" || die "找不到 avbtool。请安装 Python 版 avbtool（AOSP external/avb）后重试。"

if [[ "$USE_ADB" == "1" ]]; then
  command -v adb >/dev/null 2>&1 || die "未找到 adb，请安装 Android platform-tools"
  ADB=(adb)
  [[ -n "$SERIAL" ]] && ADB+=( -s "$SERIAL" )
  echo "check-vbmeta: 通过 adb 从手机导出 vbmeta（需要 root）..."
  "${ADB[@]}" shell su -c "'dd if=/dev/block/by-name/vbmeta of=/sdcard/vbmeta-check.img bs=4096'" \
    || die "导出 vbmeta 失败：请确认手机已 root 且 adb shell 里 su 可用"
  IMAGE="vbmeta-check.img"
  "${ADB[@]}" pull /sdcard/vbmeta-check.img "$IMAGE" >/dev/null \
    || die "拉取 vbmeta 镜像失败"
  echo "check-vbmeta: 已导出到 $IMAGE"
fi

[[ -n "$IMAGE" ]] || die "请指定 --image <vbmeta.img> 或 --adb"
[[ -f "$IMAGE" ]] || die "vbmeta 镜像不存在：$IMAGE"

echo "check-vbmeta: 检查 $IMAGE ..."
"$AVB" info_image --image "$IMAGE" || die "avbtool 无法解析该镜像（文件可能不完整或不是 vbmeta）"
FLAGS="$("$AVB" info_image --image "$IMAGE" 2>/dev/null \
  | awk -F': *' '/^[[:space:]]*Flags:/ {print $2; exit}')"
[[ -n "$FLAGS" ]] || die "无法读取 Flags，请确认镜像是完整的 vbmeta.img"

echo ""
echo "check-vbmeta: 结论：vbmeta Flags = $FLAGS"
case "$FLAGS" in
  2)
    echo "✅ 校验已禁用（flags=2）。"
    echo "   可以直接刷本项目的默认 AP（AP 不含 vbmeta），不会因 vbmeta 清数据。"
    echo "   仍建议刷机前备份数据。"
    ;;
  0)
    echo "⚠️  校验仍在强制执行（flags=0）。"
    echo "   第一次刷入 flags=2 的 vbmeta 可能清空数据！"
    echo "   请先完整备份数据，确认接受后，再刷含禁用校验 vbmeta 的包，"
    echo "   或按 README“首次 root 的手机”一节先单独刷禁用校验的 vbmeta。"
    echo "   不要在没备份的情况下直接刷。"
    ;;
  *)
    echo "⚠️  Flags=$FLAGS（不是常见的 0 或 2）。"
    echo "   请先核实该 vbmeta 的来源和状态，确认后再刷。"
    ;;
esac
