# Host compatibility

Which arm64 Linux machines should run vmapple-cli, from the code's requirements
and public documentation, researched on 2026-11-09. Only NVIDIA DGX Spark (GB10:
Cortex-X925 and Cortex-A725) has been run. Every other row is read from Arm's
Technical Reference Manuals, kernel sources and vendor pages, and is untested.

## What the host needs

| Need | Why | Where it is checked |
| --- | --- | --- |
| Linux booted at EL2, `/dev/kvm` writable by the user | KVM | `doctor` |
| Linux 6.4 or later | `KVM_ARM_VM_SMCCC_FILTER` with `KVM_SMCCC_FILTER_FWD_TO_USER` (commit 821d935c87bc) hands VMApple's hypercalls (`0xc1000000…`) to QEMU. PSCI 1.1 and QARMA3 pointer authentication in KVM date from 5.18 | `probe` |
| Pointer authentication (`paca`, `pacg`) | the arm64e kernel signs pointers | `doctor`, `probe` |
| A 16 KiB stage 1 granule (`ID_AA64MMFR0_EL1.TGran16` 1 or 2) | macOS uses 16 KiB pages | `probe` |
| A GICv3, or KVM's software vgic-v3 | `vmapple` has a GICv3; a GICv2 host such as GIC-400 cannot offer one | not checked |
| M1-class instructions | macOS userland is built for Apple M1 (below) | not checked |
| NVIDIA's Vulkan driver | Reims draws through Vulkan; only NVIDIA was tried | `doctor` |

Armv9.2 cores (A520, A720, X4, A725, X925, V3, N3) report pointer
authentication in `ID_AA64ISAR2` as QARMA3 (`APA3=5`) and leave
`ID_AA64ISAR1.APA` at 0. Linux maps both to `paca`/`pacg`, and `probe` signs and
authenticates a pointer instead of reading the fields, so these cores pass, as
GB10 does.

No report was found of macOS failing on a non-Apple core for a missing
instruction. One hard dependency is visible in source: WebKit enables FJCVTZS,
LSE and FP16 for every arm64 macOS build, and JavaScriptCore's `toInt32` uses
`fjcvtzs` with no runtime check, so a core without JSCVT (A78AE, A78C, X1C)
would likely fault there. Neoverse V1 lacks FlagM2, FRINTTS and SB, which LLVM's
`apple-a14` target includes; whether shipped macOS binaries use them is unknown.
Armv9.0 and later cores have all of these.

## Cores

| Cores | PAC | TGran16 | Verdict |
| --- | --- | --- | --- |
| Cortex-A53, A72 | no | 0 | no |
| Cortex-A55, A76, A78, X1, Neoverse N1 | no | 1 | no: no PAC |
| Cortex-A78AE, A78C, X1C | yes | 1 | unknown: no JSCVT |
| Neoverse V1 | yes | 1 | likely, untested; no FlagM2, FRINTTS, SB |
| Cortex-A510, A710, X2, A715, X3; Neoverse N2, V2 | yes, QARMA5 | 1 | likely, untested |
| Cortex-A520, A720, X4, Neoverse V3, N3 | yes, QARMA3 | 1 | likely, untested |
| Cortex-X925, A725 | yes, QARMA3 | 1 | works: GB10, measured |

## Machines

| Machine | Cores | Verdict and reason |
| --- | --- | --- |
| NVIDIA DGX Spark | 10 X925 + 10 A725 | works, measured |
| Other GB10 machines (ASUS Ascent GX10, Dell Pro Max GB10, Lenovo ThinkStation PGX …) | same SoC | likely, untested |
| NVIDIA Grace (GH200, GB200) | 72 Neoverse V2 | likely, untested; GPU Vulkan not checked |
| AWS Graviton4 (`c8g.metal-24xl`, `-48xl`) | Neoverse V2 | likely on metal, untested; no NVIDIA GPU |
| AWS Graviton3 (`c7g.metal`) | Neoverse V1 | likely on metal, with V1's caveat; no NVIDIA GPU |
| Google Axion C4A metal | Neoverse V2 | likely on metal only (nested virtualization excludes Arm); no NVIDIA GPU |
| Jetson Thor | 14 Neoverse V3AE | unknown, leaning no: NVIDIA says VMs are not supported by default |
| Jetson AGX Orin | 12 A78AE | unknown: no JSCVT; needs JetPack 7.2's 6.8 kernel |
| Snapdragon X Elite, X Plus laptops | Oryon | unknown: Gunyah owns EL2 (slbounce and Linux 6.16's `-el2` device trees get around it); TGran16 not confirmed |
| AmpereOne (Oracle `BM.Standard.A4.48`) | Ampere custom, v8.6+ | unknown: PAC and 16K not confirmed on hardware |
| Apple M1, M2 under Asahi Linux | Apple | not tried; omvm and aquarat run `vmapple` there only with two out-of-tree KVM patches (Apple's PAC key registers, and a GIC store without a syndrome) |
| Apple M3 | Apple | unknown |
| Apple M4 and later | Apple | no Asahi support |
| Raspberry Pi 4 | 4 A72 | no: PAC, 16K and GIC (GIC-400) all fail |
| Raspberry Pi 5 | 4 A76 | no: no PAC, GIC-400 |
| RK3588 boards | A76 + A55 | no: no PAC |
| Ampere Altra, Altra Max (Oracle A1, Hetzner) | Neoverse N1 | no: no PAC |
| AWS Graviton2 | Neoverse N1 | no: no PAC |
| Azure Cobalt 100, GitHub's `ubuntu-24.04-arm` runners | Neoverse N2 | no: no nested virtualization, so no `/dev/kvm` |

## Sources

- Arm TRMs, `developer.arm.com/documentation/<ID>`: A53 ddi0500, A55 100442,
  A72 100095, A76 100798, A78 101430, A78AE 101779, A78C 102226, X1 101433,
  X1C 101968, A510 101604, A710 101800, X2 101803, A715 101590, X3 101593,
  A720 102530, X4 102484, A520 102517, A725 107652, X925 102807, N1 100616,
  V1 101427, N2 102099, V2 102375, V3 107734, N3 107997. The A78AE TRM's field
  table shows ISAR1's PAC fields as RES0, but its reset value `0x01200031` and
  feature list give PAC; the V1 TRM's ISAR1 reset value disagrees with its own
  field table in the same way.
- Linux: SMCCC filter https://github.com/torvalds/linux/commit/821d935c87bc95253f82deec3cbb457ccf3de003,
  PSCI 1.1 https://github.com/torvalds/linux/commit/512865d83fd9685a4d5aab26f898737b57d3187e,
  QARMA3 https://github.com/torvalds/linux/commit/def8c222f054d18aac1fd065a50b9db5feaefa9d,
  vgic-v3 without a GIC on M1 https://lists.infradead.org/pipermail/linux-arm-kernel/2021-May/657137.html,
  device trees for the GIC of each SoC under `arch/arm64/boot/dts`.
- WebKit: `Source/WTF/wtf/PlatformHave.h` and `Source/JavaScriptCore/runtime/MathCommon.h`.
- LLVM: `llvm/lib/Target/AArch64/AArch64Processors.td`.
- Apple hosts: https://github.com/sapoepsilon/omvm, https://github.com/aquarat/apple-macos-arm64-vm-guest.
- NVIDIA: GB10 whitepaper; Grace tuning guide; Jetson Thor virtualization
  https://forums.developer.nvidia.com/t/virtualization-on-the-jetson-thor/359181;
  Orin KVM https://blog.cloudkernels.net/posts/orin-vm.
- Clouds: AWS instance pages for c6g, c7g, c8g; Google C4A metal and nested
  virtualization docs; Azure Dpsv6 sizes; GitHub runner probe
  https://github.com/actions/runner-images/issues/14062; Oracle compute shapes.
- Snapdragon: https://github.com/TravMurav/slbounce, Linux v6.16 `qcom/x1-el2.dtso`.
