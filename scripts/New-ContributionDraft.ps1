. "$PSScriptRoot\Common.ps1"

$result = Read-Json (Join-Path $env:OPENARM_EVIDENCE 'result.json')
if (-not $result.nativeVerified -or $result.route -ne 'validated') { throw 'Cannot prepare a contribution without native validation.' }
$null = New-Item -ItemType Directory -Path $env:OPENARM_OUTPUT -Force
$patch = Join-Path $env:OPENARM_OUTPUT 'changes.patch'
$exitCode = Invoke-LoggedProcess git @('--no-pager', 'diff', '--no-index', '--binary', '--', 'baseline', 'source') $env:OPENARM_EVIDENCE $patch
if ($exitCode -notin @(0, 1)) { throw "Cannot generate source patch (git exit $exitCode)." }
Copy-Item -LiteralPath (Join-Path $env:OPENARM_EVIDENCE 'result.json') -Destination $env:OPENARM_OUTPUT
$buildUrl = "$($env:SYSTEM_COLLECTIONURI)$([uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT))/_build/results?buildId=$env:BUILD_BUILDID&view=artifacts"
Set-Content -LiteralPath (Join-Path $env:OPENARM_OUTPUT 'pull-request-draft.md') -Value @"
# Windows Arm64: $($result.target)

**Draft only. No PR has been submitted or merged.**

Repository: $($result.repository)
Patch base commit: $($result.baselineCommit).
Validated checkout commit: $($result.commit), plus any local agent edits in the source snapshot.
changes.patch is the complete difference from the patch base, not an additional patch to the validated snapshot.
Evidence: $buildUrl

## Evidence
- Native host: $($result.host.os), $($result.host.osArchitecture).
- Installed EXE/DLL files: PE machine 0xAA64, with SHA-256 hashes in result.json.
- Configure, build, CTest (zero tests is an error), portable installation and smoke workflow passed.
- Launch + smoke median: $($result.performance.median) ms; raw samples are in result.json.
- No comparative x64 baseline was measured; no performance improvement is claimed.

## Before submission
- Link the maintainer's opt-in and the human review from the UpstreamReview gate.
- Describe the blocker and review changes.patch; do not submit an empty or unrelated diff.
- This CMake portable-install adapter does not verify MSI/MSIX, signing, GUI interaction,
  system dependencies or other application workflows. Add the target-specific evidence required.
- Preserve original attribution and follow the target repository's contribution policy.

All source changes were agent-generated. Volunteers provided prompts, decisions and testing.
Apply changes.patch from the configured source subdirectory with git apply -p2.
"@
