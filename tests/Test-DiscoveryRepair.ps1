Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\discovery-repair-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path "$root\scripts", "$root\targets\github", "$root\input"
Copy-Item -LiteralPath "$repo\scripts\Common.ps1", "$repo\scripts\GitHubRepair.ps1",
    "$repo\scripts\Select-DiscoveryRepair.ps1" -Destination "$root\scripts"
$saved = @{ GITHUB_OUTPUT = $env:GITHUB_OUTPUT; GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY }
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
$task = @{
    id = 'fixture'; mode = 'cmake'; repository = 'https://github.com/upstream/widget'; commit = 'a' * 40
    sourceSubdirectory = '.'; generator = 'Visual Studio 17 2022'; executable = 'bin\widget.exe'
    smokeArguments = @('--smoke-test'); performanceSamples = 3; context = 'Offline fixture'
    issue = 'https://github.com/upstream/widget/issues/1'; allowedFiles = @('main.cpp'); fork = 'tester/widget'
}
function New-Review {
    @{
        schemaVersion = 1; phase = 'Agent'; status = 'completed'; reviewer = 'github_copilot_cli'
        authVerified = $true; nativeVerified = $false; citationMode = 'numbered_source_passages'
        runId = '123'; workflowCommit = 'b' * 40; requestedCount = 1; assessedCount = 1
        assessments = @(@{
            fullName = 'upstream/widget'; eligible = $true; assessment = 'reported_missing_native_support'
            evidenceStatus = 'corroborated_report'; eligibilityReason = 'provisional_reported_native_gap'
            reviewScope = 'ranked'; tracks = @('trending'); upstreamDisposition = 'no_native_fix_identified'
            scope = 'project'; dependency = $null
            citations = @(@{ kind = 'issue'; url = 'https://github.com/upstream/widget/issues/1' },
                @{ kind = 'readme'; url = 'https://github.com/upstream/widget/blob/main/README.md' })
        })
        recommendations = @(@{ fullName = 'upstream/widget'; track = 'trending' })
    }
}
function Run-Selection([string] $Name, $Review = (New-Review), [string] $RunId = '123') {
    Write-Json "$root\input\report.json" $Review
    $errorText = ''
    try {
        & "$root\scripts\Select-DiscoveryRepair.ps1" -TaskId fixture -DiscoveryRunId $RunId -DiscoveryCommit ('b' * 40) `
            -InputPath "$root\input" -Output "$root\$Name" -OutputRoot $root
    } catch { $errorText = $_.Exception.Message }
    @{ error = $errorText; report = Read-Json "$root\$Name\report.json" }
}
try {
    $env:GITHUB_OUTPUT = "$root\outputs.txt"; $env:GITHUB_STEP_SUMMARY = "$root\summary.md"
    Write-Json "$root\targets\github\fixture.json" $task
    $result = Run-Selection manual -RunId ''
    Assert (-not $result.error -and $result.report.status -eq 'ready' -and $result.report.taskId -eq 'fixture') 'Existing explicit reviewed-task selection remains available'
    $result = Run-Selection automatic
    Assert (-not $result.error -and $result.report.status -eq 'ready' -and $result.report.taskId -eq 'fixture' -and
        $result.report.repairRepository -eq $task.repository -and $result.report.reviewSha256 -match '^[a-f0-9]{64}$' -and
        -not $result.report.nativeVerified -and -not $result.report.forkCreated) "The discovered candidate selects its issue-matched native adapter without a source URL or executing target code: $($result.error); $($result.report.reason)"
    $review = New-Review
    $review.assessments[0].fullName = 'application/widget'
    $review.assessments[0].scope = 'dependency'
    $review.assessments[0].dependency = @{ name = 'widget'; repository = 'upstream/widget' }
    $review.recommendations[0].fullName = 'application/widget'
    $result = Run-Selection dependency $review
    Assert ($result.report.status -eq 'ready' -and $result.report.repairRepository -eq $task.repository) 'Repair the identified dependency rather than the parent application'
    $review.assessments[0].dependency.repository = $null
    $result = Run-Selection unknown-owner $review
    Assert ($result.report.status -eq 'needs_human' -and -not $result.report.taskId) 'Unknown dependency ownership cannot generate an executable task'
    $review = New-Review; $review.recommendations = @()
    $result = Run-Selection no-candidate $review
    Assert ($result.report.status -eq 'no_candidate' -and -not $result.report.taskId) 'No recommendation does not fall back to the workflow default Hermes diagnostic task'
    $review = New-Review
    $review.assessments[0].citations[0].url = 'https://github.com/upstream/widget/issues/2'
    $result = Run-Selection unrelated-issue $review
    Assert ($result.report.status -eq 'needs_human' -and -not $result.report.taskId) 'A different issue in the same repository does not authorize a stale repair task'
    $diagnose = $task.Clone(); $diagnose.mode = 'diagnose'; $diagnose.allowedFiles = @()
    Write-Json "$root\targets\github\fixture.json" $diagnose
    $result = Run-Selection diagnostic
    Assert ($result.report.status -eq 'needs_human' -and -not $result.report.taskId) 'A diagnosis-only manifest is not an automatic native repair adapter'
    Remove-Item -LiteralPath "$root\targets\github\fixture.json"
    $result = Run-Selection no-adapter
    Assert ($result.report.status -eq 'needs_human' -and $result.report.candidate.fullName -eq 'upstream/widget' -and
        $result.report.reason -like '*native dependency/build recipe*' -and -not $result.report.taskId -and
        -not $result.report.pullRequestUrl) 'Absent adapters preserve automatic selection and exact native blockers, not a documentation PR or fabricated config'
    Write-Json "$root\targets\github\fixture.json" $task
    $secondTask = $task.Clone(); $secondTask.id = 'duplicate'
    Write-Json "$root\targets\github\duplicate.json" $secondTask
    $result = Run-Selection ambiguous
    Assert ($result.report.status -eq 'needs_human' -and $result.report.reason -like '*Multiple tracked*') 'Ambiguous native adapters require review instead of arbitrary selection'
    Remove-Item -LiteralPath "$root\targets\github\duplicate.json"
    $review = New-Review
    $other = $review.assessments[0].Clone(); $other.fullName = 'foundation/library'; $other.tracks = @('foundational')
    $review.assessments += $other; $review.requestedCount = 2; $review.assessedCount = 2
    $review.recommendations = @(@{ fullName = 'foundation/library'; track = 'foundational' }) + $review.recommendations
    $result = Run-Selection priority $review
    Assert ($result.report.candidate.fullName -eq 'upstream/widget' -and $result.report.candidate.track -eq 'trending') 'Trending then Foundational selection is deterministic, not dependent on array order'
    foreach ($case in 'run', 'sha', 'incomplete', 'failed', 'unauthenticated', 'duplicate', 'unknown', 'uncorroborated',
        'unranked', 'active-fix', 'wrong-track', 'duplicate-track', 'missing-assessment') {
        $review = New-Review
        switch ($case) {
            'run' { $review.runId = '124' }
            'sha' { $review.workflowCommit = 'c' * 40 }
            'incomplete' { $review.requestedCount = 2 }
            'failed' { $review.status = 'failed' }
            'unauthenticated' { $review.authVerified = $false }
            'duplicate' { $review.assessments += $review.assessments[0] }
            'unknown' { $review.assessments[0].assessment = 'unknown' }
            'uncorroborated' { $review.assessments[0].evidenceStatus = 'uncorroborated_report' }
            'unranked' { $review.assessments[0].reviewScope = 'focus' }
            'active-fix' { $review.assessments[0].upstreamDisposition = 'active_native_fix' }
            'wrong-track' { $review.recommendations[0].track = 'foundational' }
            'duplicate-track' { $review.recommendations += $review.recommendations[0] }
            'missing-assessment' { $review.recommendations[0].fullName = 'elsewhere/widget' }
        }
        $result = Run-Selection $case $review
        Assert ($result.error -and $result.report.status -eq 'failed' -and -not $result.report.taskId) "Reject invalid handoff without a fallback task: $case"
    }
    $result = Run-Selection bad-id -RunId '123/../../456'
    Assert ($result.error -and $result.report.status -eq 'failed') 'A discovery run selector is not a URL or filesystem path'
    Write-Host "$checks automatic discovery repair checks passed."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $root -Recurse -Force
}
