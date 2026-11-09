#!/usr/bin/env python3
"""select-matrix.py — 从 matrix/devices.json 生成 GitHub Actions 矩阵 JSON。

用法：
    python3 scripts/select-matrix.py matrix/devices.json [all|SM-S918N|...]

输出（单行 JSON，供 workflow 的 fromJson 使用）：
    {"include": [{"model": ..., "region": ..., "channel": ...,
                  "pda": ..., "bootloader_bit": ..., "vbmeta_policy": ...}, ...]}

只选 status == "v1" 的设备，按 priority 排序；传入单个型号时只选该型号。
vbmeta_policy 来自 devices.json：韩版（SM-S918N）为 "none"（AP 不含 vbmeta），
国行（SM-S9180）为 "check"（vbmeta 处理仍是开放问题）。
"""
import json
import sys


def main() -> None:
    devices_path = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else "all"
    with open(devices_path, encoding="utf-8") as f:
        devices = json.load(f)["devices"]

    sel = [d for d in sorted(devices, key=lambda x: x["priority"]) if d["status"] == "v1"]
    if want and want != "all":
        sel = [d for d in sel if d["model"] == want]
        if not sel:
            raise SystemExit(f"机型 {want} 不在 v1 矩阵里")

    out = {"include": [
        {
            "model": d["model"],
            "region": d["region"],
            "channel": d["channel"],
            "pda": d.get("pda") or "",
            "bootloader_bit": d["bootloader_bit"],
            "vbmeta_policy": d.get("vbmeta_policy", "check"),
        }
        for d in sel
    ]}
    print(json.dumps(out))


if __name__ == "__main__":
    main()
