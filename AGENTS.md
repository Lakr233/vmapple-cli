# vmapple-cli

Restore and boot macOS on QEMU's `vmapple` machine under KVM on arm64 Linux.

## Quick Reference

- **Build:** `swift build -c release`
- **Test:** `swift test`
- **Language:** Swift 6.0, SwiftPM. C targets where kernel or firmware interfaces need it.
- **Platform:** arm64 Linux. It compiles on macOS for editing, and only `doctor`'s output is meaningful there.
- **No Python anywhere.** No git submodules. Dependencies resolve by URL and version.

## Rules

- **No Mac in the flow.** A step that needs Virtualization.framework or a file copied from a Mac is not finished. A Mac-restored guest is only a control to compare against.
- **No Apple software in the repository**: no firmware, ROMs, disks, kernels or device trees, and no identities or tickets. Tools read them from the user's IPSW.
- **Say what was run.** README's status table and `Documents/Research/` record what has happened on a real host. A step that was not run is marked so.
- Do not create or use `/TODO.md`. Track plans in commit history and `Documents/Research/`.

## Layout

- `Sources/vmapple-cli`: the command line.
- `Sources/VMAppleKit`: host checks and everything the commands call.
- `Sources/CKVMProbe`: the throwaway KVM guest.
- `Sources/CTicket`, `Sources/CTatsu`: ticket requests through libtatsu, Linux only.
- `Patches/`: changes to QEMU, Reims, metal2vulkan and idevicerestore, applied with `git am` or `git apply`.
- `Documents/Research`: findings and designs.
- `.github/`: the release build, `build-linux.sh`, and the workflow that runs it.

## Swift

Pragmatic and minimal. `// MARK: -` to organize a file. Default access control, `private` only for clarity. Self-explanatory names, and comments only for what the code cannot say.
