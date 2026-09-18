[CmdletBinding()]
param(
    [string] $TaskId = $env:OPENARM_REPAIR_TASK,
    [Parameter(Mandatory)][string] $InputPath,
    [Parameter(Mandatory)][string] $Output,
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\GitHubRepair.ps1"
$Output = Resolve-OutputPath $Output $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Publisher output already exists; inspect earlier mutation evidence.' }
$null = New-Item -ItemType Directory -Path $Output
$resultPath = Join-Path $Output 'result.json'
$token = $env:OPENARM_GITHUB_TOKEN
$report = @{ schemaVersion = 1; status = 'checking'; requests = @(); pullRequestUrl = $null; commit = $null; error = $null
    forkCreated = $false }
$forkRoute = ''; $sourceRoute = ''

function Invoke-RepairApi([string] $Method, [string] $Route, $Body = $null, [int] $Expected = 200,
    [switch] $AllowMissing, [switch] $AllowNotReady) {
    $forkCreation = $Method -eq 'POST' -and $Route -eq "$sourceRoute/forks" -and $env:OPENARM_CREATE_FORK -eq 'true'
    if ($Method -ne 'GET' -and -not $forkCreation -and ($Method -ne 'POST' -or $Route -notin @(
        "$forkRoute/git/trees", "$forkRoute/git/commits", "$forkRoute/git/refs", "$forkRoute/pulls"))) {
        throw 'Publisher write is outside the reviewed fork-only scope.'
    }
    $entry = @{ method = $Method; route = $Route; httpStatus = $null }
    $report.requests += $entry
    Write-Json $resultPath $report
    $parameters = @{ Method = $Method; Uri = "https://api.github.com$Route"; TimeoutSec = 30; MaximumRedirection = 0
        SkipHttpErrorCheck = $true; StatusCodeVariable = 'status'
        Headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'OpenArm-Repair-Publisher' } }
    if ($null -ne $Body) { $parameters.ContentType = 'application/json'; $parameters.Body = $Body | ConvertTo-Json -Depth 12 -Compress }
    $status = 0
    try { $response = Invoke-RestMethod @parameters; $entry.httpStatus = $status }
    catch { throw "GitHub $Method $Route did not complete. Inspect the mutation journal before retrying; no request was automatically retried." }
    finally { Write-Json $resultPath $report }
    if (($AllowMissing -and $status -eq 404) -or ($AllowNotReady -and $status -in @(404, 409))) { return $null }
    if ($status -ne $Expected) { throw "GitHub $Method $Route returned HTTP $status. Inspect result.json before retrying." }
    $response
}

try {
    $task = Read-RepairTask $TaskId
    if ($task.mode -ne 'cmake' -or $task.repository -eq 'self') { throw 'Diagnostic and self-test tasks cannot publish a PR.' }
    if ($env:GITHUB_EVENT_NAME -ne 'workflow_dispatch' -or $env:OPENARM_PUBLISH_DRAFT -ne 'true' -or
        $env:GITHUB_REPOSITORY -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$') { throw 'Publishing requires an explicitly enabled manual workflow run.' }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Configure OPENARM_GITHUB_TOKEN with access only to the reviewed destination fork.' }
    $candidatePath = Join-Path $InputPath 'candidate.json'
    $validationPath = Join-Path $InputPath 'report.json'
    foreach ($path in $candidatePath, $validationPath) {
        if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Publisher input exceeds 1 MiB.' }
    }
    $candidate = Read-Json $candidatePath
    $validation = Read-Json $validationPath
    Assert-RepairBundle $candidate $task $env:GITHUB_RUN_ID $env:GITHUB_SHA
    if (-not $candidate.files.Count -or $validation.phase -ne 'Validate' -or $validation.status -ne 'validated' -or
        $validation.taskId -cne $task.id -or $validation.runId -cne $env:GITHUB_RUN_ID -or
        $validation.workflowCommit -cne $env:GITHUB_SHA -or $validation.sourceCommit -cne $task.commit -or
        $validation.candidateSha256 -cne (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -or
        -not $validation.native.nativeVerified -or $validation.native.route -ne 'validated' -or
        $validation.native.host.osArchitecture -ne 'Arm64' -or $validation.native.host.processArchitecture -ne 'Arm64') {
        throw 'Publishing requires the exact nonempty, independently validated native candidate from this workflow run.'
    }
    $sourceName = $task.repository.Substring('https://github.com/'.Length)
    $sourceRoute = "/repos/$sourceName"
    $source = Invoke-RepairApi GET $sourceRoute
    if ($source.full_name -ine $sourceName) { throw 'Source repository identity does not match the reviewed native task.' }
    $forkRoute = "/repos/$($task.fork)"
    $fork = Invoke-RepairApi GET $forkRoute -AllowMissing
    $base = $null
    if (-not $fork) {
        if ($env:OPENARM_CREATE_FORK -ne 'true') { throw 'The reviewed destination fork does not exist; enable createFork to create it after native validation.' }
        if ([string]::IsNullOrWhiteSpace($source.default_branch)) { throw 'Source default branch is missing.' }
        $sourceRef = Invoke-RepairApi GET "$sourceRoute/git/ref/heads/$([uri]::EscapeDataString($source.default_branch))"
        if ($sourceRef.object.sha -cne $task.commit) {
            throw 'Source default branch moved from the reviewed pin; no fork is created. Review and repin the native task.'
        }
        $actor = Invoke-RepairApi GET '/user'
        if ($actor.login -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$') { throw 'Invalid publishing account identity.' }
        $parts = $task.fork.Split('/')
        $body = @{ name = $parts[1]; default_branch_only = $true }
        if ($parts[0] -ine $actor.login) {
            $owner = Invoke-RepairApi GET "/users/$($parts[0])"
            if ($owner.type -ne 'Organization' -or $owner.login -ine $parts[0]) {
                throw 'The reviewed fork owner must be the publishing account or a reviewed organization.'
            }
            $body.organization = $parts[0]
        }
        $null = Invoke-RepairApi POST "$sourceRoute/forks" $body 202
        $report.forkCreated = $true
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            $fork = Invoke-RepairApi GET $forkRoute -AllowMissing
            if ($fork -and -not [string]::IsNullOrWhiteSpace($fork.default_branch)) {
                $base = Invoke-RepairApi GET "$forkRoute/git/ref/heads/$([uri]::EscapeDataString($fork.default_branch))" -AllowNotReady
                if ($base) { break }
            }
            if ($attempt -lt 11) { Start-Sleep -Seconds 5 }
        }
        if (-not $base) { throw 'Fork creation was accepted but the destination is not ready. Inspect the mutation journal; no creation request was retried.' }
    }
    $networkId = if ($source.fork) { $source.source.id } else { $source.id }
    if ($source.full_name -ine $sourceName -or $fork.full_name -ine $task.fork -or -not $fork.fork -or
        $fork.source.id -ne $networkId -or $fork.archived -or $fork.disabled -or -not $fork.permissions.push -or
        [string]::IsNullOrWhiteSpace($fork.default_branch)) { throw 'Destination must be an active, writable fork in the reviewed source network.' }
    if (-not $base) { $base = Invoke-RepairApi GET "$forkRoute/git/ref/heads/$([uri]::EscapeDataString($fork.default_branch))" }
    if ($base.object.sha -cne $task.commit) { throw 'Fork default branch moved or differs from the pinned repair base. Review and repin; it will not be reset or synced.' }
    $workflows = Invoke-RepairApi GET "$forkRoute/actions/workflows?per_page=100"
    if ($workflows.total_count -ne @($workflows.workflows).Count -or $workflows.total_count -gt 100 -or
        @($workflows.workflows | Where-Object state -notin @('disabled_fork', 'disabled_inactivity', 'disabled_manually', 'deleted')).Count) {
        throw 'Destination must have a complete inventory of at most 100 inactive workflows. No settings will be changed.'
    }
    $report.branch = "openarm-repair-$($env:GITHUB_RUN_ID)"
    if (Invoke-RepairApi GET "$forkRoute/git/ref/heads/$($report.branch)" -AllowMissing) {
        throw 'Repair branch already exists. Inspect the prior run; no overwrite or duplicate PR is allowed.'
    }
    $baseCommit = Invoke-RepairApi GET "$forkRoute/git/commits/$($task.commit)"
    if ($baseCommit.sha -cne $task.commit -or $baseCommit.tree.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid pinned base tree.' }
    $treeEntries = @()
    foreach ($file in $candidate.files) {
        $prefix = if ($task.sourceSubdirectory -eq '.') { '' } else { ($task.sourceSubdirectory.Replace('\', '/').TrimEnd('/') + '/') }
        $path = "$prefix$($file.path)"
        if ($path -cnotmatch '^(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_.-]+$') { throw 'Publication path is outside the supported source scope.' }
        $original = Invoke-RepairApi GET "$forkRoute/contents/$($path)?ref=$($task.commit)"
        if ($original.type -ne 'file' -or $original.encoding -ne 'base64' -or $original.size -gt 65536 -or $original.path -cne $path) {
            throw 'Original publication source must be a bounded regular file.'
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($original.content))
        if ($text.StartsWith([char]0xFEFF)) { $text = $text.Substring(1) }
        if ((Get-RepairHash $text) -cne $file.baseSha256) { throw 'Publication baseline differs from the validated source.' }
        $treeEntries += @{ path = $path; mode = '100644'; type = 'blob'; content = $file.content }
    }
    $tree = Invoke-RepairApi POST "$forkRoute/git/trees" @{ base_tree = $baseCommit.tree.sha; tree = $treeEntries } 201
    if ($tree.sha -cnotmatch '^[a-f0-9]{40}$' -or $tree.sha -eq $baseCommit.tree.sha) { throw 'GitHub did not return a changed source tree.' }
    $message = "Fix reviewed Windows Arm64 compiler blocker ($($task.id)) [skip ci]`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`nCopilot-Session: $($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    $commit = Invoke-RepairApi POST "$forkRoute/git/commits" @{ message = $message; tree = $tree.sha; parents = @($task.commit) } 201
    if ($commit.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'GitHub did not return a valid repair commit.' }
    $report.commit = $commit.sha
    $recheck = Invoke-RepairApi GET "$forkRoute/git/ref/heads/$([uri]::EscapeDataString($fork.default_branch))"
    if ($recheck.object.sha -cne $task.commit) { throw 'Fork base moved while preparing publication. No branch or PR was created.' }
    $null = Invoke-RepairApi POST "$forkRoute/git/refs" @{ ref = "refs/heads/$($report.branch)"; sha = $commit.sha } 201
    $pull = Invoke-RepairApi POST "$forkRoute/pulls" @{
        title = "OpenArm: reviewed Windows Arm64 repair ($($task.id))"
        head = $report.branch; base = $fork.default_branch; draft = $true; maintainer_can_modify = $false
        body = "AI-generated candidate, for human review inside this fork only.`n`nIssue: $($task.issue)`nPinned base: $($task.commit)`nEvidence: https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)`n`nIndependent native Windows Arm64 CMake/CTest/install/PE/launch checks passed for the configured scope, not the entire upstream application. Review the exact diff and evidence; no upstream PR or merge is authorized."
    } 201
    if (-not $pull.draft -or $pull.head.repo.id -ne $fork.id -or $pull.base.repo.id -ne $fork.id -or
        $pull.head.ref -cne $report.branch -or $pull.head.sha -cne $commit.sha -or
        $pull.base.ref -cne $fork.default_branch -or [long]$pull.number -lt 1) { throw 'Returned PR is outside the requested draft/fork/commit scope; inspect the journal.' }
    $report.status = 'draft_created'
    $report.pullRequestUrl = "https://github.com/$($task.fork)/pull/$($pull.number)"
    if ($env:GITHUB_STEP_SUMMARY) { "Draft repair PR: $($report.pullRequestUrl)" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
} catch {
    $report.status = 'failed'; $report.error = $_.Exception.Message
    if ($token) { $report.error = $report.error.Replace($token, '[redacted]') }
    throw $report.error
} finally {
    Write-Json $resultPath $report
}
