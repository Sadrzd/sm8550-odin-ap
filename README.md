# SM8550 Odin 直刷 AP 包

把 Faiz 内核（Linux 5.15.225，LKM）+ 官方 KernelSU 做成 Odin 可直接刷入的 AP 包。
刷完开机即有 root，**不需要再进 KernelSU 管理器点“安装”**。

> 仓库：本项目只做“打包”，不改内核。内核源码与构建在
> [Sadrzd/kernel_samsung_sm8550](https://github.com/Sadrzd/kernel_samsung_sm8550)，
> 本仓库每次构建都从它的 Release 里取最新内核成品。

---

## 一、这个包是干什么的

| 步骤 | 以前（管理器安装） | 现在（刷 AP 包） |
|---|---|---|
| 换内核 | Recovery 里刷 AnyKernel3 zip | Odin 刷 AP，里面已含 Faiz 内核 |
| 装 KernelSU LKM | 管理器里选文件、打补丁、再刷 init_boot | AP 里已含打好补丁的 init_boot，开机自动加载 `kernelsu.ko` |
| 给 App 授权 root | 管理器 | **还是管理器**（见下） |

**AP 包能替代的，只是管理器“安装 KSU”这一步。**
root 授权白名单是内核模块维护的，但只有管理器 App 能往白名单里写。
所以：

- **已经 root 过的手机**（`/data` 里已有 `/data/adb/ksu` 白名单和装好的管理器）：
  刷完 AP 开机，之前授权过的 App 直接就有 root，**什么都不用再设置**。
  这就是“刷进去就有 root，KSU 只是管理器”的意思——前提是 `/data` 没被清空。
- **从没 root 过的手机**：刷完 AP 只是内核态 root 就绪，白名单是空的，
  仍需装一次官方 KernelSU 管理器来给 App 授权。管理器打开就是“工作中”，不用再走安装流程。

### 从 KernelSU Next 换到官方 KernelSU（v1 目标机 S918N 的情况）

v1 首发机型 SM-S918N 目前用的是 **KernelSU Next**，本项目把它换成**官方 KernelSU LKM**：

- 刷完 AP 后，请装**官方 KernelSU 管理器**（tiann/KernelSU 的 Release）。
  Next 的管理器不再匹配官方模块，不要继续用它。
- **授权可能需要重新给一遍**：Next 和官方的授权白名单是分开维护的，
  旧授权列表不会自动带过来。本项目**不承诺**旧授权无缝迁移——
  刷完后打开官方管理器，逐个给需要 root 的 App 重新授权。
- 切换前，先在 Next 里卸载 Next 专属模块（如依赖 Next 内置挂载/SUSFS 的模块），
  它们在官方版上可能无法工作。
- 内核本身不用动：Faiz 内核是 LKM 模式，换的只是 init_boot 里的模块
  （Next 的模块 → 官方的 `kernelsu.ko`）。

## 二、不清空数据的保证（及前提条件）

本项目对数据安全的设计原则：

1. **AP 包里永远不放 CSC，不做 repartition**，只刷 `boot` / `init_boot`（国行特殊模式下
   才额外含 vbmeta）。只刷 AP、不选 CSC，就不会触发恢复出厂。
2. **韩版（SM-S918N）：根本不碰 vbmeta。** AP 只含 `boot.img.lz4` + `init_boot.img.lz4`，
   vbmeta 分区原样不动，因此不存在因 vbmeta 状态变化而清空数据的风险。
   韩版不需要做 vbmeta 起飞前检查，也不需要发送 vbmeta 文件。
3. **国行（SM-S9180）：默认也不碰 vbmeta**，AP 默认同样只含 boot + init_boot。
   只有在国行需要处理 vbmeta 的特殊模式下，才会涉及以下规则。
4. **“不清空数据”是有条件的，绝不是无条件保证（国行）。**
   它只在以下两种情况成立：
   - (a) 手机的 vbmeta **已经是 flags=2**（校验已禁用）；或
   - (b) AP 里 vbmeta 的 flags 与手机当前一致（omit / reuse / stock 模式）。
   构建流程绝不会默默假设不清空数据：`patch-vbmeta.sh` 会把原厂 vbmeta 的
   flags 记录到 `vbmeta-flags.json` 并写进 Release notes；
   `disable` 模式必须显式开启 `allow_vbmeta_disable`，否则构建直接失败。

### ⚠️ 先检查：国行手机 vbmeta 状态未知时不要直接刷（仅国行）

以下内容**只适用于国行（SM-S9180）**，韩版用户请跳过。

国行手机的 vbmeta 状态目前**未知**（用户也不知道校验是否已禁用）。
**刷 AP 之前必须先跑起飞前检查，确认 flags 再动手：**

```sh
# 电脑连手机（需要 adb + root），一键导出并检查：
./scripts/check-vbmeta.sh --adb

# 或手动导出后检查：
# 手机上：su -c 'dd if=/dev/block/by-name/vbmeta of=/sdcard/vbmeta.img bs=4096'
# 电脑上：./scripts/check-vbmeta.sh --image vbmeta.img
```

判读：

| 结果 | 含义 | 能不能刷 |
|---|---|---|
| Flags: 2 | 校验已禁用 | 可以直接刷默认 AP，不会因 vbmeta 清数据 |
| Flags: 0 | 校验仍在强制执行 | **先备份！**第一次刷入 flags=2 的 vbmeta 可能清空数据，确认接受后再刷 |
| 读不到 | 检查失败 | 不要刷，先排查 |

**如果手机 vbmeta 还是 flags=0，第一次刷入 flags=2 的 vbmeta 可能清空数据。**
这是 Android 在 vbmeta 状态变化后首次启动的行为，不是本项目能绕过的。
请先完整备份数据，确认接受后，再刷含禁用校验 vbmeta 的包。
只想测试、不想冒险改 flags 时，可用 `stock` 模式的包（vbmeta 原厂原样，
flags 不变），但要注意：若手机校验仍在强制执行，改过的 boot/init_boot
会被拒绝启动，这个包可能开不了机，仅供测试。

### 首次 root 的手机（仅国行）

1. 先单独刷一个禁用校验的 vbmeta（`avbtool make_vbmeta_image --flags 2` 生成），
   **这一步 Android 可能会清空一次数据，务必先备份**；
2. 之后再刷本项目的 AP，此后升级 AP 不会再清数据。

> 构建流程里也有对应保护：如果构建时需要改 vbmeta（`VBMETA_MODE=disable`），
> 必须显式开启 `allow_vbmeta_disable` 才会出包，否则构建直接失败并给出警告，
> 绝不会悄悄产出一个会清数据的包。详见 `scripts/patch-vbmeta.sh`。

## 三、支持机型

内核本身覆盖全部 SM8550（骁龙 8 Gen 2）三星机型，但 AP 包的底包
（原厂 boot / init_boot）必须按**机型 × 固件版本**分别取，所以按机型逐个上线。

| 优先级 | 机型 | 型号 | 地区/渠道 | 状态 |
|---|---|---|---|---|
| **1（v1 首发）** | Galaxy S23 Ultra | SM-S918N | 韩国 KOO | 首批 |
| **2（v1）** | Galaxy S23 Ultra | SM-S9180 | 国行 CHC | 首批 |
| 3 | Galaxy S23 / S23+ | SM-S911x / SM-S916x（含韩版 N） | CHC / TGY / KOO | 计划中 |
| 4 | Galaxy Z Fold5 / Z Flip5 | SM-F946x / SM-F731x | CHC / TGY / KOO | 计划中 |
| 5 | Galaxy Tab S9 系列 | SM-X710 / X810 / X910 等 | CHC / TGY / KOO | 计划中（平板 vendor_boot 结构略有差异，风险最高，放最后） |

同一 PDA 版本下 AP 与 CSC 无关（多 CSC 固件是同一份文件），
但国行/港版/韩版是不同的 PDA 渠道，固件版本和 BL 位不同，不能混用底包。

**v1 只做 S918N（韩版）和 S9180（国行），先韩版后国行。**

## 四、AP 包里有什么

以韩版 S918N 为例（文件名以实际 Release 为准）：

```
AP_SM-S918N_<固件版本>_Faiz_<内核tag>_ksu<版本>.tar.md5
├── boot.img.lz4          # 原厂 boot.img，内核换成 Faiz 内核
└── init_boot.img.lz4     # 原厂 init_boot.img，经 ksud boot-patch（已含 kernelsu.ko）
```

**韩版 v1 的 AP 只有上面两个文件：不含 vbmeta、不打 vbmeta 补丁、**
**不需要做 vbmeta 起飞前检查，也不需要你发送 vbmeta 文件。**
只刷 boot + init_boot，不存在因 vbmeta 清空数据的风险。

国行（S9180）的包结构相同，特殊模式下才额外含 flags=2 的 `vbmeta*.img.lz4`
（见第二节，vbmeta 处理仅适用于国行）。

不含 system / super / BL / CP / CSC，包体约 100 MB。

## 五、怎么刷（Odin）

准备：已解锁 bootloader 的手机、Odin（电脑）、本 Release 里对应你机型和
固件版本的 AP 包。

1. **备份数据。** 虽然设计上不清空数据，但刷机前备份永远是必须的。
2. 手机关机，按住 音量下 + 电源键 进 Download 模式，按 音量上 确认。
3. 打开 Odin，手机连电脑，确认 Odin 识别到设备（ID:COM 变蓝）。
4. 只在 **AP** 一栏选本项目的 `.tar.md5` 文件。
   **BL / CP / CSC 三栏留空**，不要勾选 Re-partition，
   不要选 CSC（选了 CSC 就会清数据）。
5. 点 Start，等 PASS。手机自动重启。
6. 开机后打开**官方 KernelSU 管理器**，应直接显示“工作中”。
   之前授权过的 App 直接有 root；新 App 授权仍在管理器里操作。
   从 KernelSU Next 换过来的手机：装官方管理器（不要用 Next 的），
   授权可能需要重新给一遍，见第一节。

**只能刷与你手机固件版本一致（或 BL 位不低于当前）的包。**
跨固件版本、跨机型刷入可能开不了机。刷错版本的恢复方法见下。

## 六、开不了机 / 恢复

- 只刷了 AP，不动 BL/CP/CSC，Download 模式永远都在，不会硬砖。
- 恢复：用 Odin 刷回对应机型的官方全量固件（BL + AP + CP + CSC），
  或只刷官方 AP + BL 恢复原厂 boot/init_boot。
- 注意：不要只单独把 boot/init_boot/vbmeta 其中一个恢复成原厂、
  其他保持修改状态混用，可能导致无法启动。

## 七、自动更新

新版本内核发布或官方 KernelSU 发布后，本仓库自动重新打包：

- **即时触发**：内核仓库发布 Release 后发 `repository_dispatch`（`kernel-released`）过来；
- **定时巡检**：每 6 小时检查一次内核仓库和 tiann/KernelSU 的最新 Release，
  有变化才构建，没变化直接退出；
- **手动触发**：Actions 里 `workflow_dispatch`，可指定内核 tag、KSU 版本和机型矩阵。

AP 的 Release tag 格式：`ap-<内核tag>-ksu<KSU版本>`，
例如 `ap-sm8550-lkm-5.15.225-20261109-r4-ksu3.3.1`。
同名 Release 已存在时跳过，不重复发布。

## 八、构建流程（CI 里做了什么）

```
内核 Release（Sadrzd/kernel_samsung_sm8550）
        │  下载 SM8550_LKM_*.zip，校验 SHA256SUMS，
        │  核对版本号含 Faiz、Image 为 ARM64 magic
        ▼
原厂固件（CI 内用 SamLoader-RS 从三星服务器下载，无需 IMEI；
        下载失败时才改用用户提供的备用底包）
        │  提取 boot.img / init_boot.img / vbmeta*.img
        ▼
magiskboot：解包原厂 boot.img → 内核换成 Faiz Image → 打包
        │
ksud boot-patch：给原厂 init_boot.img 打补丁（--kmi android13-5.15）
        │  注入官方 kernelsu.ko
        ▼
vbmeta：韩版不处理；国行默认不含，特殊模式按 scripts/patch-vbmeta.sh 处理并校验 flags
        │
lz4 -B6 --content-size 压缩 → 打 tar → 追加 md5 → AP_*.tar.md5
        │
verify-ap.sh 全项校验通过 → 发布 GitHub Release
```

脚本都在 `scripts/`，机型矩阵在 `matrix/devices.json`，
钉死的版本在 `config/pins.json`。未解决的风险见 [BUILD-PLAN.md](BUILD-PLAN.md)。

## 九、版权与安全提醒

- 本仓库**不存放、不提交任何三星官方固件镜像**
  （boot/init_boot/vbmeta 是三星版权文件），CI 里用 SamLoader-RS 现下现用，
  用完即删；用户提供的底包只是下载失败时的备用方案，见 `scripts/fetch-stock.sh`。
- 不要把 IMEI、序列号写进仓库或提交记录；SamLoader-RS 不需要 IMEI。
- 本项目面向已解锁 bootloader 的设备；Knox 熔断在首次 root 时已经发生，
  刷 AP 不会再有额外损失，但三星钱包/安全文件夹等 Knox 功能无法恢复。
