# Stability, 2026-11-09

Measured on the DGX under KVM on 2026-11-09 with `Patches/qemu` 0001–0016,
`Patches/metal2vulkan` 0001–0003 and `Patches/reims` up to 0040, with
`REIMS_VGPU_WIRE_WATCH=1 REIMS_VGPU_WIRE_GUARD=1`. It follows
[stability-and-wallpaper-2026-11-08.md](stability-and-wallpaper-2026-11-08.md).

"Cold" is a boot in which Reims translates the shaders and builds the pipelines
it meets; on two cold 26.6.2 boots about a hundred translations were already on
disk. "Warm" is a later boot that finds them in the caches in the VM's
directory. Each boot with an account was taken to the desktop and Terminal,
with a screenshot at the login window, the desktop, Terminal and after Terminal
quit.

## Boots

The Reims level grew through the night, so each boot is listed at the level it
ran.

| macOS | Boots | `Patches/reims` | Panics |
| --- | --- | --- | --- |
| 27.2 | 3 cold, 2 warm | 0001–0033 | none |
| 27.2 | 2 cold | 0001–0039 | none |
| 26.6.2 | 1 cold, 1 warm | 0001–0034 | the cold boot: kernel data abort (memory corruption); the guard did not know 26.6.2's kernel yet |
| 26.6.2 | 2 cold | 0001–0040 | one, while shutting down: `Debugger synch pending on cpu 2` |
| 15.6.1, with an account | 1 cold, 1 warm | 0001–0039 | none |
| 15.6.1, at Setup Assistant | 1 cold, 1 warm | 0001–0034 cold, 0001–0039 warm | none |
| 14.6.1 | 1 cold, 1 warm | 0001–0039 | none; the warm boot hung (below) |
| 14.6.1 | 2 warm | 0001–0040 | none |
| 13.6 | 1 cold, 1 warm | 0001–0039 | none |

What the screen showed:

- 27.2: the desktop wallpaper, menu bar and widgets draw. The Dock's icons are
  grey placeholders. Terminal's text draws from 0037 (R32Float render targets)
  on; on 0001–0033 Terminal's window stayed empty. One of the two boots on
  0001–0039 turned the screen to stripes after Terminal was opened. Glass
  controls carry small rainbow blocks.
- 26.6.2: the menu bar, widgets and every Dock icon draw. The background is
  dark grey or near-white instead of the wallpaper, and Spotlight and the menu
  bar garble.
- 15.6.1: the desktop is macOS's yellow fallback wallpaper; the menu bar, the
  Dock and Terminal's text are normal, and the login window's wallpaper is
  right. The VM at Setup Assistant reached the country panel, on yellow.
- 14.6.1: the desktop, menu bar, Dock, Finder and Terminal's text draw; the
  desktop is yellow too. Whether it is the same fallback was not checked.
- 13.6: the Ventura desktop wallpaper draws again; it was black in every run
  from 2026-11-08 until this build. Which patch brought it back was not
  isolated. The login window is still grey with a black avatar.

## Kernel memory corruption

This is the panic that hit about half of 27.2's boots on 2026-11-08.

Measured:

- `s272-wire`, a 27.2 boot with the wire watch on and the guard off, before the
  translation and pipeline changes: the first frame's EXEC waited 18.1 s, 9.0 s
  translating CoreAnimation's large fragment shader (94,568 bytes of AIR to
  1.47 MB of SPIR-V) and 8.9 s building its pipeline. Reims's translation-order
  hold kept the display channel behind it. The display swap that waited for
  that frame was seen at 13.4 s. At 18.4 s, 5.0 s later, the surface
  descriptor of mapping 2, a still-mapped 1920 by 1080 RGBA16Float swap buffer,
  went from wire count 1 to 0, and the guest's serial log printed
  IOMobileFramebuffer cancelling swap 1 at that moment.
- Two 27.2 RAM dumps from 2026-11-08 show the same thing after the fact:
  mapping 2's surface descriptor at wire count 0 with no UNMAP sent for it,
  its backing object paged to the compressor (536 of its 1013 pages in one
  dump, all 1013 in the other), the kernel using 57 and 319 of those pages,
  and every pixel-filled kernel page inside mapping 2. Reims's last full-frame
  write into mapping 2, a deferred write-back through the copying path, was
  running or had just ended when the guest panicked.
- On 26.6.2 a cold boot at 0001–0034, before the guard knew 26.6.2's kernel,
  panicked the same way; there the stale write came from a resident merge
  rather than a write-back.
- With the guard on, every cold boot saw the drop: mapping 2 on 27.2 at 18.5 to
  18.8 s (5 of 5 boots), and once on each cold 26.6.2 boot at 0001–0040. The
  guard condemned the mapping, and none of those boots panicked from it. The
  two warm 27.2 boots, whose translations and pipelines came from the caches,
  saw no drop.

Read from the guest kernel's code in a dump, not traced: IOMobileFramebuffer's
buffer release unwires the IOSurface and completes its memory descriptor, and
the paravirtual IOSurface mapper sends UNMAP only from its own unwire. A
cancelled swap therefore leaves the device holding a mapping whose pages the
guest has let go. That the cancel's release is the one that drops the count is
inferred from the timing; nothing else was seen to move it.

## vCPU stalls

Measured before these patches, with the lock timing of `Patches/reims`
0019–0020: one drain tranche held the device lock 8.27 s while a cold pipeline
build ran inside a draw, and a vCPU waited 7.8 s for the lock in an IOSurface
MMIO exit; another waited 6.2 s. One draw held the device and engine locks for
8.6 s building the glass fragment shader's pipeline (368,062 SPIR-V words). The
waiting vCPU held QEMU's BQL, so the main loop, interrupt delivery and every
other exit that needed the BQL stopped with it.

Measured on 2026-11-09: cold boots still build their slowest pipeline for 7.9
to 9.6 s, now on a compiler thread with no lock held. The longest vCPU wait
for the device lock was 183 ms and 139 ms in two cold 27.2 boots, 62 ms in a
cold 26.6.2 boot and 37 ms in 13.6's cold boot.

## Debugger synch pending

Cause, read from 26.6.2's kernel in a dump: `DebuggerXCallEnter` sets its
deadline to now plus `debug_ack_timeout`, or 24,000,000 counter ticks when that
is 0, and panics `Debugger synch pending on cpu N` when a CPU has not answered
its cross-call by then. The debug-ack machine timeout reads 0 in the 26.6.2 and
27.2 dumps, because Apple's VM device tree sets `debug-ack-scale` to 0.
24,000,000 ticks is 1 s on the 24 MHz counter of Apple's hardware. This VM's
counter runs at 1 GHz (the device tree's `timebase-frequency` is
1,000,000,000), so the wait is 24 ms. A vCPU that takes the cross-call later
than that panics the guest. What delayed the CPU each time was not measured; a
short host scheduling delay is enough, and the device lock waits above are
longer than 24 ms too.

Before the fix there were six panics of this kind on 2026-11-09, among them
26.6.2 at 0001–0040 while it shut down (cpu 2); it was also seen twice on 27.2
on 2026-11-08 (cpu 3).

Fix: `boot` and `account` add
`ml-timeout-debug-ack=1000000000000 ml-timeout-debug-ack-scale=1` to the
kernel's boot arguments. The timeout is in picoseconds, so it is 1 s at any
timebase, and the scale argument overrides the device tree's 0. Read from
`machine_timeout_init_with_suffix` in 26.6.2's and 27.2's kernels: the value is
divided by 1000, converted with `nanoseconds_to_absolutetime` and multiplied by
the scale, so 10^12 is 10^9 ticks at 1 GHz
([new-tree-spike-2026-11-09.md](new-tree-spike-2026-11-09.md#debug-ack-timeout)).

Measured: four cold boots of 27.2 and 26.6.2 with these arguments, on Reims
c963eab4 (`Patches/reims` 0001–0040) and `Patches/qemu` 0001–0016, passed with
no panic. Each included a stall while shutting down, where the panic had come
before. Four boots are not proof that it is gone.

Side effect, found reading the kernel: `DebuggerXCallReturn` now also times out
after 1 s instead of waiting for the other CPUs forever.

## 14.6.1's warm hang

Measured on a warm boot at 0001–0039: Reims logged the protocol handshake at
2.4 s and nothing for twelve minutes. No thread was stuck: the vCPUs idled in
KVM, the main loop was in `ppoll` and the drain worker waited for work. The
guest had stopped asking. It writes the protocol version to VERSION and reads
it straight back, and the value read selects its protocol; 0 makes it give the
device up. The write had found the device lock held for microseconds by the
4 ms poll and gone into the ingress queue, and the read found the lock free and
answered from the state before the write. The log shows the write applied by
the drain, not by the vCPU. The queue is in Reims's base; this boot hit the
race.

`Patches/reims` 0040 publishes VERSION without the lock when it is written and
applies queued writes before any other read. Two warm 14.6.1 boots with it were
fine; the race is rare, so two boots do not show it gone.

## What the patches change

| Patches | Change | Measured on a guest |
| --- | --- | --- |
| metal2vulkan 0002–0003 | Definitions looked up through maps instead of module scans; the construct tree built while the large-CFG feed runs | The first-frame shader, offline: 7.9 s on one of the host's big cores, 1.8 s on two, with the same SPIR-V; after 0002 the SPIR-V and reflection were also byte-identical for 144 other AIR files from 13.6 to 27.2 guests. Cold 27.2 boots: longest single translation 2.1 to 2.5 s |
| reims 0017 | Translations kept on disk across boots, keyed by the AIR, the options and a hash of the translator's source | Warm 27.2 boots loaded 255 to 257 translations, the longest left to translate 31 ms |
| reims 0018, 0034 | Graphics pipelines built on a compiler thread with no lock held; the draw waits as a deferred packet. `REIMS_VGPU_PIPELINE_ASYNC=off` builds them in the draw again | Slowest build 7.9 to 9.6 s, off the locks |
| reims 0019–0020 | Device lock holds and vCPU waits timed per holder | Measurement only |
| reims 0021–0022, qemu 0012–0015 | Mapper register reads served without the device lock; the IOSurface window dispatched without the BQL; the guest-memory callbacks reach RAM only, page-table walks included | Longest vCPU wait 37 to 183 ms, was 6.2 and 7.8 s |
| reims 0023–0025 | Two mappings that claim one guest page are both quarantined until the protocol says which owns it | not measured on its own |
| reims 0026–0029, qemu 0010–0011 | The drain worker walks the guest kernel's page tables itself, from the TTBR1, TCR, SCTLR and VBAR that QEMU now hands over, once the walk agrees with the vCPU's reads | not measured on its own |
| reims 0030–0033, 0035, 0039 | The wire watch and guard: a display buffer the guest unwired while mapped is condemned, its owed frames dropped, its pages never read or written again, and its page claims withdrawn. Layouts checked for 27.2's and 26.6.2's kernels only | Condemned in every cold boot that had it on; no panic from it |
| reims 0036–0038 | Ten-bit RGB and BGR and R32Float render targets; a rendered surface named by the format its image is created in | Terminal's text on 27.2 |
| reims 0040 | VERSION read back after the write queued before it | Two warm 14.6.1 boots |
| qemu 0016 | Tests of the no-dispatch section against real regions and an ARM walk | unit tests |

At 0040 the Reims library tests pass, 2311 of 2311, and QEMU's
`test-reims-vgpu-ram` and `test-reims-vgpu-no-dispatch` pass.

## Still open

- `Debugger synch pending`: four clean boots with the 1 s debug-ack timeout
  above, not yet enough to call it fixed.
- Cold boots still lose mapping 2. The first frame now waits on a pipeline
  build of 8 to 9 s instead of on translation, past the guest's 5 s swap
  timeout, so it is the guard, not the speed-up, that keeps Reims out of the
  buffer. With builds off the locks the guest keeps running, and it seems to
  give up a command it has waited about 10 s for: on 27.2, at 21 s, the first
  frame's EXEC had turned into a NOP of the same length. Builds later in a boot
  reach 8.6 to 9.0 s.
- 27.2: stripes after opening Terminal (one boot of seven, also seen on
  2026-11-08); the Dock's icons are grey placeholders; small rainbow blocks on
  glass controls.
- 26.6.2: the background is dark grey or near-white; Spotlight and the menu bar
  garble.
- 14.6.1 and 15.6.1: yellow desktop wallpaper. 15.6.1's is
  `WallpaperExtensionError (3)`; 14.6.1's cause was not checked.
- 13.6: the login window is grey with a black avatar.
- The wire watch and guard turn themselves off on 13.6, 14.6.1 and 15.6.1,
  whose layouts are not checked.
- Reims 0040 was not booted on 13.6, 15.6.1 or 27.2.

## Reproducing the patched trees

In fresh clones of the upstream repositories on the DGX:

```sh
git clone --branch dgx-spark https://github.com/Hackintosh-on-DGXSpark/reims-vgpu.git reims
git -C reims checkout --detach 44127711
git -C reims am "$PATCHES"/reims/*.patch

git clone --depth 1 --branch dgx-spark https://github.com/Hackintosh-on-DGXSpark/qemu-reims-vgpu.git qemu
git -C qemu am "$PATCHES"/qemu/*.patch

git clone https://github.com/Hackintosh-on-DGXSpark/metal2vulkan.git m2v
git -C m2v checkout --detach 8b78eac
git -C m2v am "$PATCHES"/metal2vulkan/*.patch
```

Every patch applied. `git diff` against the integration branches the night's
boots were built from was empty for all three: Reims after 0016 has the tree of
8a7b3334 and after 0040 the tree of c963eab4 (`34d7298a`), QEMU after 0016 that
of 6fbedda80c (`3ba4b5db`), and metal2vulkan after 0003 that of e1ffa45
(`a59f54f1`). Authors and messages of Reims 0017–0040 match the branch's
commits.
