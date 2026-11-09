# Tart Images

`vmapple-cli pull` makes a VM from the OCI images that Tart publishes and that
[macos-image](https://github.com/MiniMillionaire/macos-image) builds for
mini-control's Mac minis. Those images are restored on a Mac by
Virtualization.framework; `pull` only reads them, so vmapple-cli itself still
needs no Mac. This note records the format as read from the registry on
2026-11-09 and what booting one under KVM did.

## Format

One OCI image manifest (`application/vnd.oci.image.manifest.v1+json`) whose
layers are, in order:

| Layer | Media type | Contents |
| --- | --- | --- |
| config | `application/vnd.cirruslabs.tart.config.v1` | Tart's `config.json` |
| disk, many | `application/vnd.cirruslabs.tart.disk.v2+zstd` or `application/vnd.cirruslabs.tart.disk.v2` | consecutive chunks of the raw disk, zstd or Apple LZ4 |
| NVRAM | `application/vnd.cirruslabs.tart.nvram.v1` | Virtualization.framework's auxiliary storage |

- Each disk layer carries `org.cirruslabs.tart.uncompressed-size` and
  `org.cirruslabs.tart.uncompressed-content-digest`. Chunks are 512 MiB and the
  last is shorter; the disk is their concatenation. mini-control's worker and
  server accept exactly this set and refuse `disk.v1`.
- macos-image's golden-gate images (`macos-golden-gate-vanilla`, `-base`,
  `-xcode`, `-slim-xcode`) use zstd, one frame per layer: 27.2 vanilla is 75
  layers, a 40 GB disk, 16.6 GB to download. Cirrus Labs' own images use LZ4
  (`macos-sequoia-vanilla`: 96 layers).
- The LZ4 layers are Apple's stream format: `bv41` blocks (decoded size,
  encoded size, raw LZ4 whose matches may reach into the previous 64 KiB of
  output), `bv4-` stored blocks and a closing `bv4$`. The `lz4` tool does not
  read it; vmapple-cli decodes it itself. zstd layers go through the `zstd` tool.
- The image config (`application/vnd.oci.image.config.v1+json`) holds labels;
  macos-image sets `dev.macos-image.version`, `.build` and `.variant`. `pull`
  reads the version from the disk instead, so it works on images without them.

`config.json` (Tart's) gives what QEMU needs besides the disks:

- `ecid`: base64 of a binary plist `{ECID: <integer>}`, the machine identifier
  the guest's boot tickets are signed for. It is a random 64-bit value and may
  have the top bit set, so the plist stores it as a 16 byte integer. `pull`
  passes it to QEMU as the machine's `uuid`; every VM pulled from one image
  shares it, as Tart clones on a Mac do.
- `hardwareModel`: `{PlatformVersion: 2, DataRepresentationVersion: 2,
  MinimumSupportedOS: [13, 0, 0]}`. Platform version 2 is `VirtualMac2,1`, the
  machine QEMU's `vmapple` models; `pull` refuses anything else.
- `diskFormat` is `raw`; Tart's `asif` sparse format is refused.
- CPU count, memory, display and MAC address are ignored: `boot` takes
  `--cpus` and `--memory`, and the VM has no network.

`nvram.bin` is 33,570,816 bytes: a 16 KiB header of Virtualization.framework's
own, then the storage QEMU and OpenAVB read from offset 0, starting `HUFA`, with
LLB at 128 KiB and NVRAM at 10 MiB. A VM restored by vmapple-cli has the same
layout at offset 0. `pull` drops the header and pads the end, so `aux.img`
keeps its size.

## The Kernel Handoff

`boot` needs where the installed iBoot hands off to the kernel
(`handoffAddresses`). `restore` reads it from the IPSW's iBoot; a pulled image
has no IPSW, so `pull` reads the installed iBoot from the disk:

- GPT, then each APFS container at its newest checkpoint, then the volume whose
  role is Preboot.
- `<volume group UUID>/boot/active` names the boot objects in use, and
  `<UUID>/boot/<that name>/usr/standalone/firmware/iBoot.img4` is the iBoot,
  an IMG4 whose IM4P payload is LZFSE.
- The version comes from `<UUID>/cryptex1/current/SystemVersion.plist`, then
  `<UUID>/restore/SystemVersion.plist`.

The reader is read-only and covers unencrypted volumes with uncompressed
files, which Preboot is. Checked against seven VMs restored by vmapple-cli
(13.6, 14.6.1, 15.6.1 twice, 26.6.2 twice, 27.2): the Preboot iBoot gave the
same handoff addresses and version that `restore` recorded from each IPSW
(`PrebootTests`, with `VMAPPLE_TEST_VM` set to the VM's directory).
