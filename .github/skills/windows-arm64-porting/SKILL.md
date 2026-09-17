---
name: windows-arm64-porting
description: Build and validate native Windows Arm64 support, never x64/x86 emulation workarounds.
---

The objective is **native Windows Arm64 support**, not merely running on an Arm64
machine. Do not fix a porting task by selecting or downloading x64/x86 binaries,
adding an emulation fallback, renaming binaries, or disabling required features.
Existing emulation paths may be diagnosed, but improving them is outside this
skill's repair scope and cannot qualify as native evidence or a porting PR.

1. Read the pinned target configuration, result.json and the failing checkpoint log.
2. Distinguish source, dependency, packaging, CI/tooling and access blockers.
3. Use supported upstream architecture detection and compiler/build primitives.
   Fix native source, dependency builds, packaging and CI together as needed.
   Missing Arm64 dependencies require a native build/port or a specific human
   blocker, never an x64 substitution.
4. Make minimal agent-generated changes. Never delete or weaken validation to pass.
5. Use `scripts\Test-NativeWorker.ps1` to inventory worker prerequisites; it is not
   native execution evidence. Rebuild on an actual Windows Arm64 worker with an
   Arm64 validation process. Confirm every packaged EXE/DLL, including required
   runtime dependencies, has PE machine 0xAA64. For interpreted targets, keep the
   target package inventory separate from incidental files installed with the
   interpreter. Verify the actual interpreter and loaded dependencies during the
   core workflow: platform ARM64X DLLs may have a different on-disk header, but
   must expose a verified native Arm64 (0xAA64) loaded view in the native process.
   A filename exception, ARM64EC-only view or unverified hybrid header is not
   sufficient. Preserve both on-disk and loaded-view evidence. Run nonempty tests, install to a
   fresh prefix, and launch the installed application's declared core workflow.
   An Arm64 filename, cross-build, x64 launch, or version/help probe is insufficient.
6. Record raw wall-time samples and binary hashes. Clearly limit claims to the
   measured workflow; do not invent baselines or extrapolate application support.
7. On a human blocker, preserve the source snapshot and checkpoint, record prior
   attempts and specific help needed, and use the existing Azure Boards work item.
   Keep Teams updates in the same blocker thread.
8. Treat the Human gate as readiness only. Freeze owner-authored and owner-edited
   guidance, exact source, baseline and config before ResumeApproval. Verify the
   approved manifest digest and current build ID before consuming that snapshot;
   never reread live comments or change the source commit after approval. Restore
   fresh-worker prerequisites, then revalidate. Use a bounded new budget.
9. If native validation is missing or unsupported, return `needs_human` with the
   exact native build/runtime gap; do not substitute a compatibility-success result.
   Prepare a draft only after native evidence, human review and maintainer opt-in.
   No automatic upstream PR submission or merge is allowed.

The included CMake portable-install pattern is a starting point, not a claim that
all application installers, GUI workflows or dependency sets have been validated.
For OpenArm repository changes, run `scripts\Test-Project.ps1`. Keep its x64 CI
results separate from native, live volunteer-loop and real agent-task evidence.
