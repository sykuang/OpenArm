---
name: windows-arm64-porting
description: Reproduce Windows Arm64 build blockers and prepare evidence-backed porting changes.
---

1. Read the pinned target configuration, result.json and the failing checkpoint log.
2. Distinguish source, dependency, packaging, CI/tooling and access blockers.
3. Prefer supported upstream architecture detection and compiler/build primitives
   over hardcoded x64 replacements. Check all affected call sites and dependencies.
4. Make minimal agent-generated changes. Never delete or weaken validation to pass.
5. Use `scripts\Test-NativeWorker.ps1` to inventory worker prerequisites; it is not
   native execution evidence. Rebuild on an actual Windows Arm64 worker. Confirm every packaged EXE/DLL has PE
   machine 0xAA64, run nonempty tests, install to a fresh prefix, and launch the
   installed application's declared core workflow.
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
9. Prepare a draft only after native evidence, human review and maintainer opt-in.
   No automatic upstream PR submission or merge is allowed.

The included CMake portable-install pattern is a starting point, not a claim that
all application installers, GUI workflows or dependency sets have been validated.
For OpenArm repository changes, run `scripts\Test-Project.ps1`. Keep its x64 CI
results separate from native, live volunteer-loop and real agent-task evidence.
