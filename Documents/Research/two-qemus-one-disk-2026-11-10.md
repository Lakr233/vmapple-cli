# Two QEMUs on One Disk

On 2026-11-10 three test VMs on the DGX stopped booting: a pulled 27.2 with
`nx_corruption_detected` and a panic, and 26.6.2 and 13.6 in recovery. The
cause was the test scripts and a gap in `boot`, not `Patches/reims` 0041–0045.

## What Happened

- A script ended each run by killing `vmapple-cli boot`. That left QEMU running:
  `boot` did not pass the signal on, and QEMU does not notice its parent going.
- The script then checked for a process named `qemu-system-aar`. The binaries
  under test were named `qemu-0040` and `qemu-0045`, so the check always passed.
- The next `boot` of the same VM started a second QEMU on the same `disk.img`
  and `aux.img`. QEMU opens them with `file.locking=off`.
- By the evening 21 QEMUs were running, up to four on one disk, and the host's
  load average was 65 to 70. `stop` timed out at 360 s under that load, which
  the script answered by killing more runners.

A disk written by two guests showed, on a later boot,
`obj_init: wrong object at … wanted oid … got oid …` and
`nx_corruption_detected_int: Container corruption detected`. A guest switched
off this way counts a failed boot, and after a few LLB sets `boot-command` to
`recover-system`.

## What Was Run

With every left-over QEMU ended and one guest at a time, on a 27.2 image pulled
again, each boot 330 s to the desktop and then `stop`:

- 0001–0045, two boots: no corruption line, no panic, `stop` returned in 14 s
  with `ApplePSCI - system off`.
- 0001–0045 plus a draft patch for heap textures written by compute, two boots
  on a second copy: the same.

So 0041–0045 do not damage the disk. The draft patch drew the same Dock icons
as 0045 and is not in `Patches/reims`.

## Changes

- `QEMUMachine.start` refuses a VM whose monitor socket accepts a connection.
  Run on the DGX: a second `boot` of a running VM printed
  `… is already running; stop it first` and exited 1.
- `boot` ends its QEMU on SIGTERM, SIGINT and SIGHUP, and sends SIGKILL if QEMU
  is still running 90 s after SIGTERM. Run on the DGX: `kill` of the runner 6 s
  into a boot left no QEMU, and a stub `--qemu` that ignored SIGTERM was killed
  after 91 s (`boot` exited 143).
- SIGKILL of the runner still leaves QEMU running. The first change keeps a
  second one off its disk, and `stop` reaches it.

## Getting a VM Out of Recovery

`boot-command` lives in the `system` partition of the NVRAM in `aux.img`: two
banks of 0x80000 at 10 MiB, each with an Adler-32 at +0x10 over the bytes from
+0x14. iBoot's recovery prompt reads the variable (`vmapple-cli iboot <vm>
"getenv boot-command"`) but stalls on `setenv boot-command`.

On the DGX the variables LLB had added (`boot-command`, `recovery-boot-mode`,
`iboot-failure-reason`, `iboot-failure-volume`, `failboot-breadcrumbs`,
`boot-picker-bringup-reason`) were removed from both banks with a throwaway
script and the checksums recomputed. Both VMs still stopped in iBoot, because
several QEMUs had also written their disks, and restoring them again fixed both
(26.6.2 in 6.5 min after a first attempt failed with `Unable to open device in
restore mode`, and 13.6 in 5.5 min; both then went through `account`, login,
the user's setup panels, the desktop and `stop` on 0001–0045).

`vmapple-cli` has no command to edit NVRAM.
