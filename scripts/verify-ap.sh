#!/usr/bin/env bash
# verify-ap.sh — 校验产出的 AP_*.tar.md5，任一项失败即退出非 0，禁止发布
#
# 检查项：
#   1. tar.md5 末尾的 md5 与文件本体一致；
#   2. tar 里只有白名单成员：boot.img.lz4、init_boot.img.lz4、
#      vbmeta.img.lz4、vbmeta_system.img.lz4、vbmeta_vendor.img.lz4；
#      出现 CSC / BL / CP / super / system 等一律失败；
#   3. 每个 .lz4 的 magic 为 04 22 4d 18 6c（三星格式）；
#   4. boot.img：ANDROID! 头 + 内核 ARM64 Image magic（偏移 0x38 处 "ARMd"）；
#   5. init_boot.img：合法 boot 镜像，且 ramdisk 里含 kernelsu.ko；
#   6. vbmeta：若 AP 里含 vbmeta*.img.lz4，解压后 flags 必须为 2
#      （flags=0 的 vbmeta 会重新启用校验，导致改过的镜像无法启动）；
#      若 --vbmeta-mode omit，AP 里出现任何 vbmeta 即失败；
#      若 --vbmeta-mode stock，额外输出警告（flags 不变，可能开不了机，仅供测试）。
#
# 用法：
#   ./verify-ap.sh --ap out/AP_SM-S918N_xxx.tar.md5 [--vbmeta-mode omit|reuse|disable|stock]
set -euo pipefail

AP=""
VBMETA_MODE="omit"

die() { echo "verify-ap: ERROR: $*" >&2; exit 1; }
warn() { echo "verify-ap: WARNING: $*" >&2; }
ok() { echo "verify-ap: OK: $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ap) AP="$2"; shift 2 ;;
    --vbmeta-mode) VBMETA_MODE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$AP" ]] || die "--ap 必填"
[[ -f "$AP" ]] || die "AP 文件不存在：$AP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. md5 校验：去掉末尾的 md5 行，算本体 md5，与记录值比对 ---
# tar.md5 末尾一行格式： "<md5>  <文件名>"
LAST_LINE="$(tail -n 1 "$AP")"
RECORDED_MD5="$(echo "$LAST_LINE" | awk '{print $1}')"
[[ "$RECORDED_MD5" =~ ^[0-9a-f]{32}$ ]] || die "tar.md5 末尾没有合法的 md5 行"
BODY_SIZE="$(($(stat -c%s "$AP") - ${#LAST_LINE} - 1))"
head -c "$BODY_SIZE" "$AP" > "$WORK/body.tar"
ACTUAL_MD5="$(md5sum "$WORK/body.tar" | awk '{print $1}')"
[[ "$ACTUAL_MD5" == "$RECORDED_MD5" ]] || die "md5 不匹配：记录 $RECORDED_MD5，实际 $ACTUAL_MD5"
ok "tar.md5 校验和一致"

# --- 2. 成员白名单 ---
ALLOWED="^(boot|init_boot|vbmeta|vbmeta_system|vbmeta_vendor)\.img\.lz4$"
MEMBERS="$(tar -tf "$WORK/body.tar")"
# 注意：不能用管道接 while（die 会只退出子 shell）；改用进程替换。
while read -r m; do
  [[ "$m" =~ $ALLOWED ]] || die "AP 里出现不允许的成员：$m（只允许 boot/init_boot/vbmeta*.img.lz4）"
done < <(echo "$MEMBERS")
echo "$MEMBERS" | grep -qx "boot.img.lz4"      || die "AP 里缺少 boot.img.lz4"
echo "$MEMBERS" | grep -qx "init_boot.img.lz4" || die "AP 里缺少 init_boot.img.lz4"
ok "tar 成员白名单通过"
VBMETA_PRESENT="$(echo "$MEMBERS" | grep -c "^vbmeta.*\.img\.lz4$" || true)"

if [[ "$VBMETA_MODE" == "omit" && "$VBMETA_PRESENT" != "0" ]]; then
  die "vbmeta-mode=omit 但 AP 里含 vbmeta（$VBMETA_PRESENT 个），与不碰 vbmeta 的设计冲突"
fi

# --- 解压全部成员到工作目录 ---
tar -xf "$WORK/body.tar" -C "$WORK"
for f in "$WORK"/*.img.lz4; do
  [[ -e "$f" ]] || continue
  MAGIC="$(xxd -p -l 5 "$f")"
  [[ "$MAGIC" == "04224d186c" ]] || die "$(basename "$f") 的 lz4 magic 不是 04224d186c（实际 $MAGIC）"
  lz4 -d -f "$f" "${f%.lz4}" || die "解压 $(basename "$f") 失败"
done
ok "全部 lz4 成员为三星格式（magic 04224d186c）"

# --- 4. boot.img：ANDROID! 头 + ARM64 Image magic ---
if ! python3 - "$WORK/boot.img" <<'EOF'
import sys
with open(sys.argv[1], "rb") as f:
    head = f.read(8)
    assert head == b"ANDROID!", "boot.img 没有 ANDROID! 头"
    f.seek(0x38)
    assert f.read(4) == b"ARMd", "内核不是 ARM64 Image（偏移 0x38 处无 ARMd magic）"
EOF
then
  die "boot.img 校验失败：不是合法 Android boot 镜像，或内核不是 ARM64 Image"
fi
ok "boot.img：ANDROID! 头 + ARM64 Image 内核"

# 内核版本字符串里应含 Faiz（由上游构建保证；这里只做提示性检查）
if grep -aq "Linux version 5.15.*Faiz" "$WORK/boot.img"; then
  ok "boot.img 内核版本字符串含 Faiz"
else
  warn "boot.img 里没找到含 Faiz 的内核版本字符串（可能是字符串被压缩或截断，请人工核对）"
fi

# --- 5. init_boot.img：合法镜像 + ramdisk 含 kernelsu.ko ---
if ! python3 - "$WORK/init_boot.img" <<'EOF'
import sys
with open(sys.argv[1], "rb") as f:
    head = f.read(8)
sys.exit(0 if head == b"ANDROID!" else 1)
EOF
then
  die "init_boot.img 不是合法 Android boot 镜像"
fi
if command -v magiskboot >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
  mkdir -p "$WORK/ib" && cp "$WORK/init_boot.img" "$WORK/ib/"
  (cd "$WORK/ib" && magiskboot unpack init_boot.img >/dev/null) || die "init_boot.img 解包失败"
  if [[ -f "$WORK/ib/ramdisk.cpio" ]]; then
    cpio -it < "$WORK/ib/ramdisk.cpio" 2>/dev/null | grep -qx "kernelsu.ko" \
      || die "init_boot ramdisk 里没有 kernelsu.ko"
    ok "init_boot ramdisk 含 kernelsu.ko"
  else
    grep -aq "kernelsu.ko" "$WORK/init_boot.img" || die "init_boot.img 里没有 kernelsu.ko"
    ok "init_boot.img 含 kernelsu.ko（弱校验：无 ramdisk.cpio）"
  fi
else
  grep -aq "kernelsu.ko" "$WORK/init_boot.img" || die "init_boot.img 里没有 kernelsu.ko"
  ok "init_boot.img 含 kernelsu.ko（弱校验：无 magiskboot/cpio）"
fi

# --- 6. vbmeta flags 校验 ---
if [[ "$VBMETA_PRESENT" != "0" ]]; then
  AVB=""
  if command -v avbtool >/dev/null 2>&1; then
    AVB="avbtool"
  else
    echo "verify-ap: 未找到 avbtool，无法校验 vbmeta flags，跳过此项（请在 CI 里保证 avbtool 可用）" >&2
  fi
  if [[ -n "$AVB" ]]; then
    for v in "$WORK"/vbmeta*.img; do
      [[ -e "$v" ]] || continue
      FLAGS="$("$AVB" info_image --image "$v" 2>/dev/null \
        | awk -F': *' '/^[[:space:]]*Flags:/ {print $2; exit}')"
      [[ -n "$FLAGS" ]] || die "无法读取 $(basename "$v") 的 flags"
      [[ "$FLAGS" == "2" ]] || die "$(basename "$v") 的 flags=$FLAGS（期望 2）：flags=0 的 vbmeta 会重新启用校验，导致改过的镜像无法启动"
      ok "$(basename "$v") flags=2（校验已禁用）"
    done
  fi
  if [[ "$VBMETA_MODE" == "stock" ]]; then
    warn "vbmeta-mode=stock：AP 里的 vbmeta 是原厂原样（flags 不变）。若手机校验仍在强制执行，这个包可能开不了机，仅供测试。"
  fi
fi

echo "verify-ap: 全部校验通过：$AP"
