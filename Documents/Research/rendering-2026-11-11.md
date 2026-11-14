# Rendering on macOS 27.2, 2026-11-11 and 2026-11-12

`Patches/reims` 0046–0068 follow
[dock-icons-2026-11-10.md](dock-icons-2026-11-10.md). They were written and run
on the DGX on 2026-11-11 and 2026-11-12 against a 27.2 (26B123) disk, with
`Patches/qemu` 0001–0017 and `Patches/metal2vulkan` 0001–0003. This note records
what each group changes, what a guest showed with all of them, and what is still
wrong on 27.2's Liquid Glass. 0069–0070 came later on 2026-11-12; see
[0069 and 0070](#0069-and-0070) at the end.

## The Patches

0046–0051 are other people's commits to Reims, taken with their authorship:

- 0046: a clear-only pass publishes through its resolve texture.
- 0047: a stencil face is read only when its own enable bit is set.
- 0048: a pipeline's declared topology class is named, so pipelines that
  declare one are no longer refused.
- 0049: a pipeline-cache blob larger than the bound is rebuilt, not kept.
- 0050: a DontCare attachment keeps the contents it already had.
- 0051: packed 4:2:2 video is expanded the way Metal samples it.

0052–0068 are this repository's:

- 0052–0056: clip masks, icons the guest reads back, glyph views and attachments
  that alias across slots are kept; wide and integer targets (16-bit and
  `RGBA16Unorm` among them) survive a Store, a LOAD seed and a sample; heap
  texture residents are keyed by the resource; a clear-only pass on a heap
  texture creates its image.
- 0057–0063: programmable blending (`ColorInput`) and its feedback passes are
  synchronized and get matching initial layouts; secondary MRT slots that are
  not cleared start at zero; render-target locations a fragment shader does not
  write are masked; a GPU-resident linear target is cleared on the GPU, and the
  pre-draw DontCare seed no longer wipes it.
- 0064, 0066, 0068: the extended-range formats. `BGR10_XR`, `BGRA10_XR` and the
  two-plane `RGB10A8_2P_XR10` (Metal 550–555) are rendered, sampled and written
  back, on heap textures and on IOSurfaces. An IOSurface names them by FourCC
  (`b3a8`, `&b38`, `w30r`, `&w3r`, `w40a`, `w40m`, `l10r` and others), and a
  type-11 view of one plane of a two-plane surface renders that plane alone.
- 0065: strip topologies enable primitive restart.
- 0067: a task's object list is sized from the wire's byte length.

All 68 apply with `git am` on Reims `44127711`, and the result is the tree that
was built and run.

## What a 27.2 Guest Showed

With 0001–0068, and with the diagnostic build of it described below, about
twenty boots of a 27.2 disk that had been through Setup Assistant reached the
desktop; the three whose serial logs were kept show no panic. The wallpaper, the menu bar and its menus,
the Software Update notification, desktop widgets, and the Dock's Safari, Mail,
Photos, Calendar, Contacts, TV, Games and System Settings icons drew in their
colours. 0065 removed the horizontal streaks that had crossed several icons.

Still wrong:

- Every Liquid Glass surface is a flat mid grey: window backgrounds, the Dock,
  menus, the notification banner and buttons. A window that should be near
  white reads sRGB 136.
- The first time a window draws, its text is missing. "About This Mac" opened
  from the Apple menu showed no text and a blank button. Clicking inside it
  made the text appear; closing and reopening it drew the text every time.
- Seven Dock icons are grey placeholders. The disk's icon cache was not cleared
  at boot, so whether they come from an earlier build's cache was not checked.

## Looking at the Grey

A diagnostic build of Reims (not in `Patches/reims`) logged, behind
`REIMS_VGPU_DRAW_LOG=1`, every texture a draw sampled, could mask a listed
pipeline's colour writes, could replace its textures with a solid colour, and
could read a resident image back to a file. It was run with "About This Mac" on
27.2.

- WindowServer draws the window into a 512×704 `RGBA16Float` layer and
  composites it with a shader whose entry point is
  `glass_background_sdf_all_lph`. Masking that pipeline's writes left a white
  window with dark text: the grey is that shader's output.
- Giving that pipeline a white 1×1 texture instead of its input made the window
  white, as it should be. Giving it a transparent one gave the same grey as the
  real input. (Corrected later: the switch replaced every texture the pipeline
  samples, the shape's distance field included. A white distance field puts every
  pixel outside the shape, so the glass drew nothing. This does not show which
  input was wrong. See [Why the Glass Is Grey](#why-the-glass-is-grey).)
- Read back before each draw into the layer, the window's fill was 1.0 after its
  solid-colour draw, and 0.534 after the glass shader drew into the layer.
- That draw samples another 512×704 texture. Between a clear-only pass that
  clears it to zero and the sample, no draw, compute dispatch or blit in the
  logs writes it. So the glass shader works from a texture that is empty
  in Reims; what fills it on Apple's GPU was not found.

Ruled out, each by a boot with the switch or change:

- `REIMS_VGPU_SAMPLED_IDENTITY=off`: one boot drew the text, the next did not.
- `REIMS_VGPU_PIPELINE_ASYNC=off` and `REIMS_VGPU_BUFFER_EXTENT=off`: no change.
- Clearing the resident as well as the guest pages in a clear-only pass: no
  change.
- The glass shader's parameter buffers matched their declared sizes (288, 25
  and 2 bytes) and held plausible values.

The missing first-draw text is drawn by WindowServer's large uber fragment
shader (1.47 MB of SPIR-V) until the window's specialised pipelines are built;
the specialised pipelines draw it correctly. Whether the uber shader's
translation or its input is at fault is open.

## Other Versions

Booted once each on 2026-11-12 with 0001–0068, cold:

- 26.6.2 reached the login window with a grey background instead of the
  wallpaper, and shut down cleanly from its Shut Down button.
- 15.6.1 reached Setup Assistant's language panel over its blurred wallpaper.
- 14.6.1 reached the login window with its wallpaper and clock, and shut down
  cleanly.
- 13.6 reached the login window with its Ventura wallpaper and avatar, where
  0039 had drawn it grey with a black avatar, and shut down cleanly.

None was logged in, and none of their serial logs shows a panic. `stop` ended
15.6.1 in Setup Assistant, but timed out at each of the three login windows; the
login window's Shut Down button ended those guests instead.

## 0069 and 0070

Written and run on 2026-11-12 on the same 27.2 disk, then once on each other
version. All 70 patches apply with `git am` on Reims `44127711`, and the result
is the tree that was built and run.

- 0069: a heap texture size query can name a task whose `DEFINE_TASK2` is still
  queued on a child ring behind a held packet. The reply is now answered from
  that queued definition instead of being declined (`cmd_task_dead`).
- 0070: Reims runs each draw of a Metal render encoder as its own Vulkan render
  pass. Every draw after the first already loaded its colour attachments.
  Depth and stencil kept the encoder's load action, so a Clear ran again before
  each draw.

### The Dock's Grey Icons

They were not an old cache. With every icon cache cleared and Dock and
iconservicesagent restarted, the agent logged "Flattened representation is
seemingly a fully transparent image" for the same icons. Each one ended in an
all-zero store of its 104×104 or 106×106 render.

A diagnostic build read back every target and secondary attachment after each
draw, and every sampled resident when it was sampled. With that, the empty
output was traced back draw by draw. The first wrong draw was a RenderBox fill:

1. One draw writes the icon shape with depth on.
2. The next draw covers the whole target with transparent colour behind a
   `GreaterEqual` depth test, meant to fill only outside the shape.
3. Because depth had been cleared again, the fill passed everywhere and erased
   the shape. Everything that sampled it afterwards was empty.

With 0070, after clearing the per-user `com.apple.iconservicesagent` and
`com.apple.dock.iconcache` and the system `com.apple.iconservices.store`,
every Dock icon drew. That includes Finder, Messages, FaceTime, Phone,
Reminders, Notes, Music, App Store and Terminal. No icon render left an
all-zero store. Clearing only some of these caches leaves placeholders that an
older build already stored.

Keynote, Numbers and Pages show a question mark. They are not installed on
this disk.

### First-Draw Text

In one boot, the pipelines were already built by re-rendering every icon.
"About This Mac" then drew its text on first open. After a cold boot it still
opened without text the first time. That boot had no dropped packet and no
long compile while the window opened, so the cause is still open.

Separately, the uber fragment shader's pipelines take 7.7–8.8 s each for
NVIDIA's driver to compile. A packet that waits on such a compile for 10 s,
counting its translation, is replaced at the ring head and its later draws are
lost (`exec_continuation_dropped`). This happened about once a boot. The
following did not shorten the compile:

- `VK_PIPELINE_CREATE_DISABLE_OPTIMIZATION_BIT`
- running `spirv-opt -O` on the module, which is 16% smaller afterwards

### The Grey

Still grey at 0070. Two more leads were checked and are not the cause:

- The 512×704 texture the glass shader samples is a linear texture in guest
  memory, never a render target while the window opens. Sampling it from guest
  pages instead of the GPU-resident copy left the window just as grey.
- The texture reference it uses does appear as a second colour attachment in
  1920×1080 passes. Those passes run at another time, against a different
  object that reuses the reference.

### Other Versions at 0070

Booted once each, cold, on 2026-11-12. Each reached the same screen as at 0068:

- 26.6.2: the login window, grey.
- 15.6.1: the language panel.
- 14.6.1: the login window with its wallpaper and clock.
- 13.6: the login window with its wallpaper and avatar.

None of their serial logs shows a panic. 15.6.1 stopped with `stop`. For 26.6.2
and 13.6, `stop` timed out and the login window's Shut Down button ended them.
On 14.6.1 the button was pressed while `stop` was also running.

## Why the Glass Is Grey

Found late on 2026-11-12. This records the cause; [Protocol 237](#protocol-237)
records the fix and what is still wrong. All of it is on the same 27.2 disk.

### The Grey Is a Fallback

Masking one pipeline's colour writes, one pipeline at a time, while "About This
Mac" redrew, found a single draw that turns the window grey. Without it, the
window is white with its text and button, which is how 27.2 draws it. That
pipeline's entry point is `glass_background_all_lph`. Its uniforms are named in
the shader's own metadata:

- It samples `source_texture`, the content behind the window, at a level picked
  from `blur_radius` (8 here).
- It multiplies that content by a colour matrix, `face_cm0`–`face_cm2`, which is
  0.7 times identity here.

WindowServer clears `source_texture` to zero every frame and never writes it.
So the glass is 0.7 × nothing, laid over the window. Four such layers stack to
the sRGB 136 that was measured.

WindowServer never fills it because it never gets the textures it would blur
into. On every boot the guest logs, hundreds of times:

    (AppleParavirtGPUMetalIOGPUFamily) Cannot create a texture with this usage on this host
    [com.apple.coreanimation:Metal] Failed to allocate 128x192 surface texture.

Reading the guest's own Metal plugin and kernel driver (in this host's working
directory only) shows why:

- When the plugin serializes a texture creation, it asks
  `supportsTextureDescriptor2`. If that is off, it uses the older record, whose
  usage field is one byte. Any texture with a usage of 0x100 or above is refused
  with that message. CoreAnimation's backdrop textures need such a usage.
- `supportsTextureDescriptor2` comes from a feature struct the kernel driver
  builds from the negotiated protocol version. A 27.2 guest asks for 252. Its
  driver has a second ladder of versions, 200 to 252, above the old one that
  ends at 62. TextureDescriptor2 is on from 237 up and off at every version
  below 200.
- Reims negotiates at most 62, macOS 26's top rung. So 27.2 always runs
  without TextureDescriptor2, and Liquid Glass falls back to flat grey.

### What Higher Protocol Versions Need

A diagnostic switch forced the negotiated version:

- **63, 64, 70:** not versions the guest has. The screen stayed black.
- **252 and 237:** the guest sends child commands this device does not have,
  `0x43`, `0x44` and `0x45`, about a thousand a boot. The screen stayed black.
- **200, the lowest new version:** only `0x43` is new. `0x43` is
  `EXEC_INDIRECT2` (`0x37`) with each resource record cut from 24 bytes to its
  first 8, `{object_id, ops}`; the header and command-buffer records are
  unchanged.

With `0x43` widened to `0x37` the guest submitted work at version 200, but the
screen stayed black. Reims also refused many draws (MRT requests, render
targets in formats it did not resolve) and compute pipeline descriptors with a
field it does not read. So versions 200 and up change more of the wire than one
command, and supporting them is its own piece of work, done in
[Protocol 237](#protocol-237).

### 0071

Writing this up found one real defect on the way. The guest asks for device
info about four seconds into boot, before any draw has created the Vulkan
device. Reims answered from the Vulkan 1.2 floor: one sample, no D24S8, 128
threads, 16 KiB of threadgroup memory, no native FP16. 0071 brings the device
up first and answers from it: 8 samples, D24S8, 1024 threads, 48 KiB, FP16. It
does not change the glass.

## Protocol 237

Done on 2026-11-13 with Reims 0072–0083 and metal2vulkan 0004. A 27.2 guest
asks for 252 and now gets 237, and its Liquid Glass draws a blurred backdrop.
0072–0076 got there with grey glass and black corners; 0077–0083 fixed those.
See [0077–0079](#00770079) and [What Is Still Wrong](#what-is-still-wrong).

### The Ladder

The guest's kernel driver turns the negotiated version into a 0x38-byte
feature table, and its Metal plugin reads that table. From the driver:

- 62, the top of the 26-era ladder, sets bytes 0x2–0xa and 0x10.
- The second ladder runs from 200 to 252. Its valid rungs are 200–209, 230–233,
  235, 237, 238, 245 and 250–252. Each rung adds bytes to the 26-era set:
  200 adds 0x14–0x22, 201–209 add 0x23–0x2b, 230–233 add 0x2c–0x2f, 235 adds 0x30,
  237 adds 0x32, 238 adds 0x31, 245 adds 0x33 and 250–252 add 0x34–0x36.

What the plugin does with the bytes this device now turns on, read off its
`setupSerializerFeatures` and device getters:

| byte | what it turns on |
| --- | --- |
| 0x14 | shared texture handles |
| 0x15 | heap and pipeline queries through the info encoder |
| 0x16 | default raster sample count |
| 0x17 | vertex amplification |
| 0x19 | programmable sample positions |
| 0x1a | rasterization rate maps |
| 0x1b | tile shaders, imageblocks, memory-order atomics (each also needs a device-info key) |
| 0x1e | texture swizzle |
| 0x1f | dynamic attribute stride |
| 0x20 | blit encoder SPI, fill texture |
| 0x21 | multiplane mipped blits |
| 0x22 | compute pass dispatch type |
| 0x24 | command buffer jump |
| 0x25 | shared-storage heap resources |
| 0x27 | protection options envelope |
| 0x28 | compressed texture reinterpretation flush |
| 0x29 | argument buffers; the driver sends `0x44` instead of `0x33` |
| 0x2b | extended XR10 formats |
| 0x2c | resource pools |
| 0x2d | indirect command buffers |
| 0x2e | protected texture options |
| 0x2f | dispatch threads indirect |
| 0x30 | info indirect |
| 0x32 | TextureDescriptor2 |

### What Changed on the Wire

Each item was found by booting at 237 and reading what Reims refused, then
reading the driver or plugin for the layout:

- **Child packets.** `0x43` and `0x45` are `EXEC_INDIRECT2` with eight-byte
  resource records; `0x45` carries the info encoder's command buffers. `0x44`
  sets the object list by task address, with a second list nothing here
  reads. Without `0x44` no object resolved and every draw was refused (0075).
  Each resource record's flag byte packs the four validity ops into its low
  nibble (0077).
- **Texture descriptors.** Object-list descriptors carry TextureDescriptor2
  records (`0x34`, `0x39`). Read with the old layout, formats came out as
  0x500 and widths as 0x80000000. They are now rewritten to the old layout
  before anything reads them (0072).
- **Pool buffers.** Object type 19 is a buffer from a resource pool, with a
  12-byte descriptor (0072).
- **Info queries.** Heap texture size and alignment (`0x1d5`) and compute
  pipeline info (`0x1c2`) arrive as info records. Unanswered, the guest's kernel
  refused heaps of size 0 ("invalid arguments") and the guest dispatched empty
  grids (0073).
- **Compute descriptors** carry `maxTotalThreadsPerThreadgroup` (0072).
- **Two-plane textures** are on at every rung of the new ladder (0075).
- **Tile shaders and imageblocks.** At 237 the plugin offers them whenever
  device-info keys 23 and 24 say yes. The Vulkan backend now says no (0075).

### The Backdrop Blur

CoreAnimation captures the screen behind a glass surface and blurs it with
compute kernels: `backdrop_capture_compute_tile`, `variable_blur_copy_base_mip`,
`variable_blur_downsample_compute_agx2`. All of them fill a shared imageblock
tile, meet at a barrier, and have one thread write the whole tile. Two things
stopped them:

- Reims refused any kernel with an imageblock (0074).
- metal2vulkan wrote only the calling thread's cell, so each 32×32 tile wrote
  one texel. A kernel without a `threads_per_threadgroup` argument also kept its
  cells per thread, so the writing thread saw none of the others (0004).

With both fixed, the 256×256 RGBA16F texture the glass samples went from all
zero to about 454,000 non-zero bytes, and the About window drew as frosted glass.
The downsample kernel writes mip levels 1–4 of that texture, and a Vulkan storage
image is bound at one level. Those writes are dropped, so the glass samples
level 0 and is blurred less than on a Mac.

### Boots

All cold boots of the 27.2 disk on arm64 Linux (NVIDIA GB10), with no panic,
to the desktop with its wallpaper, Dock and menu bar. In the first, the guest
logged no "Cannot create a texture with this usage" and one "invalid
arguments" heap refusal, as many as at 62.

| build | About This Mac | menus |
| --- | --- | --- |
| 0072–0075 | frosted glass, text on first open | Apple menu: a grey panel without items |
| 0072–0075, and a compute fallback that did not trigger and was dropped | not opened | Apple menu: frosted glass with items; Finder menu: glass without items |
| 0072–0076 | grey, text on first open | Apple and Finder menus: items on grey glass |
| 0072–0076 | grey, text on first open; the boot Apple logo shows through the lower part | Apple and Finder menus: items on grey glass |

Diagnostic builds of the same code drew About This Mac as frosted glass in two
more boots. The last row is the build in `Patches`; the one above it ran 0076
before its two copies of the black sample were moved into one helper.

### 0077–0079

At 0076 the glass was often grey, the Dock had no background in some builds,
and windows and menus had black corners. The explanation written then, that
CoreAnimation captured a retired display buffer, was wrong. Each defect below
was found by reading back every draw's target and every kernel's inputs in
one frame, on diagnostic builds.

- **Resource tables (0077).** `0x43` resource records carry one flag word
  where `0x37` carries four validity-op bytes. The guest packs the four ops into
  the low nibble of its first byte (clear host valid, set host valid, clear guest
  valid, set guest valid, from bit 0) and sets the high nibble as well. Read as
  four bytes, the high nibble said "clear host valid", which Reims takes to mean
  the guest's CPU wrote the resource. One boot's records by first byte: 0x40
  572, 0x20 313, 0x10 276, 0xa0 268, 0x42 173, 0xa8 157, 0xd0 102. 23 of 25
  frames a pass had stored into a linear texture were abandoned for the guest's
  pages, and the Dock's blur kernel read an all-zero 896×64 backdrop. With the
  nibble read, none was abandoned and the Dock got its glass back. The same
  misreading bumped mapping content generations 531 times in a boot instead of
  4. A diagnostic change that made the backdrop capture read a surface's
  resident instead of its pages changed nothing once the nibble was read, and
  was dropped. What the high nibble means is not known.
- **`inplace_copy_lph` (0078).** The 42×42 and 54×54 RGBA16F heap textures 0076
  sampled as black are written by this fragment shader: it has no colour output
  and copies the framebuffer under a window's or menu's rounded corner into a
  storage image. Its target is a heap texture, and Reims kept storage-image
  writes only for linear textures. The texels now go to a per-texture snapshot
  that draws sample, and the corners are round.
- **Mipmapped heap textures (0079).** Toolbar and button glass blurs into heap
  textures with mip levels (448×96 in five, 84×30 in two). Compute refused any
  heap texture with more than one level, and the toolbar drew black. Kernels now
  run on the base level, and their output to a heap texture becomes its snapshot.

About This Mac's white interior is drawn by the guest: the draw before the
capture fills the content rectangle with opaque white from its vertex colours.
Only the frame around it is glass.

| build | About This Mac | menus | Dock | Finder toolbar |
| --- | --- | --- | --- | --- |
| 0072–0079, four cold boots | glass frame, round corners | Apple and Finder menus: tinted glass with items | glass tray | glass, with title and buttons |

### 0080–0081

- **Mip levels (0080).** Kernels still write only level 0 of a blur pyramid.
  When a draw samples one, its snapshot is now uploaded with the texture's mip
  count and the levels above 0 generated by halving with linear blits, so the
  glass shaders' explicit LOD reaches a blurred level.
- **Condemned display surfaces (0081).** In some boots the wire guard condemns
  a display surface's pages early. The draw rail then binds the resident, but
  compute staging read the pages and failed, 27 times in one boot, each a
  dropped backdrop capture. Compute now reads the resident too.

### 0082–0083

About This Mac draws a glass rim tinted by the wallpaper around a white,
square-cornered content area. Read back draw by draw, the window is drawn in
this order: a white background over the whole window (square corners), a copy,
the backdrop capture, then three glass draws over the window that leave the
centre white and tint a band about 28 px wide at the edges.

- **The capture (0082).** It sampled the display surface's guest pages, which
  do not hold the frame being composed: it read the wallpaper where the white
  background had just been drawn. Compute now reads the resident under the draw
  rail's rule, and the capture, read back, holds the white window.
- **The blur (0083).** The glass samples a 256×256 mipmapped linear texture at
  one level. It now has its levels.

Neither changed the rim: screenshots before and after match. The rim comes from
the glass draws themselves, and whether a Mac draws the same band has not been
compared on a Mac.

### metal2vulkan 0005

The symbols missing from System Settings' icons and the black toolbar on a
first window had one cause: the translator lost a pointer that crossed a helper
call and stood a zero in for it.

When the native emitter cannot trace a pointer, it defines a Private variable
initialised to `OpConstantNull` and reads through that. The module still passes
spirv-val, so none of the retry tiers sees anything wrong, and every load
through the pointer reads zero.

- **Icons.** iconservicesagent rasterises a symbol as a mask, and a Core Image
  chain (`ci_asgDownH_affine_nearest` and its neighbours) downsamples and blurs
  it before RenderBox builds the distance field. `_ci_sampler_builder` returns
  `coreimage::Sampler_h`, whose third member is a `ptr addrspace(2)` to the
  sampler's transform rows in the argument buffer, and the kernel reads both
  rows through it after an `extractvalue`. Translated, the rows were zero, every
  sample landed at (0, 0), and the 31×82 and 31×36 stages came out transparent
  black. Read back after each draw, the chain was empty from that kernel on,
  while its 64×74 input held the glyph.
- **Toolbar.** The CoreAnimation fallback shader `A2Xghfc` read 4,892 values
  this way and `narrow_blur_19_compute` and `_final` read their offset table
  through a pointer parameter. The first window an app opened drew its toolbar
  black.

0005 counts, after translating, the zero-initialised Private variables a module
loads and never stores. When there are any, it translates again from the text
with every internal helper inlined and the `insertvalue`/`extractvalue`
round-trips folded, which forwards the argument-buffer pointer, and keeps that
result only if it reads fewer of them.

Of the 304 shaders a 27.2 boot that opened System Settings, a Finder window and
About This Mac translated, four read such a variable before 0005 and none after;
299 translate to the same bytes. With icon caches cleared, the sidebar and list
icons draw their symbols, and System Settings' first window draws its toolbar
light.

### About This Mac's Band

A Mac guest on Virtualization.framework running 27.0.1, captured with an orange
image directly behind the window, draws About This Mac neutral white: 254
across the window, falling to 250 within 8 pixels of the edge, with no tint
from the backdrop. A first capture that read a pink tint had caught the window
opening. This stack draws a 28-pixel band of warm glass, (255,242,227) over the
same kind of backdrop, around a white middle with square corners.

What WindowServer sends for the window, in order:

1. `inplace_copy_lph` copies the band's region of the display into heap
   textures.
2. Two quads with the window's footprint and vertex colour (1,1,1,1) write
   white over the window. A Mac draws them too; they are not the fault.
3. `Kbdsd_TimgA2Xhu_Isrc` captures the display around the window into 128×192.
4. `variable_blur_copy_base_mip_compute` copies that, mirror-padded, into level
   0 of a mipmapped 256×256 texture, and `variable_blur_downsample_compute_agx2`
   builds levels 1 to 5, each from the one before: it samples level N at an
   explicit LOD and writes level N+1 with `write_imageblock_slice_to_texture`
   at a LOD read from its uniforms.
5. `glass_background_sdf_all_lph` draws the band, and other glass draws the
   middle, sampling that texture at a level of detail.

With the band's source texture replaced by white, the band reads 250, 253 and
254 at 3, 10 and 20 pixels in, which is the Mac's profile. The shader and its
uniforms are right; the blurred backdrop is not.

Step 4 does not run as written here. metal2vulkan's region store writes only
when the LOD is 0, so levels 1 to 5 are dropped; a compute sampled image has one
level, so a read at LOD N returns level 0; and the draw path generates the
levels from level 0 by halving (0083). The box-filtered levels pull the desktop
from the mirror padding into the window's edge, where the guest's variable blur
keeps it white. A fix needs compute reads and writes at a LOD the kernel
computes, which Vulkan expresses as one image view per level: the translator
indexing a per-level array by the LOD, the runtime staging and writing back each
level, and the draw path sampling the levels the guest wrote.

The summed-area kernels in the same frame, `sum_rgba_rows` and
`sum_rgba_columns`, sample a pixel-coordinate sampler with `ConstOffset`, which
Vulkan forbids (`VUID-vkCmdDispatch-None-08611`). Folding the offset into the
coordinate at bind time was tried and left the band unchanged; it is not
applied.

### What Is Still Wrong

- **About This Mac's band, and blur strength.** See
  [About This Mac's Band](#about-this-macs-band): the guest builds its backdrop
  blur's mip levels in compute at a LOD the kernel computes, which neither the
  translator nor the compute rail carries, so the levels are generated by a box
  filter instead. System Settings' symbols and a first window's black toolbar,
  listed here at 0083, are fixed by [metal2vulkan 0005](#metal2vulkan-0005).
- **15.6.1** was recorded at 0071, 0076 and 0079 as drawing its language panel
  too dark. At 0081 that was the panel fading in at the 150 s screenshot; 90 s
  later it is drawn.
