# Dock Icons on macOS 27.2

On 27.2 (26B123) every application icon in the Dock was a grey placeholder, on a
restored VM and on a pulled one. `Patches/reims` 0041–0045 fix five causes, and
13 of the 19 icons then draw. This note records each cause, how it was found,
what was run on the DGX on 2026-11-10, and what is still wrong.

The guest was `macos-golden-gate-vanilla:27.2` pulled with `vmapple-cli pull`,
booted with four vCPUs on QEMU `hmacos-arm` + `Patches/qemu` 0001–0017 and
Reims 44127711 + `Patches/reims`.

## Looking Inside the Guest

The guest has no network, so two things were added to the test disk from the
single-user shell, the way `account` types its commands:

- A LaunchDaemon that runs `bash -i` on `/dev/console`. Booted with `serial=3`
  it is a root shell on QEMU's serial socket.
- A LaunchDaemon that deletes the icon caches at boot
  (`/Library/Caches/com.apple.iconservices.store` and the per-user
  `com.apple.iconservices*` and `com.apple.dock.iconcache`), so each boot draws
  every icon again with the build under test. Without it the Dock keeps the
  placeholders an earlier build left in the cache.

Small Metal probes were built on a Mac and copied in over that shell as base64,
and RenderBox and the guest's Metal driver were disassembled on the same Mac,
which runs 27.0.1. Neither is part of running a guest.

For four minutes or more after a boot the guest's load average is above 300,
with the patches and without them, and the shell answers slowly or not at all.

## Causes

### 1. A Heap Size Query Read Before It Was Answered

iconservicesagent and `com.apple.dock.extra` logged RenderBox's
`unable to create heap: 0` hundreds of times a boot, then
`Failed to generate flatten representation for icon stack`.

- RenderBox sizes a texture heap from `heapTextureSizeAndAlignWithDescriptor:`.
  A probe made that call 40 times: 27 returned `{0, 0}`, each in 10 to 60 µs,
  and the 13 that returned a size took 1 to 27 ms. Reims had answered all 40.
- The guest sends `CmdHeapTextureSizeAndAlign`, rings the child doorbell and
  reads the reply as soon as that register write returns. It waits for no stamp
  and no interrupt. Apple's host answers inside the write; Reims hands the
  doorbell to its drain thread and returns.
- 0041: the vCPU that rings the doorbell looks through the channel's ring for
  such a query and writes the reply itself before returning. The query changes
  nothing in the device, so it does not wait its turn behind a channel held for
  a shader translation.

After it the probe read a size from all 40 calls.

### 2. Two Alignments for a Linear Texture

With heaps working the next error was Metal's:
`Linear texture: bytesPerRow (112) must be aligned to 256 bytes`.

- 27.2 answers `minimumLinearTextureAlignmentForPixelFormat:` with 16, from its
  own `deviceLinearTextureAlignmentBytes`, and validates the row pitch against
  `linearTextureAlignmentBytes`, which the host supplies as device info key 13.
  Reims served 256.
- 0042 serves 16, the value the guest uses when the key is absent.

After it the probe created a linear texture over a buffer in 21 formats.

### 3. Views Over Buffer-Backed and Heap Textures

A buffer-backed texture and a heap texture carry the same object tag as a
texture view. Reims decoded either as a view when it was a view's base, failed,
and dropped the draw that sampled it.

- 0043 ends a view chain at either kind and samples through it. RenderBox views
  its R8 masks as A8; a view format with the same texel size reads the buffer's
  bytes under the view's format.

### 4. Copying a Heap Texture Into a Buffer

A probe cleared a texture and copied it into a buffer four ways. The private,
shared and linear textures read back the clear colour; the heap texture read
zeros, and Reims logged `blit_fail reason=view_desc_decode`.

- 0044 copies from the heap texture's host image.
- The probe still reads zeros, now with `t2b_heap_unrendered`: its pass only
  clears, and a clear with no draw does not create the host image of a heap
  texture.

### 5. A Rendered IOSurface Left in the Host Image

With the four above, iconservicesagent drew its icons and logged
`Flattened representation is seemingly a fully transparent image` for all 19.

- It draws each icon into a 104×104 IOSurface and reads the surface with the
  CPU. Reims's draw log showed the pass stored
  (`resident_surface_store`), and when the guest unmapped the surface 40 s
  later, `writes=1`: the pass's opening clear was all Reims ever wrote to the
  guest's pages.
- Reims keeps a rendered frame in the host image until the guest names the
  resource in `CmdSynchronizeResources`. For an IOSurface the guest sends none:
  on Apple's host the attachment is the surface's own memory.
- With `REIMS_VGPU_LAZY_WRITEBACK=off` the one icon redrawn in that run, the
  Calendar's, drew.
- 0045 keeps a frame in the host image only for a surface Reims has itself read
  since the guest mapped it: one a draw sampled or the display presented. Any
  other is copied to the guest's pages when the pass stores it.

## What Was Run

All on the DGX on 2026-11-10 with `Patches/reims` 0001–0045.

- Reims library tests, one thread: 2317 passed, 0 failed.
- Pulled 27.2, icon caches cleared at boot, two boots to the desktop, no panic:
  13 of the 19 application icons drew, one of them a black square, and six were
  placeholders. The three `?` items are applications the image does not have.
- One boot each, 200 s, no panic, not logged in: 26.6.2 and 14.6.1 and 13.6 and
  a restored 27.2 to the login window, 15.6.1 to the Language panel.
- 26.6.2 and 13.6 were booted again on 0001–0040 for comparison. Their login
  windows were the same on both: a second, dark password field below the first
  on 26.6.2, and white specks and a white strip along the bottom on 13.6.

## Still Wrong

- Six Dock icons are placeholders and one is a black square. A boot still logs
  `heap_sample_unrendered` about 20 times and drops about 10 draws: a heap
  texture is sampled, or loaded as a pass's target, before any draw has rendered
  into it. A pass that only clears a heap texture is one way to get there.
- In some boots the menu bar is a black band with a soft lower edge, or has a
  black patch behind the status items. It was not seen before 0041, when
  RenderBox could not make a heap.
- An `RGBA16Unorm` texture cannot be rendered into or converted
  (`rt_heap_format`, `buftex convert_fail fmt=0x6e`); RenderBox keeps a 384×384
  one over a buffer.
- With 0045 a window's backing is copied to the guest once, on its first frame.
  The cost was not measured.
- No version but the pulled 27.2 was taken to its desktop on 0041–0045.
