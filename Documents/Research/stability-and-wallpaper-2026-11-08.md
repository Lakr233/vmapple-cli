# Stability and wallpaper, 2026-11-08

Measured on the DGX under KVM on 2026-11-08. Branches `collision-owner` and
`kva-walk`, with its QEMU change, are now `Patches/reims` 0023–0029 and
`Patches/qemu` 0010–0011, and the ten-bit and R32Float render targets, revised,
are `Patches/reims` 0036–0038. `c136-resident`, RGBA16Unorm sampling and the type-8
views are not in `Patches/`. What followed is in
[stability-2026-11-09.md](stability-2026-11-09.md).

## 27.2, one change at a time

Guest `s272`, Reims `8a7b3334` (`Patches/reims` 0001–0016) with `Patches/qemu`
0001–0009, one boot per variant. "Skipped" is `draws_skipped_after_engine_refusal`, "missing" is
`texture_resolve_missing`, each counted over the boot.

| Variant | Skipped | Missing |
| --- | --- | --- |
| base | 128 | 114 |
| RGBA16Unorm sampling | 144 | 139 |
| ten-bit render targets (RGB10A2, BGR10A2) | 38 | 31 |
| R32Float render targets, with the type-11 identity fix | 28 | 19 |
| type-8 views over buffer textures | 168 | 150 |
| metal2vulkan constant-buffer helper arguments | not recorded | not recorded |
| ten-bit + RGBA16Unorm + type-8 | 0 | 0 |
| ten-bit + RGBA16Unorm + type-8 + metal2vulkan | 0 | 0 |

- The menu bar, the wallpaper and Terminal's text draw on base.
- The Dock's icons stay blank placeholders in every variant.
- With the combination, after Terminal was opened and quit once, the wallpaper
  drew as vertical stripes: each screen column showed the wallpaper's rightmost
  column. The cause is not found.

## 27.2 panics

About half of tonight's 27.2 boots panicked, in two classes:

1. Kernel memory corruption: `kalloc element modified after free` (twice),
   `c_decompress_page: c_segno … >= c_segments_available`, `Mutex … not owned`,
   and a kernel data abort.
2. `DebuggerXCallEnter> Debugger synch pending on cpu 3`, twice, always CPU 3,
   once with every type-11 write refused.

## What corrupts kernel memory

A class 1 panic was kept with `boot --keep-panic-memory`, and the guest kernel's
page tables were walked offline from that RAM with that boot's TTBR1 and TCR.

- The overwritten physical page, GPA `0x180730000`, belonged to Reims IOSurface
  mapping 2, a 1920 by 1080 RGBA16Float display surface. 2047 of its 2048 words
  were RGBA16Float pixels, with `0x3c00` (alpha 1.0) in their top 16 bits. Every
  pixel-filled kernel page in the dump lay inside mapping 2.
- The guest had given mapping 2's pages to the kernel, as compressor buffers,
  without an UNMAP.
- 0.75 s earlier Reims had logged `surface_page_collision`: new mappings 8 and 9
  claimed mapping 2's pages. It failed the new mappings closed and left mapping 2
  writable.
- Reims' render-flush copy path then wrote a whole frame into mapping 2's stale
  pages.

Corrupted values from earlier panics are exact RGBA8 to RGBA16Float conversions
of pixels: `0x3c00359636563707` is (112, 101, 89, 255). So the copying rails also
write stale guest RAM, not only the zero-copy rails that restore-on-linux.md
suspected.

Branch `collision-owner` quarantines both mappings on a collision until the
request protocol shows which one owns the pages. It has not been run on a guest.

## Walking the kernel's page tables from the drain worker

Since `Patches/qemu` 0009 the drain worker has no current vCPU to translate guest
virtual addresses with. Reims branch `kva-walk`, with a QEMU change that hands
Reims TTBR1, TCR, SCTLR and VBAR, walks the guest kernel's page tables itself and
checks the result against the vCPU path at run time. On 27.2 the check passed
about 11 s after boot on 3 of 3 boots, with no mismatches. One of the three still
had a class 1 panic, which fits a stale mapping rather than a bad translation.

## 13.6's black wallpaper

13.6's desktop wallpaper is black. It is not a regression of Reims 0012–0016,
`Patches/qemu` 0009, the zero-copy defaults, the vCPU count (1 or 4) or guest
memory (8 or 16 GiB): every one of those gives the same 36 write-back failures.

- The wallpaper decode writes a 1504 by 6016 RGBA32Uint surface in 6 by 6 tiles.
- Its page list has 9216 entries. Entries 3 to 4095 are zero, never populated, and
  the rest are valid. The list does not change until the UNMAP about 4.7 s later.
- Reims writes the whole window back after every tile. On a failed write-back it
  dropped the result, so the tiles did not accumulate.
- Branch `c136-resident` keeps the result as the authoritative copy; the 36 tiles
  then accumulate, as measured. A write-back of only the dirty rectangle, as a
  diagnostic, is being written and has not been run.

Why the guest leaves those 64 MiB unpopulated is not known.

## Tooling

- `boot --keep-panic-memory` (`0528bb1`) keeps a panicked guest's RAM and serial
  log.
- `boot` finds a panic header that follows other output on its line (`7cc5781`).
