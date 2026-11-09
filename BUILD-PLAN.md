# BUILD-PLAN — 构建计划与未解决问题

> 本文件记录 v1 上线前必须处理的风险和开放问题。构建脚本本身已就绪，
> 但以下事项未经真机验证前，**不要把任何 Release 当成“可直接给别人用”的成品**。

## 目标与范围

- 新独立仓库，不动 `Sadrzd/kernel_samsung_sm8550`。
- v1 矩阵：SM-S918N（韩版 KOO，优先）→ SM-S9180（国行 CHC）。
- 底包来源：CI 内用 SamLoader-RS 从三星服务器下载（无需 IMEI）；
  用户提供的底包仅为下载失败时的备用方案。
- 不清空数据：AP 里只有 boot / init_boot /（可选）vbmeta，
  绝无 CSC、BL、CP，不做 repartition。

## 已知目标手机状态（2026-11-09 用户确认）

- SM-S918N 已 root，但用的是 **KernelSU Next**，不是官方 KernelSU。
- **韩版 vbmeta 不需要考虑**：用户确认，韩版直接刷 boot + init_boot 即可，
  AP 不含 vbmeta、不打补丁、不做起飞前检查，也不需要发送 vbmeta 文件。
  因此韩版 v1 不存在因 vbmeta 清空数据的风险。
- 国行 SM-S9180 的 vbmeta 状态仍是**未知**，相关处理只适用于国行 build。

## 开放问题 / 风险清单

### 1. SamLoader-RS 在 CI 里下载约 8 GB 固件（磁盘与时间）
- GitHub Actions runner 可用磁盘约 14 GB；固件 zip（~8 GB）+ 解压的
  AP/BL tar（各数 GB）+ 提取的镜像，峰值占用可能超过 20 GB。
- 已做缓解：工作流先跑 `free-disk-space` 释放空间；`fetch-stock.sh`
  在解压后立刻删除固件 zip，提取完删除 AP/BL tar。
- 仍需验证：第一次跑是否真的能在磁盘上限内完成；下载耗时（三星服务器
  限速 + 8 线程并行）是否在 `timeout-minutes: 300` 内。
- 备选：如果下载在 CI 里不可行，改用用户提供的底包做输入
 （`fetch-stock.sh --base-dir`，仅备用）。

### 2. AP 槽刷 vbmeta 未经 S918N / S9180 验证（仅国行）
- Odin 按文件名认分区，AP tar 里放 `vbmeta.img.lz4` 理论上能刷到 vbmeta 分区，
  但这一点在 S918N/S9180 上未经验证。
- **韩版不受此影响**：韩版 AP 根本不放 vbmeta。
- 只有 reuse/disable/stock 模式（仅国行）会涉及，首次使用这些模式前必须真机实测。
- 如果 Odin 拒绝 AP 槽的 vbmeta，改成单独出一个 `vbmeta.tar` 让用户放 AP 槽刷，
  或出在 BL 槽的配套文件。

### 3. vbmeta 状态未知 → 首次刷入可能清空数据（仅国行）
- 如果国行手机的 vbmeta 还是 flags=0，第一次刷入 flags=2 的 vbmeta
  可能清空数据。README 已明确要求先备份、先跑 `check-vbmeta.sh`。
- **韩版不存在这个问题**：韩版 AP 不含 vbmeta，不改变 vbmeta 状态。
- 构建绝不能默默假设不清空数据：`patch-vbmeta.sh` 会把原厂 vbmeta 的 flags
  记录到 `vbmeta-flags.json`，并写进 Release notes；
  `disable` 模式必须显式 `--allow-disable`，否则构建失败。
- stock（flags 不变）模式是仅供测试的备用方案：若手机校验仍在强制执行，
  改过的 boot/init_boot 会被拒绝启动，可能开不了机。

### 4. 首次构建必须真机实测
- 至少一次完整流程：Odin 刷 AP → 开机 → 官方管理器显示“工作中” →
  已授权 App 直接有 root → 新 App 授权正常。
- 每个新机型上线前都必须重复一次。

### 5. 三星固件文件绝不能公开提交
- boot / init_boot / vbmeta 是三星版权文件，只能在 CI 运行时现下现用，
  用完即删；`.gitignore` 已排除 `*.img` / `*.tar*` / `firmware/` 等。
- Release 里只发我们自己生成的 AP（内含原厂 ramdisk 的衍生文件），
  版权上仍是灰色地带；如介意，可改为只发构建脚本、AP 在用户自己的
  runner 上生成。

### 6. 工具链版本的不确定性
- `ksud boot-patch` 的参数以官方文档为准（`-b/-k/-m/-o/--magiskboot/--kmi`）；
  若 tiann/KernelSU 发新版改了参数，构建会明确报错，需同步更新。
- 官方 Release 的资产文件名（如 `ksud-x86_64-unknown-linux-musl`、
  `*android13-5.15*.ko`）随版本可能变化；工作流里已做按模式匹配、
  找不到就列出全部资产名并失败，不会静默用错文件。
- `config/pins.json` 里钉死的 KSU 版本（v3.3.1）必须在构建时核实；
  上游有新版时先更新 pins.json 再跟进。
- magiskboot 由 `build-boot.sh` 自动从官方 Magisk APK 提取；
  若 Magisk 改了 APK 内路径，脚本会失败并提示改用 `ksud -k` 备选方案。

### 7. 固件版本匹配
- AP 的底包固件版本必须与手机当前系统版本一致或接近，
  且 BL 位不得低于手机当前 BL 位，否则可能开不了机。
- `matrix/devices.json` 里 S918N 的 PDA 目前为空，由构建时
  `samloader check-update` 动态获取；首次构建后应把实际 PDA 回填进来。
- S9180 的 PDA 以 `S9180ZCU7FZDP` 为准（用户本机固件），
  如上游已更新，以 check-update 结果为准。

### 8. KernelSU Next → 官方切换的遗留问题
- Next 与官方的 allowlist 是分开维护的，切换后旧授权不一定带过来，
  需在官方管理器里重新授权（README 已说明，不做“无缝迁移”的承诺）。
- Next 特有的模块（如依赖 Next 内置挂载/SUSFS 的模块）在官方版上
  可能无法工作，切换前应先在 Next 里卸载 Next 专属模块。
- ReSuSFS 等模块在官方版上有独立的支持路径，不受切换影响。

## 建议的上线顺序

1. 先在本地跑通一次 `fetch-stock.sh`（确认 SamLoader-RS 能下到 S918N KOO 固件）。
2. 手动触发一次工作流（workflow_dispatch，单机型 SM-S918N，vbmeta_mode=omit），
   确认构建、校验、Release 全流程跑通。
3. 真机刷入验证（见第 4 条）：韩版不需要先跑 `check-vbmeta.sh`，直接刷 boot + init_boot。
4. 通过后再做 S9180 CHC；国行首次刷入前，用户先跑 `check-vbmeta.sh` 确认 flags。
5. 之后按矩阵扩展。
