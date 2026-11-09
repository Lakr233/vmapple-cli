# Reference

Everything the short [README](../README.md) leaves out: what each macOS version
does on the measured host, what each command does, the pieces a restore and a
boot need, and the licences.

## Status

Measured on DGX Spark under KVM, one to eight vCPUs, 8 GiB. "Restore" means
`Status: Restore Finished` onto a blank 64 GiB disk. "Boot" means the restored
disk boots through OpenAVB, iBoot and XNU to `launchd` without a host.

| macOS | Restore | Boot | Screen | Last run with |
| --- | --- | --- | --- | --- |
| 13.6 (22G120) | works, 4 of 4 from blank, 6 to 10 min | works: Setup Assistant, account, login, desktop; clean shutdown and reboot; a cold and a warm boot on 2026-11-09, no panic | the desktop with its Ventura wallpaper again, the Dock, menus and Finder windows draw; the login window is grey with a black avatar | qemu 0001–0016, reims 0001–0039, metal2vulkan 0001–0003 |
| 14.6.1 (23G93) | works, 5 min | works with `account`: login, desktop, Terminal; a cold and two warm boots on 2026-11-09, no panic; a warm boot on reims 0001–0039 hung before the display started, which reims 0040 fixes | the menu bar, the Dock, Finder and Terminal's text draw; the desktop is yellow | qemu 0001–0016, reims 0001–0040, metal2vulkan 0001–0003 |
| 15.6.1 (24G90) | works, 6 min; one of two attempts timed out waiting for the restore OS's USB | works: Setup Assistant, account, login, desktop, Dock, menus, Terminal; a cold and a warm boot on 2026-11-09, no panic | the login window's wallpaper, the menu bar, the Dock and Terminal's text draw in their colours; the desktop and the Setup Assistant panels after the language panel sit on macOS's yellow fallback wallpaper (see below) | qemu 0001–0016, reims 0001–0039, metal2vulkan 0001–0003 |
| 26.6.2 (25G83) | works, 6 min, twice | works with `account`: login, desktop; of two cold boots on 2026-11-09 at this level one was clean and one panicked while shutting down (`Debugger synch pending on cpu 2`) | the menu bar, widgets and every Dock icon draw; the background is dark grey or near-white instead of the wallpaper, and Spotlight and the menu bar garble | qemu 0001–0016, reims 0001–0040, metal2vulkan 0001–0003 |
| 27.2 (26B123) | works, 6 min | works with `account` (Setup Assistant alone restarts the guest after Data & Privacy): login, the user's own setup panels, desktop; seven boots on 2026-11-09, five cold and two warm, no panic | the desktop wallpaper, menu bar, widgets and Terminal's text draw; the Dock's icons are grey placeholders, glass controls carry small rainbow blocks, and in one boot the screen turned to stripes after Terminal was opened | qemu 0001–0016, reims 0001–0039 (two boots; five on 0001–0033), metal2vulkan 0001–0003 |

Every row was rerun on 2026-11-09 with Reims's wire watch and guard on, cold
(Reims translates the shaders and builds the pipelines the boot meets) and warm
(a later boot that finds them in the caches in the VM's directory). Each boot
with an account was taken to the desktop and Terminal. The Reims patches grew
through the night, so the last column names the level each row last ran at;
reims 0040 only fixes a register read-back race, and 13.6, 15.6.1 and 27.2 were
not booted with it. Causes, fixes and what is still wrong:
[stability-2026-11-09.md](Research/stability-2026-11-09.md).

steelbrain's rewritten Reims and its QEMU were tried apart from this stack. In
one cold boot each, 26.6.2 drew its wallpaper, Dock and Terminal and came
through memory pressure, and 15.6.1 did the same on its yellow desktop; 27.2
never initialized its display in five boots. 13.6 and 14.6.1 were not booted on
it. The patches are in `Patches/staging`, not used by `boot`; see
[new-tree-spike-2026-11-09.md](Research/new-tree-spike-2026-11-09.md).

15.6.1's yellow is macOS's own "ultimate fallback error wallpaper". WallpaperAgent
cannot make the default Sequoia Sunrise video wallpaper
(`WallpaperExtensionError (3)` from `com.apple.wallpaper.extension.video`) and
falls back to it, as the guest's own log says. Why the extension fails is open.

`boot` runs Reims with its zero-copy rails off (`REIMS_VGPU_GUEST_IMPORT=off`,
`REIMS_VGPU_SHARED_TARGET=off`) unless the environment sets them: with them on, the
GPU wrote pixels into guest RAM the kernel had reused, and every 27.2 boot past the
language panel panicked. The copying rails cost frame rate.

Graphics come from [Reims](https://github.com/Hackintosh-on-DGXSpark/hmacos-arm),
which translates the guest's Metal to Vulkan and targets macOS 13.

## Use

```sh
vmapple-cli create vms/sonoma
vmapple-cli restore vms/sonoma UniversalMac_14.6.1_23G93_Restore.ipsw
VMAPPLE_PASSWORD=… vmapple-cli account vms/sonoma --user me
vmapple-cli boot vms/sonoma
vmapple-cli screenshot vms/sonoma screen.png
vmapple-cli click vms/sonoma 0.5 0.5
vmapple-cli press vms/sonoma shift+a ret
vmapple-cli stop vms/sonoma
```

`account` is optional. It boots the guest single-user and types on its serial
console: it mounts the Data volume, starts directory services, creates an
administrator and writes `.AppleSetupDone`, the method aquarat's
experiment-macOS-arm64-on-asahi-linux-arm64 uses for macOS 26. The user's own
setup panels still run at the first login.

`boot` starts the guest again when it restarts itself: QEMU's own reset hangs in
the boot ROM, so a restart ends QEMU and `boot` launches a fresh one. With
`--keep-panic-memory`, a restart after a kernel panic first moves the guest's
RAM to `panic-<UTC time>.ram` and copies its serial log to
`panic-<UTC time>.serial.log` in the VM's directory.

`boot` and `account` add `ml-timeout-debug-ack=1000000000000 ml-timeout-debug-ack-scale=1`
to the kernel's boot arguments, giving a CPU 1 s to answer the kernel debugger's
cross-call. Without them the wait is 24 ms at this VM's 1 GHz timebase, and a short
host delay panics the guest with `Debugger synch pending on cpu N`; see
[stability-2026-11-09.md](Research/stability-2026-11-09.md#debugger-synch-pending).
A `--boot-args` value replaces the defaults, these included.

`boot`, `account` and `restore` start QEMU with Reims's wire watch and guard on
(`REIMS_VGPU_WIRE_WATCH=1`, `REIMS_VGPU_WIRE_GUARD=1`) unless the environment
sets them. The watch reads the guest's wire count on each display buffer Reims
maps; once the guest unwires one that is still mapped, the guard stops Reims
reading or writing its pages, which may be the kernel's by then. Reims checks
the kernel's layout first and turns both off on any kernel but 27.2's and
26.6.2's. Reims keeps its shader translations in the VM's directory
(`reims-vgpu-m2v-cache`), so the first boot with a new build is the slow one.

Stop a logged-in guest with `stop`, or from the login window's Shut Down button.
Switching QEMU off instead counts as a failed boot, and after a few LLB boots
recovery.

`restore` extracts the IPSW next to it once, requests the tickets from Apple, and
drives DFU, iBSS, iBEC and the restore OS itself. idevicerestore talks to
`restored` through a usbmuxd that vmapple-cli serves on a Unix socket.

`--qemu` and `--rom` (or `VMAPPLE_QEMU` and `VMAPPLE_ROM`) name the patched QEMU
and OpenAVB below.

`pull` makes a VM from a Tart-format macOS image in an OCI registry, the format
Tart, [macos-image](https://github.com/MiniMillionaire/macos-image) and
mini-control publish:

```sh
vmapple-cli pull ghcr.io/minimillionaire/macos-golden-gate-vanilla:27.2 vms/pulled
```

It downloads the config, NVRAM and the disk chunks (zstd or Apple LZ4), checks
every layer against its digest, writes one sparse `disk.img`, and reads the
installed version and kernel handoff from the disk's Preboot volume, so a pulled
VM needs no `restore` or `account`. The format and that read are covered in
[Research/tart-images.md](Research/tart-images.md).

A pulled VM boots with `Patches/qemu` 0017. Virtualization.framework tells a
macOS guest that its disk does not encrypt inline, so a disk it restored has an
unencrypted Data volume. QEMU's virtio disk said nothing, so the guest assumed
AES-XTS and panicked mounting that volume (`unencrypted data volume is not
allowed`). `pull` records `inlineEncryption: false` in `vm.json`, and `boot` then
gives the root disk the same vendor configuration as the framework. A VM that
`restore` made keeps the old disk, whose Data volume is encrypted. Measured on
2026-11-09 with `macos-golden-gate-vanilla:27.2`: two cold boots to the desktop,
logged in automatically, and no panic. Later that day a fresh pull and that disk
were booted again after runs that `boot --seconds` ended at 15 to 150 s and after
a QEMU killed in userspace, and every boot reached `loginwindow`. The Dock icons
are grey placeholders, as on a restored 27.2. The causes and the checks are in
[Research/tart-images.md](Research/tart-images.md).

## Build

```sh
swift build -c release
.build/release/vmapple-cli doctor
.build/release/vmapple-cli probe
```

Linking needs libtatsu and libplist found by `pkg-config`. Restoring needs these
on the host, built as a user:

| Piece | Source | Patches |
| --- | --- | --- |
| QEMU | `hmacos-arm`'s QEMU at `bc63c27b6f` | `Patches/qemu` |
| Reims | `hmacos-arm`'s, at `44127711` | `Patches/reims` |
| metal2vulkan | `hmacos-arm`'s, at `8b78eac` | `Patches/metal2vulkan` |
| Boot ROM | [OpenAVB](https://github.com/owngoal-dev/OpenAVB), branch `vmapple` at `c35e417` | none |
| idevicerestore | libimobiledevice's, at `ae8cfb4` | `Patches/idevicerestore` |
| libtatsu, libplist, libimobiledevice | libimobiledevice's | none |
| `lzfse`, `unzip` | the distribution | none |

`doctor` needs arm64 Linux to pass. `probe` needs `/dev/kvm`.

The release binary comes from [build-linux.sh](../.github/build-linux.sh), which
links libtatsu, libplist and the Swift runtime in. Which hosts should work:
[host-compatibility.md](Research/host-compatibility.md).

See [Documents/Research/restore-on-linux.md](Research/restore-on-linux.md)
for how each stage works and what was measured.

## Licence

vmapple-cli is under the [MIT License](../LICENSE). Each series in `Patches/`
changes another project and is under that project's licence. Third-party
patches retain their original authorship.

| Patches | Project | Licence |
| --- | --- | --- |
| `qemu`, `staging/newtree/qemu` | QEMU | GPL-2.0 |
| `reims`, `staging/reims-guard-old`, `staging/newtree/reims-vgpu` | Reims | GPL-2.0-or-later or LGPL-3.0-or-later |
| `metal2vulkan` | metal2vulkan | GPL-2.0-or-later or LGPL-3.0-or-later |
| `idevicerestore` | idevicerestore | LGPL-2.1-or-later |
