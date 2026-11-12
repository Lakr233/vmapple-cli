# Rendering on macOS 27.2, 2026-11-11 and 2026-11-12

`Patches/reims` 0046–0068 follow
[dock-icons-2026-11-10.md](dock-icons-2026-11-10.md). They were written and run
on the DGX on 2026-11-11 and 2026-11-12 against a 27.2 (26B123) disk, with
`Patches/qemu` 0001–0017 and `Patches/metal2vulkan` 0001–0003. This note records
what each group changes, what a guest showed with all of them, and what is still
wrong on 27.2's Liquid Glass.

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
  real input.
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
