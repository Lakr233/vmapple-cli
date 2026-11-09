# New-tree spike, 2026-11-09

An isolated trial on the DGX on 2026-11-09 of steelbrain's rewritten Reims and
its QEMU, with this project's KVM port, against the stable stack of
[stability-2026-11-09.md](stability-2026-11-09.md) booted from the same disks.
The stable stack stays the default; the spike's patches are in
`Patches/staging/newtree` and are not used by `boot`, `account` or `restore`.
The last part records the guard for 13.6, 14.6.1 and 15.6.1
(`Patches/staging/reims-guard-old`), which was only unit-tested.

## Why

Our Reims is steelbrain's at 44127711 with `Patches/reims` 0001–0040, from
before the rewrite that replaced the whole tree with libreims_vgpu and its C
API (98fe2a3, 2026-10-11). Three of the rewrite's changes bear on what
`Patches/reims` patches around, read from the code at 84089ca:

- The register window takes no lock: `device/mmio.rs` reads and writes no
  register under a lock, and answers the registers the device also keeps under
  a lock from a staged copy. In the old tree vCPUs waited up to 7.8 s for the
  device lock (`Patches/reims` 0019–0022).
- VERSION is negotiated and stored atomically when it is written
  (`set_binary_version`), so its read-back cannot race a queue, as it did on
  14.6.1 (`Patches/reims` 0040).
- No write-back is deferred past completion. A texture over guest pages is
  rendered into a shadow that a GPU copy in the same submission merges back,
  and copied buffers are merged back on the CPU, both before `Completed` is
  posted; only a merge owed after a failed wait runs later. The kernel memory
  corruption on 27.2 and 26.6.2 came from a deferred write-back and a resident
  merge into a buffer the guest had let go.

omvm (sapoepsilon/omvm) reports macOS 26.4 on `vmapple` under KVM on Asahi
Linux with this tree.

## The pinned set

| Piece | Source | Commit | Changes |
| --- | --- | --- | --- |
| Reims | steelbrain/reims-vgpu `master` | 1fe0acb | `Patches/staging/newtree/reims-vgpu`, 4 |
| metal2vulkan | pinned by Reims's `Cargo.toml` | 219f0136 | none |
| QEMU | steelbrain/qemu-reims-vgpu, branch `steelbrain/reims-vgpu` | 1b41f5f5db | `Patches/staging/newtree/qemu`, 14 |
| OpenAVB | branch `vmapple` | c35e417 | none |

The series were exported from the DGX's `spike` branches at 314e248f1 (Reims)
and fcdfd20f5d (QEMU) once the spike had stopped.

Reims:

1. YahiaAngelo's 84089ca, the guest's page size per device (on his
   `vphone-next3` branch; its parent is 1fe0acb).
2. SDL3 as a Unix console build: the DGX has no X11 or Wayland development
   files and runs headless (`REIMS_VGPU_WINDOW=0`); without it `sdl3-sys`
   fails in CMake.
3. `REIMS_VGPU_SPIKE_VERSION_CAP=<n>`, off unless set: a binary version request
   above `n` becomes `n` before negotiation. A diagnostic for 27.2.
4. `REIMS_VGPU_TRACE_FLUSH=1`, off unless set: each `REIMS_VGPU_TRACE` line is
   written through, so a killed run keeps its trace.

QEMU:

1. 0001–0005: the DGX fork's KVM port, cherry-picked with their authors:
   bcb0c54181 (KVM support for `vmapple`; the reims-vgpu-mmio and meson parts
   dropped, Kconfig `TCG || HVF || KVM` with `MAC_PVG_MMIO`), 73d24d0d34
   (no-syndrome MMIO stores), 2be303b3c2 (the firmware handoff in QEMU),
   18f1392a5a (the guarded GIC fixup) and bc63c27b6f (PAC context on secondary
   vCPUs). aquarat's port, which omvm uses, was not taken: it is written for
   Apple's AVPBooter, and our VMs boot through OpenAVB and the QEMU-side
   handoff.
2. 0006–0010: `Patches/qemu` 0003 (whole-disk discard), 0005 (handoff and
   hypercalls for 14 to 26), 0008 (PCI capabilities in ascending order), and
   0002 (RAM at 0x410000..0x700000) and 0007 (bdif writes) applied with fuzz.
3. 0011: omvm's 0002, by its author: the macOS 27 virtio-blk vendor capability
   and the virtio-blk-only capability reordering dropped. Our disks were
   restored without the vendor capability, and 0008 orders every device's
   capabilities.
4. 0012–0014: the HVF kernel-entry hook kept out of KVM builds; the scratch RAM
   mapped after apple-gfx-mmio's realize, as the library refuses a RAM range
   with no file behind it on Linux; the handoff calling
   `kvm_insert/remove_gdbstub_breakpoint`, as upstream renamed them.

Not taken from `Patches/qemu`: 0001 (USB device mode, used only to restore),
0004, 0006 and 0009–0016, which patch the old reims-vgpu-mmio shim that
apple-gfx-mmio replaces. omvm's Reims and metal2vulkan patches for Honeykrisp
are not needed: NVIDIA's driver has `VK_EXT_external_memory_host`.

## Build

- Reims: `cargo xtask dist` with `RUSTUP_TOOLCHAIN=stable` (1.99.1; the
  toolchain file pins 1.98.1 with Mac and x86 targets, and rust-version 1.98.1
  accepts 1.99.1) and `RUSTFLAGS="-C target-feature=+lse,+rcpc"`. aarch64 Linux
  is not a target upstream ships, and `reims-vgpu-core/src/guest/ptr/raw/aarch64.rs`
  uses `ldsetal` (LSE) and `ldapr` (RCPC), which the default
  `aarch64-unknown-linux-gnu` baseline lacks; GB10 has both. A full build took
  6 to 8 min on six A725 threads.
- QEMU: `--target-list=aarch64-softmmu --enable-kvm --enable-tcg --enable-slirp
  --enable-fdt --enable-pvg --enable-nettle --disable-docs --disable-werror
  --disable-gtk --disable-sdl --disable-vnc --disable-capstone --disable-rust`
  with `PKG_CONFIG_PATH` at the dist tree's `lib/pkgconfig`. `vmapple`'s AES
  comes from nettle 3.9.1, as the DGX has no gnutls development files.
  `ninja` does not relink QEMU when only `libreims_vgpu.a` changed; delete the
  binary first.
- The Linux build takes the library's own shaders from the metallibs committed
  in Reims's repository (`crates/reims-vgpu-vulkan/metallibs`), compiled by
  upstream on a Mac. No Mac of ours is involved and nothing Apple's is in this
  repository, but they are binary inputs that cannot be rebuilt on Linux.

## Run

Each run is a fresh `cp --sparse=always` of a frozen base disk: the 27.2 and
26.6.2 bases were copied from VMs that had just powered off cleanly, then left
read-only. A qcow2 overlay cannot be used, as `vmapple` opens the same image
twice (pflash for bdif and virtio-blk), and the DGX's ext4 has no reflink.

The new tree ran with the arguments `vmapple-cli` gives QEMU, less the old
shim's (`gfx-device=` and the USB chardev): the RAM backend file in the VM's
directory, `-cpu host,pmu=off,kvm-psci-version=1.1 -smp 4 -m 8G`, every QEMU
thread on the X925 cores, OpenAVB, and the boot arguments
`-v serial=11 debug=0x14c ml-timeout-debug-ack=1000000000000 ml-timeout-debug-ack-scale=1`.
Reims ran with `REIMS_VGPU_WINDOW=0`, `REIMS_VGPU_CENSUS_DIR` (below) and `HOME`
at the VM's directory, since it keeps its shader cache in
`$HOME/.cache/reims-vgpu-vulkan` and does not read `XDG_CACHE_HOME`. Its
display is 1440 by 1080; the stable stack's is 1920 by 1080.

The stable stack ran through `vmapple-cli boot --keep-panic-memory` on Reims
c963eab4, QEMU 6fbedda80c and metal2vulkan e1ffa45, but with a `vmapple-cli`
built at 03:34 that day (UTC+8), before the wire watch and guard and the
debug-ack arguments became its defaults. Its runs had
`wire_watch=unset wire_guard=unset` in Reims's log and `-v serial=11 debug=0x14c`
as boot arguments. They compare the old Reims and QEMU without the guard, not
the stack as `boot` runs it now.

Each comparison boot was cold and went through the same steps: the login
window, login, the desktop 120 s later, Terminal with `echo hello`, Safari,
Maps, Photos, Notes and Calendar opened with `memory_pressure -l warn`, the
apps quit, and `vmapple-cli stop`.

## Results

### 26.6.2, both stacks from one disk

New tree, one cold boot:

- The login window at about 100 s with the Tahoe wallpaper and the clock; the
  desktop at 120 s with its wallpaper, widgets and every pinned Dock icon.
- Terminal ran `echo hello` and printed it.
- With the five apps open, `memory_pressure -l warn` brought free memory to 34%
  (160,408 swap-outs, 273,052 pages used by the compressor); the screen stayed
  intact.
- After a Maps sheet was dismissed, `stop` shut the guest down and QEMU exited
  by itself. The serial log has no panic, no swap cancel and no
  `IOFence: blocking wait timed out`.
- The icon of a newly launched app (Terminal) is blank in the Dock's recent
  apps; the pinned icons are right.
- 29 frames per second on average over the seconds that had frames.

Stable stack without the guard, one cold boot that panicked and its restart:

- The login window was grey, with no wallpaper and no clock.
- Within about two minutes of the login the guest panicked:
  `panic(cpu 2 caller …): Invalid/destroyed mutex …: <0x36663666 0x36 0x00873666 0x36663666/0 0x3666 0x3666> @lock_mtx.c:141`,
  after one IOMFB `cancelling swaps` and nine `Too many corpses`. `boot` kept
  its RAM and started it again. The panic was not analysed; it has the shape
  the guard exists for, a swap cancel and then a kernel object overwritten,
  and the guard was off.
- After the restart: a near-white background with no menu bar or Dock at
  120 s, then the wallpaper with closed windows ghosting over it, a black menu
  bar, a cyan block in the Dock and one Dock icon missing. Terminal's window
  drew no text and the typed text went into a Finder search field. The apps
  did not launch, so memory pressure was not reached. `stop` shut it down after
  a `killall`; no panic on this boot.

### 27.2 on the stable stack

One cold boot, without the guard: the grey login window at about 100 s; the
desktop with its wallpaper, grey placeholders for the Dock's icons, artefacts on
the widgets and a black band on the menu bar; Terminal printed `hello`, with a
garbled tooltip. With the apps open and memory under pressure the whole screen
turned to noise, then dark red with windows missing. Safari could not be ended
(`kill -9` and Force Quit), and iconservicesagent crashed in a loop. Shutting
down failed three times on Safari, and QEMU was killed by its PID. No panic; the
serial log has one swap cancel during boot, 11 IOFence timeouts, two
`Trying to restart GPU` and eight `Too many corpses`.

### 27.2 on the new tree: the display is never initialized

Five boots from copies of the base that boots on the stable stack: `s272-new`
twice, then with the version capped to 62, with `tablet=usb-tablet`, and with
a flushed trace. QEMU's screen stayed at "Guest has not initialized the
display (yet)" in all five.

Measured:

- Kernel, handoff, PAC, timebase and secondary vCPUs behave as on the stable
  stack. The guest brings the device up as 26.6.2 does: root FIFO commands
  56, 51, 48 five times and 58, the display FIFO's 1 and 2, and
  `guest display on port 0 created` (56 lines of trace).
- On 26.6.2 the first user-space GPU clients follow (FIFOs 3, 2 and 1), and
  WindowServer opens IOMobileFramebuffer (`s_map_display_type` in the serial
  log). On 27.2 nothing follows for minutes: no further FIFO command, no
  IOSurface map, no GPU or IOSurface-window MMIO (zero `apple_gfx*` trace
  events over 4 s), no disk I/O, and all four vCPUs at 100% in varying EL0 and
  EL1 code. The kernel keeps logging; the guest does not answer `stop`.
- 27.2's driver asks for binary version 252, which upstream clamps to 245
  (26.6.2 asks 245, 15.6.1 asks 209); the stable stack answers 62. Capping the
  request to 62 changed nothing, and neither did `tablet=usb-tablet` in place of
  Virtualization.framework's tablet.

Hypothesis, not tested: 27.2's user space stalls in a CPU-bound loop before it
makes its first Metal device or task, on something the new stack answers at
bring-up differently from the stable stack and that 26.6.2 ignores. To test,
in this order:

1. The device-info replies (root FIFO 48 and 58): diff the stable stack's
   answers against `reims_vgpu_core::guest::abi::device_info`, which reports the
   Vulkan platform's limits, family and argument-buffer tier.
2. The ID registers and KVM features `-cpu host` exposes under each QEMU, the
   DGX fork's (upstream of about 2026-07) and steelbrain's (upstream of
   2026-09-30 merged).
3. The guest's unified log for the stuck boot, which would name the process; it
   needs APFS read access from Linux or a later boot of that copy on the stable
   stack.

A shader compile storm is less likely: it would follow a task, and 27.2 never
makes one.

### 15.6.1 on the new tree

One cold boot, from a copy of the 15.6.1 VM: the lock screen at about 100 s
with the redwood wallpaper and the clock; after login the desktop is macOS's
yellow fallback, as on the stable stack, with the menu bar and every Dock icon
right; Terminal printed `hello`; with the five apps open `memory_pressure`
stabilised at 46% free (241,001 compressor pages) with the screen intact; `stop`
shut it down and QEMU exited by itself. No panic, no swap cancel, no IOFence
timeout. The stable stack was not booted from this disk.

On the stable stack the yellow is the default video wallpaper failing (see
README); on the new tree the cause was not checked. A next step is the new
tree's VideoToolbox device (`-device apple-videotoolbox-pci`, NVDEC on GB10),
which the stable stack lacks. Not tried.

### Not run

- 13.6 and 14.6.1 on the new tree. Their copies were made and not booted.
- Warm boots on either stack; the stable stack from the 15.6.1 disk; any old
  stack run with the guard on.
- The pipeline-deadline A/B below.

## Blockers

- **Census mode is required on GB10.** A 26.6.2 boot's census records five
  degradation kinds placed as "dies": DeviceNanEncoding (356,769 draws and
  dispatches), PixelSamplerScaling (18,322), ExtendedRangeBlendSource (6,231),
  ExtendedRangeBlendsStoredCodes on RGB10A8_2P_XR10 (2,108) and
  YCbCrFilterNotExact (4). Without `REIMS_VGPU_CENSUS_DIR` QEMU exits at the
  first, and with it the library says the run is "NOT faithful to Metal". They
  need an answer or a policy that relays them.
- **The guard is still needed.** Read from the code, not run: UNMAP answers
  Busy only while the host object has more than one reference, and under
  `vmapple` every task but task 0 is isolated, so a task's reference goes when
  the guest deletes the type-11 resource, not when the GPU finishes with it.
  UNMAP can succeed with committed GPU work still to run. Nothing walks the
  pages again, cancels work or watches the wire count, so a guest unwire
  without UNMAP goes unseen. A draw can start up to 4.5 s after its commit
  while its pipeline is built, inside the 5 s after which the guest cancels a
  swap. The cancel-and-unwire hazard of
  [stability-2026-11-09.md](stability-2026-11-09.md#kernel-memory-corruption)
  is not closed by the rewrite.
- **Draws and dispatches are skipped at a deadline.** 4.5 s after its commit a
  draw, dispatch or tile dispatch whose pipeline is not ready runs nothing, and
  the command buffer reports no error. A skipped dispatch loses its storage
  writes and atomics. Reims relays the first skip per device; every skip is
  seen only in a census or a trace with `REIMS_VGPU_TRACE_DEGRADE=1`.
  `REIMS_VGPU_EXACT=pipeline_waits` waits without a deadline. The 26.6.2 and
  15.6.1 cold boots skipped none.
- **aarch64 Linux is off upstream's path**: the RUSTFLAGS, the SDL console
  build, the gdbstub rename and the scratch RAM order above.
- **Restore is not ported.** The USB device mode patch is not applied and the
  old shim is gone; restoring still needs the stable stack.

Where a guard would hook, from the same reading: the UNMAP decision
(`iosurface/table.rs`, to answer Busy while the runtime still holds the
surface's memory), the mapper's UNMAP and teardown and the type-11 delete as
the signals to condemn, `buffer_over_surface_at` (`gpu/device.rs`) to tie a
surface to its runtime buffers, the per-submission backing check
(`gpu/backing.rs`, `gpu/command.rs`) to fail a submission that uses a condemned
buffer, metal2vulkan's `detach_backing` for work already submitted, and the
library's own CPU writes into guest pages.

## Before the new tree can replace the stable stack

The conditions agreed with the reviewer, and where each stands:

| Condition | Status |
| --- | --- |
| Old and new from the same disk state: cold, warm, under memory pressure, shut down | 26.6.2 and 27.2 cold, with the old stack's guard off; warm not run |
| The wire guard hooked on the new tree's own guest-write paths; no hits on a hook that no longer exists is not evidence | not started; the paths are listed above |
| Deadline skips only as a logged degradation, A/B against exact waits, compute, storage and atomic skips flagged | none seen in two cold boots; per-skip logging needs a census or trace; A/B not run |
| One vCPU per host core, and the RAM backend in `/dev/shm`, each tested on its own | not run |

## Guard for 13.6, 14.6.1 and 15.6.1

`Patches/staging/reims-guard-old`, four patches after `Patches/reims` 0040.
**Unit-tested only; no guest was booted with them.** `Patches/reims` keeps the
watch and guard off on these kernels.

### Layouts

Read from kernelcaches extracted from the 13.6 (22G120), 14.6.1 (23G93) and
15.6.1 (24G90) IPSWs and deleted afterwards; 26.6.2's and 27.2's, read the same
way, agree with what their panic dumps showed.

- The IOMemoryDescriptor fields the watch reads are at the same offsets in all
  five kernels: `_wireCount` +0x88, `_length` +0x50, `_task` +0x70, the mixed
  data at `_memoryEntries` +0x90, and `prepare` and `complete` at vtable +0x218
  and +0x220.
- 15.6.1's `IOSurfaceParavirtMappingInternal` is 26.6.2's and 27.2's at every
  offset read: 0x98 bytes, the surface descriptor at +0x20, +0x48 and +0x50
  zero, the page-table descriptor at +0x58, the page count at +0x80.
- 13.6 and 14.6.1 have the older 0x78-byte class. +0x20 is the `IOSurface*`,
  and the surface descriptor is what `IOSurface::getMemoryDescriptor` returns:
  the IOSurface's +0x38 on 13.6 and +0x30 on 14.6.1. The page-table descriptor
  is at +0x48, its mapping at +0x50, the page count at +0x70. +0x58 holds the
  eviction deadline once the mapping has been completed and +0x60 is 1 when the
  page table spans two pages, so neither is a reserved zero.
- The guest's side, read and not observed: all three keep a mapping wired from
  MAP to UNMAP, and all three have the IOMobileFramebuffer path that cancels
  swaps after 5 s and releases a buffer with `complete`, as 27.2 does. 13.6
  completes both descriptors after an UNMAP whatever its result; 14.6.1 and
  15.6.1 complete only after one that succeeded. That a cancel produces the
  unmatched `complete` on 13 to 15 is inferred.

### What the patches do

KNOWN_KERNELS pairs each exact version string with its layout, "shifted" for
15.6.1, 26.6.2 and 27.2, "unshifted" for 13.6 and 14.6.1. The review set four
rules:

1. The version string alone picks the layout, and a mapping that fails its
   kernel's layout is refused, never tried against the other. On the unshifted
   layout the IOSurface must be one by its vtable, a fixed distance above the
   kernel's Mach-O header (0xa5ddc8 on 13.6, 0xb0fde8 on 14.6.1), and on every
   layout MappingInternal +0x18 must be the mapper device.
2. The chain from MappingInternal through the IOSurface to both descriptors is
   read twice back to back at every check and sample, and used only when both
   reads name the same objects. Otherwise it is `wire_watch inconclusive`,
   counted and read again later; never a count, never a condemnation.
3. Nothing the kernel writes is taken for a reserved zero: the +0x48/+0x50 zero
   check stays on the shifted layout only.
4. A mapping is not let go silently. One whose chain no longer reads as the one
   checked at MAP, with no UNMAP for it, is lost, not retired.

Lost is a latch, `unowned`, not a count or a condemnation:

- When the chain is lost the mapping is no longer sampled, its pages are still
  read, and no anomaly is reported. With the guard on, every host write into it,
  CPU or GPU, is refused, and a frame owed to it is dropped when paid.
- A MAP of the same MappingInternal carries the latch into its fresh entry. The
  latch is lifted only when that MAP's check passes: the whole chain read alike
  twice and both wire counts positive, at the MAP or at a later sample.
- If the check cannot read the chain, or its two reads disagree, the entry
  stays pending and refused and is checked again at the next sample. If the
  check fails, the entry goes back to lost and stays refused until a later MAP
  verifies.
- A condemned mapping that is lost stays condemned, and a MAP restating it does
  not clear it. An UNMAP, or another MappingInternal under the id, ends the
  entry; a failed or timed-out UNMAP gives nothing back.

### Tests

On the tree committed as 2697f743, in a worktree without `vendor/qemu`:
`runtime::mapper::wire_watch` 39 of 39; the library 2322 of 2323, the one
failure being the cursor test, which reads `vendor/qemu/ui/cursor.c`.
Mutations, each undone afterwards: one read instead of two together with a lost
chain retired as before failed 3 of 34 watch tests; 13.6's +0x58/+0x60 taken as
reserved zeros failed 6 of 34; the latch not carried across a MAP failed 5 of
39.

### Live checks still to run

On cold and warm boots of 13.6, 14.6.1 and 15.6.1 with the watch and guard on:

- `wire_watch_kernel verified … macos=13.6 layout=unshifted` (14.6.1 likewise,
  15.6.1 `layout=shifted`) once per boot, and a `wire_watch map … iosurface=`
  line for each display buffer.
- No `wire_watch_layout_unverified scope=mapping` (reasons `mi_unshifted_layout`,
  `mi_owner`, `iosurface_pointer`, `iosurface_class`), and few
  `wire_watch inconclusive` (the cost line's `inconclusive=`).
- On a boot with an IOMFB swap cancel, `wire_guard_condemned` for that buffer,
  as on 26.6.2 and 27.2.
- On 13.6 after an UNMAP that failed: `wire_watch identity_lost`,
  `wire_guard_unowned_refused`, then `wire_guard_unowned_cleared … reason=verified_map`
  or `wire_guard_unowned_kept … why=`.
- No panic, and the screens as on 0001–0040.

## Debug-ack timeout

Read from `machine_timeout_init_with_suffix` in 26.6.2's and 27.2's kernels: a
debug-ack value from the boot arguments or the device tree is in picoseconds.
The kernel divides it by 1000 and passes it to `nanoseconds_to_absolutetime`,
then multiplies it by the scale. `ml-timeout-debug-ack=1000000000000` is
therefore 10^9 ticks at this VM's 1 GHz timebase, 1 s, and 5 s would be
`5000000000000`. The device tree's `debug-ack-scale` is 0, which zeroes any
value, so `ml-timeout-debug-ack-scale=1` is needed too. An emulation of the
26.6.2 conversion gives 1,000,000,000 ticks at 1 GHz and 24,000,000 at
24 MHz for 10^12. See
[stability-2026-11-09.md](stability-2026-11-09.md#debugger-synch-pending).

## Reproducing the series

`Patches/staging/README.md` gives the bases and the `git am` steps. Applied in
fresh clones on the DGX, each series gives the tree of the branch it was
exported from: reims-guard-old `fcb94967` (2697f743, on c963eab4),
newtree/reims-vgpu `7029d854` (314e248f1, on 1fe0acb) and newtree/qemu
`a278a71a` (fcdfd20f5d, on 1b41f5f5db). The spike's own commits were made under
a placeholder name and carry this project's author in the series; the commits
of other people keep theirs.
