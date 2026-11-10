# Restore on Linux

Goal: from a blank disk and an IPSW to a booting macOS guest, on the Linux host,
with no Mac.

## Measured on DGX Spark

Host: Linux 7.0.0-1019-nvidia, 4 KiB pages, 10 Cortex-X925 (`0xd85`) and 10
Cortex-A725 (`0xd87`), GB10. Results from `hmacos-arm`'s KVM probe at `35c9a21`,
pinned to one core of each kind:

| Check | Result |
| --- | --- |
| 16 KiB stage 1 on a 4 KiB host | runs with the MMU on, `TGran16=1` |
| `0xc1000000..0xc10000ff` forwarded through an SMCCC filter | forwarded and resumed |
| PSCI 1.1 | set and read back |
| PACIA/AUTIA | round trip works, QARMA3 (`APA3=5`) |
| Apple's `APCTL` | absent, so EL0 shares EL1's keys |
| IPA / PARange | 40 bits, `PARange=2` |
| Counter | 1 GHz, not Apple's 24 MHz |

A negative control with a wrong expected value failed as it should.

## IPSW contents

`UniversalMac_13.6_22G120_Restore.ipsw` has `VirtualMac2,1`, board
`vma2macosap`, `ApChipID 0xFE00`, `ApBoardID 0x20`, with Erase and Update
identities. Everything a restore needs is there: `iBSS`, `iBEC`, `LLB`, `iBoot`
and `DeviceTree` for `vma2`, `kernelcache.release.vma2`, and a restore ramdisk.

## Boot ROM and DFU

The ROM is [OpenAVB](https://github.com/owngoal-dev/OpenAVB), branch `vmapple`.
Nothing from Apple is needed before the IPSW. QEMU's `vmapple` memory map matches
what OpenAVB expects, and its cfg page already reports board `0x20` at `+0x10`.

`vma2` has no SEP. OpenAVB keys off board `0x20`: it names the chip `0xfe00`,
skips the SEP exchanges, and keeps the five configuration words at `0xaaaaaaaa`.
A real `vma2` ticket from a Mac has `snon` as twenty `0xaa` bytes, which is that value.

On 2026-11-08 on the DGX, under KVM, one vCPU pinned to the X925 cores, with an
empty disk and AUX, the ROM reached `[dfu] ready for image upload`. Over USB/IP the
host saw:

```text
05ac:1227 Apple Mobile Device (DFU Mode)
SDOM:01 CPID:FE00 CPRV:00 CPFM:03 SCEP:01 BDID:20 ECID:367FE40487C8B60D IBFL:3C
```

`SRTG` still says vphone's `mBoot-20457.0.13.0.11`. `NONC` and `SNON` did not show
in `iSerial` and are unchecked.

On the same host, on 2026-11-08, with no root and no `vhci_hcd`, first from scripts
on a userspace USB/IP client and then from vmapple-cli itself. Every line was run.

1. iBSS over DFU: identity, then the IMG4 with the 16 byte DFU suffix (libirecovery's
   CRC form). The ROM prints `DFU image accepted`.
2. OpenAVB's entropy publication needs RAM at `0x600090`, which `vresearch101` has and
   `vmapple` did not. `Patches/qemu/0002` adds `0x410000..0x700000`.
3. iBSS then panicked until the ROM also published entropy where `vma2` reads it:
   status at `0x400400` (bit 0 has data, bit 16 enabled), 48 bytes at `0x400408`.
   OpenAVB `c35e417`.
4. iBSS comes up as `05ac:1281` with a real `NONC` and `SNON` of twenty `0xaa`.
5. A live ticket is requested against that `NONC`. Without an `Ap,LocalPolicy` iBSS
   rejects iBEC with `Memory image not valid`: its image class check reads a flag only
   the `lpol` path sets.
6. The local policy is the 22 byte empty IM4P from idevicerestore, with its own ticket:
   `tss_request_add_local_policy_tags` alone, `Ap,NextStageIM4MHash` as the SHA-384 of
   the first ticket. Adding the common tags, or putting `Ap,LocalPolicy` in the AP
   request, gets `STATUS=94`.
7. `lpolrestore`, then iBEC, then `go` with `bRequest` 1. `boot-stage` reads 1 before it.
   iBootStage2 enters recovery with `aborting autoboot due to tethered restore`.
8. iBEC keeps the same `NONC`. It accepts `rtsc` + `firmware`, `rdsk` + `ramdisk`,
   `rdtr` + `devicetree`, `rkrn` and `bootx`. The ramdisk takes 19 s over USB/IP.
9. `End of iBootStage2 serial output`. XNU stops at `str w9, [x8, #0x80]!` on the GIC
   redistributor, which KVM cannot describe, until QEMU's existing handoff runs
   (`QEMU_VMAPPLE_HANDOFF=1`). It rewrites that store and the device tree timebase at
   `0xaca00000`, and writes the boot arguments, so they belong in
   `QEMU_VMAPPLE_BOOT_ARGS`. The entry point is the same as a local boot.
10. RestoreOS boots from the ramdisk under KVM and prints
    `waiting for host to trigger start of restore [timeout of 120 seconds]`.
11. The guest shows `05ac:12ac`, with the mux on configuration 4, interface 1, endpoints
    `0x01` and `0x81`. A userspace usbmuxd (plist protocol on a Unix socket, Apple's mux
    v2 and its TCP over USB/IP, no `vhci_hcd`, no libusb, no root) reaches `restored` on
    port 62078: `HardwareModel` `VMA2MACOSAP`, `RestoreProtocolVersion` 15.

12. idevicerestore master, built without root, runs against that usbmuxd with
    `-e -R -T`, patched in two ways: with `--restore-mode` it still requests the local
    policy and recovery OS tickets, from an `ApNonce` passed in the environment, and it
    takes `ApSepNonce` the same way (`Patches/idevicerestore`, on `ae8cfb4`).
13. `clean_NAND` discards the whole disk in one request of 134217727 sectors and ignores
    `max_discard_sectors`, then waits forever on the error. `Patches/qemu/0003` accepts it.
14. `Status: Restore Finished`, with 13.6 (22G120), Erase, on an empty 64 GiB image.
    OS, `Cryptex1,SystemOS` and the rest took five minutes over the mux. The image has
    15 GiB allocated.
15. Booting that disk with OpenAVB, with no DFU and no host, reaches macOS userspace
    under KVM: `launchd`, `AppleVPKeyStore`, `bluetoothd`, APFS on `disk3`.

16. On the first boot Setup Assistant shows its language list, read from the guest's
    frames with QMP `screendump`. `REIMS_VGPU_WINDOW=0` (`Patches/qemu/0004`) keeps the
    QEMU console as the display, and Reims needs `llvm-dis` and `spirv-val` on `PATH`:
    without them it draws black.

Pausing the VM through QMP while USB is up resets the guest's USB controller and drops
every mux connection, so a restore has to be watched from its logs. `restored` compares
the SHA-384 of the root ticket with `boot-manifest-hash`, so every stage uses the one
ticket iBSS was given. `usbmux` sequence numbers wrap at 4 GiB.

A USB/IP client must send `SET_CONFIGURATION` before `SET_INTERFACE(1, 1)`, or iBoot
panics starting the serial endpoint. `SET_INTERFACE(0, 0)` stalls and is not needed.
`saveenv` stalls in iBSS and iBEC. A guest RAM file that survives a run keeps the
uploaded identity, so remove it before each boot.

`Patches/qemu` applies on top of `hmacos-arm`'s `bc63c27b6f`. The restore OS
drives `vusb-pci`, including the queue disable it needs. `gfx-device=reims-vgpu-mmio`
is still required: `graphics=off` does not stop `vmapple` asking for `apple-gfx-mmio`.

## Signing

Apple's public TSS signs `vma2` for a random ECID from Linux. On 2026-11-08, from
the DGX, with libtatsu and no device or Mac involved:

| Request | Result |
| --- | --- |
| `j274ap` 27.2, the control | ticket, 9891 bytes |
| `vma2macosap` 13.6 (22G120) | ticket, 5504 bytes |
| `vma2macosap` 27.2 (26B123) | ticket, 5632 bytes |

A `tart` restore of 13.6 on a Mac the same day left a 5504 byte ticket in AUX,
with the leaf `FE00-A00-SDOM1-TssLive-ManifestKey-RevA-DataCenter1`. So a VM's
ticket is an ordinary TSS ticket, not something Virtualization.framework signs
locally. ipsw.me lists every `VirtualMac2,1` build as unsigned, and that is wrong
for this purpose.

Build requests with libtatsu. A hand-written request gets `STATUS=94` ("This
device isn't eligible for the requested build") even for a real Mac on a signed
build, so 94 says nothing about the VM until a real Mac passes through the same
code.

## Design

The guest is the USB device, and vmapple-cli is the host. There is no USB/IP, no
`vhci_hcd`, no libusb and no root: vmapple-cli speaks QEMU's vusb chardev directly.

```text
guest (OpenAVB DFU -> iBSS -> iBEC -> RestoreOS)
  -> QEMU vusb (bdif USB slot) and vusb-pci (RestoreOS)
  -> vmapple-cli: DFU and iBoot commands, then usbmuxd on a Unix socket
  -> idevicerestore (USBMUXD_SOCKET_ADDRESS) -> restored
```

| Piece | Where |
| --- | --- |
| `vmapple` under KVM | `hmacos-arm`'s QEMU at `bc63c27b6f`, plus `Patches/qemu` |
| Metal to Vulkan | Reims at `44127711`, plus `Patches/reims`; metal2vulkan at `8b78eac`, plus `Patches/metal2vulkan` |
| Boot ROM | OpenAVB, branch `vmapple` at `c35e417` |
| vusb client, DFU, iBoot commands, usbmuxd | `Sources/VMAppleKit` |
| Tickets | libtatsu, through `Sources/CTicket` |
| Restore protocol | idevicerestore, plus `Patches/idevicerestore` |

## Other versions

Every `VirtualMac2,1` IPSW from 13 to 27 has the same restore components. On
2026-11-08, from blank disks, with vmapple-cli:

| Build | Result |
| --- | --- |
| 13.6 (22G120) | restored three times from blank with the experiment scripts and once with vmapple-cli, booted six times to Setup Assistant |
| 14.6.1 (23G93) | restored in 316 s, boots to Setup Assistant, the hello animation draws |
| 15.6.1 (24G90) | restored in 342 s, boots to Setup Assistant, hello and the language list draw |
| 26.6.2 (25G83) | restored in 357 s, and again from blank later the same day; the hello screen's Continue button draws |
| 27.2 (26B123) | restored from blank, boots to Setup Assistant; the hello screen's Continue button draws |

What changed after 13:

- iBoot enters the kernel through a trampoline with the boot arguments in x1. Up to
  15 it runs from a copy at `0xaca00000`; in 26 it runs in place in the image. The
  handoff now breaks at both, steps over passes that carry no boot arguments, and
  reads them physically, because iBoot no longer maps them one to one. The
  addresses come from the image (`QEMU_VMAPPLE_HANDOFF_PC`).
- XNU 14 boot arguments are revision 3. The handoff takes 2 and 3.
- QEMU answered `CPU_INITIALIZE` in `hypercall.ret`, which arm64 ignores. 13 does
  not look; 14 spins until x0 is zero, so x0 is now set.
- 15 switches PAC keys per task with hypercall `0xc1000003` and spins until x0 is
  zero. EL0 and EL1 share keys on this host, so QEMU acknowledges it and changes
  nothing.
- 27's iBoot moved its banner from `0x200` to `0x280`, so the load base is read
  0x100 past the banner, not at `0x300`.

- 27's iBSS and iBEC write through the backdoor block interface: 512 bytes to the
  aux disk at 16 MiB, then NVRAM at 10 MiB. QEMU answered every write with a
  failure, which iBSS reported as `0x40200102` before panicking at
  `70b7ca7d373f8bb:144` on a pointer its error path had not set up (`0xb0830`).
  `Patches/qemu` 0007 writes them.
- 27's iBEC copies the kernel trampoline to `0xe0a00000`, not `0xaca00000`. The
  handoff reads the window from the function that returns its bounds.

- 27's IOPCIFamily answers `extendedFindPCICapability` from a new cache
  (`IOPCIDevice::lookupCapability`): the first capability in list order whose
  offset is past the one it was handed. QEMU links each capability at the head of
  the list, so a virtio-pci device lists them in descending order, and the
  search for the next vendor capability after `0x70` returned `0x84` again. The
  restore OS spent five minutes in that loop (72 million config reads) and its disk
  and USB drivers never started. `Patches/qemu` 0008 keeps every list in ascending
  order; 13.6 still boots to its desktop with it.

With these, 27.2 restored from a blank disk on 2026-11-08 and booted to Setup
Assistant, where it draws what 26 draws.

### Graphics after 13

Reims was written against 13. What 14, 15 and 26 do differently, as measured on
2026-11-08, and what `Patches/reims` does about it:

- **IOSurface mappings.** Reims finds a surface's pages by reading the guest
  driver's `MappingInternal`. From 14 on, the page fields and the page count sit 16
  bytes further on (`+0x58`, `+0x60`, `+0x80`; `+0x48` and `+0x50` read zero), so
  every mapping failed `iosurface_page_table_fields_invalid` and nothing reached the
  screen. 26's driver also hands the `MappingInternal` over in x21 instead of x22.
  Reims now reads the moved fields, and finds the register by asking each one for
  a `MappingInternal` that names the mapping. QEMU reads guest virtual memory for it
  from RAM only: one 26 restore that read a register pointing at MMIO lost its USB
  link.
- **Memoryless textures.** Nearly every WindowServer pass from 14 on attaches a
  type-9 object as colour 1 and reads it back in the fragment shader (framebuffer
  fetch of `dest_1`). Type 9 is a memoryless texture: its 44-byte descriptor is the
  record a type-2 descriptor carries after its levels, with storage mode `0x30`.
  Reims refused it as `rt_wrong_type` and dropped the whole draw. It now renders
  into a host image that lives for the pass, and fetches any colour attachment, not
  only colour 0.
- **26's Setup Assistant** writes an RGBA16Unorm storage image from a kernel, which
  Reims now does, and draws its hello text with a 2309-block fragment shader whose
  typed SPIR-V does not validate. metal2vulkan skipped its raw retry for functions
  that large; `Patches/metal2vulkan` lets it run, and the result validates.

- **Liquid Glass.** 26 and 27 render their panels' shapes into RG16Uint targets
  that a later pass samples, beside a memoryless RG32Float colour attachment.
  Neither format was renderable, so every panel pass was refused. Both are now
  texel layouts rendered and sampled at their own format (`Patches/reims` 0010),
  and 27.2's language panel draws.
- **Background video.** 14, 15 and 27 play Setup Assistant's background as video
  into biplanar YCbCr IOSurfaces (`420f` at 3840 by 2160 on 14, `422f` at 512 by
  512 on 15, `444f` at 512 by 512 and ten-bit `x420` at 3840 by 2160 on 27) and
  bind each surface whole, in one of Metal's private formats. Reims had no bytes
  for those, so 14's background was grey and 15's a flat colour. The formats
  sample differently, and each order below is read off the shader that consumes
  it. 500 converts in the sampler: 14's compositor reads R'G'B' and goes straight
  to its transfer function. 541 returns Cr, Y and Cb in red, green and blue:
  15's VideoToolbox kernel swizzles them and applies BT.601 itself. Reims now
  reads both planes (8- or 16-bit samples) from the surface's plane records and
  hands each format its texels (`Patches/reims` 0011). 14's and 15's backgrounds
  draw.
- **Ten-bit video samples as Cr, Y and Cb.** 15 and 27 bind `x420` as 543, and
  27 binds `444f` as 542. Every VideoToolbox kernel seen reading them (15's
  `x420` to RGBA16Float kernel, 27's two) swizzles the sample to `.gbr` before
  its matrix, as 541's does. The ten-bit one swizzles when it stores the sample
  in a local array and reads `.rgb` back later, which 0011 misread as Y, Cb and
  Cr; 0014 then handed 543 as Y, Cr and Cb, matched against a 27 boot whose hello
  showed the Golden Gate still. 543 is now handed Cr, Y and Cb (`Patches/reims`
  0015). On 15 the converted frames come out warm gold, the same hue as the
  placeholder Setup Assistant draws under them; handed the old order they were
  teal. Today's 27 boots draw the Golden Gate still without sampling 543 at all,
  so that boot is unchanged.
- **27's textures.** 27's Setup Assistant creates textures tagged 12 whose
  descriptor carries the level-0 layout twice, declares icon, panel and
  memoryless textures in private format 550 (four bytes a texel, only ever on
  the GPU), places textures in heaps after asking the device for their size, and
  renders into textures made over a buffer. Reims refused all four, and left the
  heap query unanswered, so the guest placed every texture of a heap at one
  offset. Type 12 is now served as type 3, 550 is stored as BGRA8, the heap query
  is answered with a padded, page-aligned layout (`Patches/reims` 0012), and a
  buffer-backed texture is a linear render target at the buffer's address
  (`Patches/reims` 0013). 27.2's language and country panels draw over the
  background.
- **Heap textures.** 26 and 27 place Liquid Glass shapes, shadows and panel
  snapshots in heaps (type 8, opcode 0x15). A heap is host memory the guest never
  maps, so a heap texture has no bytes this device can read, and Reims refused
  them as render targets (142 times on a 26.6.2 boot, 61 on 27.2). A heap
  texture now renders into a persistent engine resident that later passes load
  from and sample (`Patches/reims` 0014). 26's country panel gets its globe and
  its list selection; no 26 or 27 render target is refused any more. Compute
  keeps its own heap residents, so a heap texture a kernel writes is not yet
  visible to a draw. The same patch reads 26's and 27's ten-bit icons (RGB10A2
  buffer textures) at eight bits.
- **27 is stable once the GPU stops writing imported guest RAM.** Every 27.2 boot
  that went past the language panel ended within about a minute: kernel data aborts,
  `os_refcnt` overflow, a mutex and a `kalloc.type4.48` element overwritten, a
  vnode use count lost, and `launchd` exiting on SIGSEGV. The overwritten words
  were pixels: `0x3b45ae48` and `0x383f383f` are half-float pairs, and
  `0x3c0030c83a87b04b` is an RGBA16Float texel with alpha 1. In the run that
  overwrote a mutex, two RAM pages held its bytes; a trace of every write Reims
  records names one as a task's image row and never the other. The likely writer
  is one it does not record: the zero-copy rails, where the GPU renders or stores
  straight into guest RAM imported earlier. With `REIMS_VGPU_GUEST_IMPORT=off` and
  `REIMS_VGPU_SHARED_TARGET=off` (the copying rails) 27.2 ran past the language
  panel for six minutes with no panic; all eight runs without them panicked, one
  of them while shutting down.
  `SHARED_TARGET=off` alone was not enough: that run panicked before the hello
  screen with page tables overwritten. `vmapple-cli boot` now sets both unless the
  environment already does. Which imported range goes stale is not yet found; the
  copying rails cost frame rate.
- **Fragment storage images.** After the language panel, 14 and 15 snapshot the
  framebuffer with `inplace_copy_lph`, a fragment shader that has no colour
  output and writes a storage image. Reims refused the draw, and the rest of the
  stream with it. The draw now gets a storage image of its own and leaves the
  attachments alone; a level-0 linear texture of the shader's texel width seeds
  the image and takes its texels back after the draw. A pipeline with no
  fragment function draws with an empty fragment shader and colour writes off
  (`Patches/reims` 0015). 15.6.1's country panel draws whole.
- **15's yellow background is macOS's fallback wallpaper.** WindowServer fills
  the background from a CoreAnimation vertex colour of (1.0, 0.985, 0, 1). The
  guest's own log (read from a logged-in 15.6.1 with `log show` written to
  `/dev/console`, which lands in the serial log) names it: WallpaperAgent asks
  `com.apple.wallpaper.extension.video` for the default Sequoia Sunrise video,
  each "Acquire Wallpaper" ends within about 100 ms in
  `WallpaperExtensionError (3)`, and the agent logs "Failed to create system
  default wallpaper as fallback - using ultimate fallback error wallpaper". The
  extension meanwhile opens `Sequoia Sunrise.mov`, uses its cached snapshot and
  waits for its player layer; VideoToolbox converts the 3840 by 2160 ten-bit
  frames to RGBA16Float (260 to 330 ms each in Reims, 140 to 250 ms of it the
  66 MB writeback), and nothing samples them. Why the extension reports error 3
  is open. The login window, which shows the same scene as a still, draws it in
  its colours.
- **Lost IOSurface unmaps.** The guest's IOSurface mapper writes request `n` into
  slot `n % capacity` of its ring; Reims read it at `n * 16`. After the first
  wrap every MAP and UNMAP came from memory past the ring, and a lost UNMAP left
  Reims writing frames into pages the guest had freed. 15.6.1 took a kernel data
  abort in `appleaccountd` while creating the account, after 4,843 recorded
  writes into released pages. Reims now reads the wrapped slot (`Patches/reims`
  0016, as in aquarat/reims-vgpu 81c0e6a8f9); the next boot finished Setup
  Assistant and reached the desktop.
- **The drain no longer holds the BQL.** The sysbus shim drained Reims in a
  main-loop bottom half, so every vCPU exit that needed the BQL waited for a
  whole tranche, up to half a second while a 4K frame converts. It now drains on
  its own thread, as the PCI shim does (`Patches/qemu` 0009, from
  aquarat/qemu-reims-vgpu 6740a49344). 15.6.1 booted, logged in and shut down
  cleanly with it.
- A released-page guard that refused device writes into pages a task had
  unmapped (briefly `Patches/reims` 0011) is withdrawn. It judged writes whose
  pages a fresh page-table walk had just named, which are the guest's own
  mappings; on 15.6.1 it refused the reply to a compute-info query, the guest
  dispatched a 32 by 624 threadgroup, and the Vulkan device was lost. It did not
  stop 27.2's panics either.

- **27.2's Setup Assistant cannot create the account.** After Data & Privacy,
  `sessionlogoutd` restarts the guest and Setup Assistant starts again at the
  language panel, every time; the log has `apfs_keybag_init: failed to initialize
  volume keybag`. `vmapple-cli account` creates the account from a single-user
  boot instead (`-s` in the boot arguments QEMU hands XNU, `apfs_boot_util 1` and
  `2`, `opendirectoryd`, `dscl`, `.AppleSetupDone`). The next boot shows the
  terms, the login window, the user's own setup panels and the desktop.
- **A guest restart used to hang.** QEMU resets the machine in place, and the
  boot ROM then stops at `runtime initialization`. QEMU now ends on a guest reset
  (`-action reboot=shutdown`), and `vmapple-cli boot` starts it again when the
  serial log's last word is a reset or a panic.
- **Display buffers the guest unwired.** On 27.2 and 26.6.2 a display swap waited
  behind the first frame's translation and pipeline build past
  IOMobileFramebuffer's 5 s timeout, the guest unwired a display buffer Reims
  still mapped, and Reims's next write into it landed on kernel memory.
  `Patches/reims` 0017–0040, `Patches/qemu` 0010–0016 and `Patches/metal2vulkan`
  0002–0003 translate faster and cache translations, build pipelines and serve
  the mapper registers without holding locks a vCPU waits on, and watch the
  guest's wire count so that Reims stops touching such a buffer. None of seven
  27.2 boots panicked on 2026-11-09:
  [stability-2026-11-09.md](stability-2026-11-09.md).

Still open, each seen on a driven boot:

- 15.6.1's video wallpaper fails in the guest (`WallpaperExtensionError (3)`), so
  its desktop and the Setup Assistant panels after the language panel sit on the
  yellow fallback. 14.6.1's desktop was yellow too on 2026-11-09; its cause was
  not checked.
- 26 and 27 draw the hello text, and the text never reaches the screen though the
  draw now runs.
- 27.2's blurred background is coarse, and the panel's shadow draws as a
  translucent square.
- 27.2's Setup Assistant renders into RGB10A2Unorm buffer textures, which Reims
  refused until `Patches/reims` 0036; Setup Assistant was not rerun with it.
  26's background stays black although its video surfaces convert, and its
  language panel has no icon.
- A rarer panic, `Debugger synch pending on cpu N`, remains: XNU waits 24 ms for
  a cross-call on this VM's 1 GHz counter, 1 s on Apple's 24 MHz one
  ([stability-2026-11-09.md](stability-2026-11-09.md)).

## Running a guest

On 2026-11-08, 13.6 restored with vmapple-cli went through Setup Assistant with
`click` and `press` (no network, local account), logged in and reached the Finder
desktop with its Dock and menus.

- Input is QEMU's USB keyboard and tablet through QMP `input-send-event`. The
  pointer is not drawn into the frames.
- macOS ignores QEMU's power button (`system_powerdown`). Control-Option-Command-
  Power from the keyboard shuts a logged-in session down; the login window has a
  Shut Down button. Either ends in `ApplePSCI - system off`.
- A guest switched off mid-boot counts as a failed boot. After two or three, LLB
  sets `boot-command` to `recover-system`, logs `1aad73bb1002bf0:994` and resets.
  With `-no-reboot` that looks like a hang. Normal boots now allow the reset;
  restores keep `-no-reboot` to see the restore OS finish.
- Before `Patches/reims`, everything after the language list was black: a compute
  dispatch that wrote a surface with no CPU pages at all was refused. Such a surface
  is GPU-private, so it now starts from zero in the engine and is never written
  back. Setup Assistant, the login window and the desktop draw.
- The wallpaper draws since `Patches/reims` 0002. A compute pipeline decodes it into
  a 6016 by 6016 surface whose page table is mostly holes (4093 of 9216 entries
  invalid), because nothing on the CPU has touched those pages, and the desktop
  samples each decoded tile as RGBA8 over a 1024-wide luma plane. Reims refused the
  mapping, then refused the view. It now resolves the mapping with its holes and
  again later, starts a storage window over holes from zero, and matches the view
  to the one plane whose rows hold the same bytes. 13.6's wallpaper was black in
  every run from 2026-11-08 until the patches of 2026-11-09
  ([stability-2026-11-09.md](stability-2026-11-09.md)).
- `stop` works at Setup Assistant too: 26's hello screen powered off in seconds.
  Killing QEMU instead is what to avoid: after four or five killed boots, 26's LLB
  set `boot-command` to `recover` with `iboot-failure-reason` `0x64`, and the disk
  had to be restored again. Killing `boot` without ending its QEMU also left a
  second boot writing the same disk; see
  [two-qemus-one-disk-2026-11-10.md](two-qemus-one-disk-2026-11-10.md).

## Open questions, riskiest first

1. **Graphics.** Reims draws 13 in full. From 14 on it draws Setup Assistant's first
   screens and stops at the gaps listed under "Graphics after 13".
2. **Unattended setup.** Setup Assistant works through `click` and `press`. A
   preseed would need linux-apfs-rw or a ramdisk, since Linux cannot write the
   sealed System volume.
3. **Graphics speed.** One vCPU reached 13's login window in 35 s, four and eight in
   20 s, each with a clean shutdown and no panic. 15.6.1 restored with four in 363 s.
   vmapple-cli now defaults to four.

## Related work

- [hmacos-arm](https://github.com/Hackintosh-on-DGXSpark/hmacos-arm): `vmapple` on KVM on DGX Spark, restores on a Mac.
- [vphone-linux](https://github.com/YahiaAngelo/vphone-linux): restores `vresearch101` on Linux with no Mac, TCG, x86_64.
- [apple-macos-arm64-vm-guest](https://github.com/aquarat/apple-macos-arm64-vm-guest): macOS CI on Asahi Linux, restores on a Mac.
- [vma2pwn](https://github.com/nick-botticelli/vma2pwn): idevicerestore on `vma2` in DFU, on a Mac.
- [vphone-linux#20](https://github.com/YahiaAngelo/vphone-linux/issues/20): macOS 27 recovery on a `vmapple2` board under TCG, stops at the SSV authenticator.
