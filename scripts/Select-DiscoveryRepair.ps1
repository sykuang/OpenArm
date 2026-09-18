[CmdletBinding()]
param(
    [string] $TaskId = $env:OPENARM_REPAIR_TASK,
    [string] $DiscoveryRunId = $env:OPENARM_DISCOVERY_RUN,
    [string] $DiscoveryCommit = $env:OPENARM_DISCOVERY_COMMIT,
    [string] $InputPath = '',
    [Parameter(Mandatory)] [string] $Output,
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\GitHubRepair.ps1"

$Output = Resolve-OutputPath $Output $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Selection output already exists; preserve the earlier handoff.' }
$null = New-Item -ItemType Directory -Path $Output
$report = @{
    schemaVersion = 1; phase = 'Select'; status = 'selecting'; reason = ''; error = $null
    discoveryRunId = $DiscoveryRunId; discoveryCommit = $DiscoveryCommit
    candidate = $null; repairRepository = $null; taskId = $null; sourceCommit = $null
    nativeVerified = $false; forkCreated = $false; pullRequestUrl = $null
}
try {
    if (-not $DiscoveryRunId) {
        $task = Read-RepairTask $TaskId
        $report.taskId = $task.id
        $report.sourceCommit = $task.commit
        $report.repairRepository = $task.repository
        $report.status = 'ready'
        $report.reason = 'The explicitly selected tracked task is ready for its configured preparation, not yet validated.'
    } else {
        if ($DiscoveryRunId -cnotmatch '^[1-9][0-9]*$' -or $DiscoveryCommit -cnotmatch '^[a-f0-9]{40}$') {
            throw 'Automatic repair requires an authenticated successful discovery run and its exact workflow commit.'
        }
        $path = Join-Path (Resolve-OutputPath $InputPath $OutputRoot) 'report.json'
        if ((Get-Item -LiteralPath $path).Length -gt 16MB) { throw 'Discovery review exceeds the handoff size limit.' }
        $review = Read-Json $path
        if ($review.schemaVersion -ne 1 -or $review.phase -ne 'Agent' -or $review.status -ne 'completed' -or
            $review.reviewer -ne 'github_copilot_cli' -or $review.authVerified -ne $true -or $review.nativeVerified -ne $false -or
            $review.citationMode -ne 'numbered_source_passages' -or
            $review.runId -cne $DiscoveryRunId -or $review.workflowCommit -cne $DiscoveryCommit -or
            $review.assessments -isnot [array] -or $review.assessments.Count -lt 1 -or $review.assessments.Count -gt 101 -or
            $review.assessedCount -ne $review.assessments.Count -or $review.requestedCount -ne $review.assessedCount -or
            @($review.assessments.fullName | Sort-Object -Unique).Count -ne $review.assessedCount -or
            $review.recommendations -isnot [array] -or $review.recommendations.Count -gt 2) {
            throw 'Discovery handoff is not a complete, authenticated review from the requested successful run.'
        }
        $report.reviewSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $seenTracks = @{}
        foreach ($recommendation in $review.recommendations) {
            $assessments = @($review.assessments | Where-Object fullName -ceq $recommendation.fullName)
            if ($recommendation.track -cnotin @('trending', 'foundational') -or $seenTracks.ContainsKey($recommendation.track) -or
                $assessments.Count -ne 1 -or $assessments[0].fullName -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' -or
                $assessments[0].eligible -ne $true -or $assessments[0].assessment -ne 'reported_missing_native_support' -or
                $assessments[0].evidenceStatus -ne 'corroborated_report' -or
                $assessments[0].eligibilityReason -ne 'provisional_reported_native_gap' -or
                $assessments[0].tracks -cnotcontains $recommendation.track -or $assessments[0].reviewScope -ne 'ranked' -or
                $assessments[0].upstreamDisposition -notin @('no_native_fix_identified', 'workaround_only') -or
                $assessments[0].scope -notin @('project', 'dependency', 'feature')) {
                throw 'A recommendation is not an eligible, corroborated ranked assessment; no task is substituted.'
            }
            $seenTracks[$recommendation.track] = $true
        }
        $recommendation = $review.recommendations | Sort-Object { if ($_.track -eq 'trending') { 0 } else { 1 } } |
            Select-Object -First 1
        if (-not $recommendation) {
            $report.status = 'no_candidate'
            $report.reason = 'The completed review recommends no missing-native-support candidate. No fallback repository, fork or PR is created.'
        } else {
            $candidate = $review.assessments | Where-Object fullName -ceq $recommendation.fullName | Select-Object -First 1
            $report.candidate = @{ fullName = $candidate.fullName; track = $recommendation.track; scope = $candidate.scope
                dependency = $candidate.dependency; citations = $candidate.citations }
            $owner = if ($candidate.scope -eq 'project') { $candidate.fullName }
                elseif ($candidate.dependency) { $candidate.dependency.repository } else { $null }
            $report.status = 'needs_human'
            if (-not $owner) {
                $report.reason = 'Discovery selected a dependency/feature gap but did not identify its owning repository. No application patch, guessed dependency or PR is substituted.'
            } else {
                if ($owner -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repair repository identity.' }
                $report.repairRepository = "https://github.com/$owner"
                $issues = @($candidate.citations | Where-Object { $_.kind -eq 'issue' -and
                    $_.url -cmatch '^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$' } | ForEach-Object url)
                $tasks = @(foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\targets\github') -Filter '*.json') {
                    $entry = Read-RepairTask $file.BaseName
                    if ($entry.mode -eq 'cmake' -and $entry.repository -ieq $report.repairRepository -and
                        $entry.issue -cin $issues) { $entry }
                })
                if ($tasks.Count -eq 1) {
                    $report.taskId = $tasks[0].id
                    $report.sourceCommit = $tasks[0].commit
                    $report.status = 'ready'
                    $report.reason = 'The discovered repository and cited issue match one tracked native repair task. Native baseline, independent validation and publishing guards still apply.'
                } elseif ($tasks.Count -gt 1) {
                    $report.reason = 'Multiple tracked native repair tasks match this repository and cited issue; the repair scope must be disambiguated before execution.'
                } else {
                    $report.reason = "Automatically selected $owner, but no tracked native repair adapter matches its cited issue. Missing: a reviewed immutable source pin, editable source scope, native dependency/build recipe, nonempty tests, fresh install and installed core-workflow validation, plus a permitted destination fork. Discovery evidence alone cannot authorize a native-fix draft. No target code, fork or PR was created."
                }
            }
        }
    }
    if ($report.status -in @('needs_human', 'no_candidate')) { Write-Warning $report.reason }
} catch {
    $report.status = 'failed'
    $report.taskId = $null
    $report.error = $_.Exception.Message
    throw
} finally {
    Write-Json (Join-Path $Output 'report.json') $report
    if ($env:GITHUB_OUTPUT) {
        @("status=$($report.status)", "taskId=$($report.taskId)") | Add-Content -LiteralPath $env:GITHUB_OUTPUT
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        "OpenArm automatic selection: **$($report.status)**. $([Net.WebUtility]::HtmlEncode($report.reason))" |
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
}
