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

## Booting

A pulled 27.2 first panicked mounting its Data volume: `"unencrypted data
volume is not allowed" @apfs_vfsops.c:2399`. The Data volume of a Tart image is
unencrypted (`fs_flags` 0x1); a VM restored by vmapple-cli has an encrypted one
(0x100). Its file-system tree is plaintext with valid checksums, so no key is
missing. The difference is what each guest was told about its disk.

What the 27.2 kernel does (kernelcache.release.vma2, 26B123):

- `apfs_mount_crypto_check` panics for an unencrypted Data volume when the
  device's encryption type is non-zero. It passes if `/filesystems` has
  `DoNotUseSEP`, if `csr_check(CSR_ALLOW_APPLE_INTERNAL)` passes, or if the
  device has `DK_FEATURE_PRIORITY`. The encryption type is `DKIOCGETENCRYPTIONTYPE`,
  which AppleVirtIOStorage answers from its `Encryption Type`.
- `AppleVirtIOStorageDevice::start` sets that to AES-XTS unless the disk carries
  a vendor configuration: a virtio-pci capability with `cfg_type` 9
  (`VIRTIO_PCI_CAP_VENDOR_CFG`) and vendor ID 0x106b, the data inline in PCI
  configuration space after the six-byte header. With legacy feature bit 0 set,
  the disk does not encrypt. The data starts with legacy features (u64), version
  (u32), compatible size (u32), features (u64) and extended request size (u32).
  The driver writes the negotiated fields back in place and checks the byte
  count, not the contents.
- Virtualization.framework builds this for its macOS disks in
  `AvpVirtioBlockDevice` (`com.apple.Virtualization.VirtualMachine`, macOS 27):
  legacy features 3, version 1, compatible size 0x1c, features 0, extended
  request size 0x60.

`Patches/qemu` 0017 adds `vendor-legacy-features` to `vmapple-virtio-blk-pci`;
`boot` sets it to 3 on the root disk of a VM whose `vm.json` has
`inlineEncryption: false`, which `pull` writes. The extended request size is 0,
not the framework's 0x60. Offered 0x60, the guest started the disk, reached
`DRIVER_OK` and sent it no request, so the boot waited for its root and went to
Recovery. QEMU does not parse extended requests.

Ruled out on the way, with the framework and the 27.2 kernel:

- A Secure Enclave. `vma2` has none: the framework ships `AVPSEPBooter` only
  for `vresearch1`, and OpenSEP stands in for that one. The guest's keystore is
  AppleVPKeyStore, without a SEP.
- Machine-bound keys. The framework's `AppleAesEngine` fills key selects 1 to 3
  with `{1}`, `{2}` and `{3}` followed by zeros: `uid1_key` is a constant in the
  binary, and 2 and 3 are set in the constructor. QEMU's `hw/vmapple/aes.c` has
  the same values. `AppleVirtualPlatformHostKeyData` is the host's identity key
  for the guest's strong identity, not storage.
- `nvram.bin`. Its 16 KiB header carries no key; the rest is the same layout as
  a restored VM's AUX.

Run on the DGX on 2026-11-09, QEMU `hmacos-arm` + `Patches/qemu` 0001–0017,
OpenAVB `c35e417`, `macos-golden-gate-vanilla:27.2` pulled fresh:

1. Without 0017: the Data volume panic above, every boot.
2. 0017 with extended request size 0x60: no request reached the root disk;
   Recovery panic (`Reboot into Recovery`).
3. Extended request size 0: Data mounted, `loginwindow` started.
4. A cold boot to the desktop (logged in automatically, "Your Mac has been
   updated to macOS 27.2"), `stop`, then a second cold boot to the desktop. No
   panic in either.

During those runs, after a boot that `boot --seconds` ended in userspace, two
later boots of that disk stopped in iBootStage1, and the disk was pulled again
before step 4. That disk had also been through step 2's Recovery panic.

Rerun on the DGX on 2026-11-09 with the same pieces, on an image pulled fresh
and on the step 4 disk, every run followed by a boot of 100 to 120 s:

- `boot --seconds` 15, 40 and 150 on the step 4 disk, and 90 on the fresh
  disk's first boot (the one that finishes the update): each answered the power
  button, reached `ApplePSCI - system off`, and the next boot went through
  iBootStage1 and iBootStage2 to `loginwindow`.
- QEMU killed with SIGKILL 75 s into a boot, after `loginwindow` started: the
  next boot also went through to `loginwindow` and shut down cleanly.

The iBootStage1 stop did not happen again, so `--seconds` is not what caused
it. `boot --seconds` used to sleep the whole time even after QEMU had ended; it
now returns when QEMU does. Killing the `boot` runner instead also left its
QEMU open on the disk while the next boot started; see
[two-qemus-one-disk-2026-11-10.md](two-qemus-one-disk-2026-11-10.md).
