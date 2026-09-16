# Contributing to OpenArm

Use a branch and a pull request with a focused, agent-generated patch. Explain the
observed problem, acceptance criteria, relevant trust boundaries and limitations.
Never commit tokens, bridge URLs, local tool installations or generated `out`
evidence. Do not weaken tests or claim mocked/cross-built results are native.

Run `.\scripts\Test-Project.ps1` before review (see README for local tool overrides).
Add regression checks to `tests\Test-OpenArm.ps1` for behavior changes,
`tests\Test-OutputPaths.ps1` for public output-path behavior, and
`tests\test_pipeline.py` for YAML wiring changes. Update the associated README,
agent or skill instructions when the workflow changes. Changes to approval,
credentials, pools or source selection require explicit human trust-boundary review.
The approval regression checks must continue to reject unauthorized guidance,
source/content substitution, missing digests and approval replay.

Repository administrators must configure the separate `azure-pipelines-ci.yml`
pipeline and make its actual PR result plus independent human review required.
Azure Repos needs a build-validation branch policy; a YAML `pr` trigger is not
enforcement there. Do not authorize native pools, variable groups, service
connections or secrets for untrusted PR builds. This repository cannot set those
permissions or invent reviewers on your behalf.

## Producing real agent-task evidence

Before an agent starts, record the task, pinned source revision, acceptance checks
and native workflow that will decide success. Use representative work rather than
rerunning an unchanged test suite. Preserve the original failure and the resulting
patch, prompts, tool/agent versions, elapsed time, interventions, and independently
evaluated acceptance results. Keep source snapshots or content hashes linking all
of those records. Store evidence as restricted build artifacts, not credentials
or uncontrolled dumps in the repository.

Repeat at least one task three times from clean environments and the same starting
revision. Each repetition must be an actual new agent attempt with its own output
and acceptance result; report failures as well as passes. Use the native pipeline
for Windows Arm64 claims. Repository CI is only a prerequisite, not a replacement.

For new local maintenance trials, use the **v2 local-validation protocol** after
reviewing the candidate and acceptance checks. Run the trusted checkout's
`scripts\Test-LocalCandidate.ps1 -CandidateRoot <absolute-candidate> -Output
<absolute-new-directory-inside-candidate>` (with local tool overrides if needed).
It passes absolute output/root arguments and explicitly sets the child process
working directory to the candidate; `invocation.json` records the launch and exit.
Candidates must contain the updated `Test-Project.ps1` with `-OutputRoot` support.
No agent or independent judge is launched by this validation command.

Relative `-Output` paths in the worker and repository checks follow the caller's
PowerShell filesystem location. `-OutputRoot` is opt-in so ordinary CI can still
publish to its external artifact staging directory. When set, it requires an
existing root, a new strict-descendant output path, and no existing symlink or
junction in the output ancestry, all checked before output creation.
This is mistake prevention, **not filesystem confinement**: mutable candidate
code, concurrent junction replacement, tool caches and arbitrary agent commands
are not controlled. Run untrusted candidates only in a disposable VM or under an
OS-enforced account/filesystem boundary; this repository does not provision one.

Keep the original protocol version, partial outcomes, deviations and evidence.
The corrected launcher does not retroactively repair prior trials. A claim about
v2 agent performance requires fresh independently judged trials, not a rerun of
the old scoring inputs. A separately scoped local-maintenance score may use old
records unchanged, but must not be presented as native-porting or live-cloud
capability.

For the volunteer demonstration, preserve the initial failure, one work item and
Teams thread, owner guidance, exact approved snapshot, resumed native result, and
reply to that same thread. Configure and authorize the bridge before live writes.
Do not call mock coordination tests a live demonstration.

Promote a remediation into a reusable pattern only after repeated native success,
provenance, a regression check and human review. Update the instructions used by
future runs, then record whether an actual later run improves with the pattern.
Re-score using the same evaluation rubric and declared scope only after this
evidence exists; additional scaffolding alone does not raise lifecycle capability.
