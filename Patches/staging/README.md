# Staging

Patch series that are not part of the default stack. `boot`, `account` and
`restore` are validated against `Patches/qemu`, `Patches/reims` and
`Patches/metal2vulkan` only; nothing here changes that.

## reims-guard-old

The wire watch and guard for the kernels of macOS 13.6, 14.6.1 and 15.6.1,
which `Patches/reims` turns off. Four patches applied after `Patches/reims`
0001–0040, that is on Reims 44127711 with 0001–0040 (the tree of c963eab4).
Unit-tested only; no guest was booted with them. See
[new-tree-spike-2026-11-09.md](../../Documents/Research/new-tree-spike-2026-11-09.md#guard-for-136-1461-and-1561).

```sh
git -C reims am "$PATCHES"/reims/*.patch "$PATCHES"/staging/reims-guard-old/*.patch
```

## newtree

A spike of steelbrain's rewritten Reims (libreims_vgpu and its C API) and its
QEMU, with this project's KVM port. It replaces the Reims and QEMU of the
default stack together and uses none of `Patches/reims` or the Reims shim
patches in `Patches/qemu`. Restore is not ported. Results and blockers:
[new-tree-spike-2026-11-09.md](../../Documents/Research/new-tree-spike-2026-11-09.md).

| Series | Base | Patches |
| --- | --- | --- |
| `newtree/reims-vgpu` | steelbrain/reims-vgpu `master` at 1fe0acb | 4: YahiaAngelo's 84089ca (guest page size per device), the SDL3 console build, two diagnostic switches |
| `newtree/qemu` | steelbrain/qemu-reims-vgpu `steelbrain/reims-vgpu` at 1b41f5f5db | 14: the KVM port from the DGX fork, five of `Patches/qemu`, omvm's virtio-blk change, three build and ordering fixes |

```sh
git clone https://github.com/steelbrain/reims-vgpu.git reims-vgpu
git -C reims-vgpu checkout --detach 1fe0acb
git -C reims-vgpu am "$PATCHES"/staging/newtree/reims-vgpu/*.patch

git clone --filter=blob:none https://github.com/steelbrain/qemu-reims-vgpu.git qemu
git -C qemu checkout --detach 1b41f5f5db
git -C qemu am "$PATCHES"/staging/newtree/qemu/*.patch
```

Each series was applied with `git am` to a fresh clone at its base on the DGX
and gave the tree of the branch it was exported from: reims-guard-old
`fcb94967` (2697f743), newtree/reims-vgpu `7029d854` (314e248f1) and
newtree/qemu `a278a71a` (fcdfd20f5d). Patches from other people keep their
authors.
