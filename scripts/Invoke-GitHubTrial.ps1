[CmdletBinding()]
param(
    [string] $SourceRepositoryUrl = $env:OPENARM_GITHUB_SOURCE,
    [string] $ForkOwner = $env:OPENARM_GITHUB_FORK_OWNER,
    [string] $TrialId = $env:OPENARM_GITHUB_TRIAL_ID,
    [switch] $CreatePullRequest = ($env:OPENARM_GITHUB_TRIAL_CREATE -eq 'true'),
    [string] $Output = (Join-Path $PSScriptRoot "..\out\github-trial-$([guid]::NewGuid())"),
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"

$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Trial output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$resultPath = Join-Path $Output 'result.json'
$token = $env:OPENARM_GITHUB_TOKEN
$api = ''; $sourceRoute = ''; $forkRoute = ''; $filePath = ''
$report = @{
    schemaVersion = 1; status = 'checking'; createPullRequest = [bool]$CreatePullRequest
    purpose = 'Documentation-only GitHub API trial; not a build, agent repair or Arm64 validation'
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); completedAt = $null
    sourceRepository = $null; forkRepository = $null; trialId = $null
    branch = $null; baseBranch = $null; sourceCommit = $null; baseCommit = $null
    commit = $null; pullRequestUrl = $null; error = $null; requests = @()
}

function Invoke-TrialApi {
    param([string] $Method, [string] $Route, $Body = $null,
        [int[]] $Expected = @(200), [int[]] $Missing = @())
    if ($Method -ne 'GET') {
        $allowed = ($Method -eq 'POST' -and $Route -in @("$sourceRoute/forks", "$forkRoute/git/refs", "$forkRoute/pulls")) -or
            ($Method -eq 'PUT' -and $Route -eq "$forkRoute/contents/$filePath")
        if (-not $CreatePullRequest -or -not $allowed) { throw 'GitHub write is outside the confirmed trial scope.' }
    }
    $entry = @{ method = $Method; route = $Route; httpStatus = $null }
    $report.requests += $entry
    # Record intent before a write: a lost response must not invite an automatic retry.
    Write-Json $resultPath $report
    $parameters = @{
        Method = $Method; Uri = "$api$Route"; TimeoutSec = 30; MaximumRedirection = 0
        SkipHttpErrorCheck = $true; StatusCodeVariable = 'status'; ErrorAction = 'Stop'
        Headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'OpenArm-GitHub-Trial' }
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
    }
    $status = 0
    try {
        $response = Invoke-RestMethod @parameters
        $entry.httpStatus = $status
    } catch {
        $entry.error = $_.Exception.Message.Replace($token, '[redacted]')
        throw "GitHub $Method $Route could not complete: $($entry.error). No write was automatically retried."
    } finally {
        Write-Json $resultPath $report
    }
    if ($status -in $Missing) { return $null }
    if ($status -notin $Expected) {
        if ($response -and $response.PSObject.Properties['message']) {
            $entry.error = ([string]$response.message).Replace($token, '[redacted]')
        }
        throw "GitHub request failed (HTTP $status): $Method $Route. Check token access, fork policy and result.json."
    }
    $response
}

function Assert-TrialFork($Fork, [long] $NetworkId, [string] $FullName) {
    if ($Fork.full_name -ine $FullName -or -not $Fork.fork -or $Fork.source.id -ne $NetworkId) {
        throw 'Destination exists but is not a matching fork; it will not be modified.'
    }
}

try {
    $uri = $null
    if (-not [uri]::TryCreate($SourceRepositoryUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Host -notin @('github.com', 'msft.ghe.com') -or
        $uri.AbsolutePath -notmatch '^/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$') {
        throw 'Set SourceRepositoryUrl to https://github.com/OWNER/REPO or https://msft.ghe.com/OWNER/REPO, without credentials or extra URL components.'
    }
    $sourceOwner = $Matches[1]
    $name = $Matches[2] -replace '\.git$', ''
    if (-not $name -or $name -in @('.', '..')) { throw 'Invalid source repository name.' }
    if ($TrialId -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,79}$') { throw 'TrialId must be a unique alphanumeric/hyphen identifier of at most 80 characters.' }
    if ($ForkOwner -and $ForkOwner -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$') { throw 'Invalid fork owner.' }
    if ([string]::IsNullOrWhiteSpace($token) -or $token.StartsWith('$(')) {
        throw 'Set the Actions secret OPENARM_GITHUB_TOKEN (or this environment variable for local runs); never put the token in YAML or a URL.'
    }
    if (@($SourceRepositoryUrl, $ForkOwner, $TrialId | Where-Object { $_ -and $_.Contains($token) }).Count) {
        throw 'The secret token must not appear in repository, owner or trial parameters.'
    }
    $report.trialId = $TrialId
    $web = "https://$($uri.Host)"
    $api = "https://api.$($uri.Host)"
    $sourceName = "$sourceOwner/$name"
    $sourceRoute = "/repos/$sourceName"
    $actor = Invoke-TrialApi GET '/user'
    if ($actor.login -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$') { throw 'GitHub returned an invalid authenticated account.' }
    if (-not $ForkOwner) { $ForkOwner = $actor.login }
    $organization = $ForkOwner -ine $actor.login
    if ($organization) {
        $owner = Invoke-TrialApi GET "/users/$ForkOwner"
        if ($owner.type -ne 'Organization' -or $owner.login -ine $ForkOwner) {
            throw 'ForkOwner must be the authenticated user or an explicitly selected organization.'
        }
    }
    $source = Invoke-TrialApi GET $sourceRoute
    if ($source.full_name -ine $sourceName -or [string]::IsNullOrWhiteSpace($source.default_branch)) {
        throw 'Source identity or default branch does not match the requested repository.'
    }
    $sourceRef = Invoke-TrialApi GET "$sourceRoute/git/ref/heads/$([uri]::EscapeDataString($source.default_branch))"
    if ($sourceRef.object.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Source default branch has no valid commit.' }
    $networkId = if ($source.fork) { $source.source.id } else { $source.id }
    $forkName = "$ForkOwner/$name"
    if ($forkName -ieq $sourceName) { throw 'Source and fork must be different repositories; choose another permitted fork owner or source.' }
    $forkRoute = "/repos/$forkName"
    $report.sourceRepository = "$web/$sourceName"
    $report.forkRepository = "$web/$forkName"
    $report.sourceCommit = $sourceRef.object.sha
    $report.branch = "openarm-trial-$TrialId"
    $filePath = "openarm-trials/$TrialId.md"
    $fork = Invoke-TrialApi GET $forkRoute -Missing @(404)
    if ($fork) { Assert-TrialFork $fork $networkId $forkName }
    if (-not $CreatePullRequest) {
        $report.status = 'checked'
        return
    }
    if (-not $fork) {
        $body = @{ name = $name; default_branch_only = $true }
        if ($organization) { $body.organization = $ForkOwner }
        $null = Invoke-TrialApi POST "$sourceRoute/forks" $body -Expected @(202)
    }
    $baseRef = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not $fork -or $attempt -gt 0) { $fork = Invoke-TrialApi GET $forkRoute -Missing @(404) }
        if ($fork) {
            Assert-TrialFork $fork $networkId $forkName
            $baseRef = Invoke-TrialApi GET "$forkRoute/git/ref/heads/$([uri]::EscapeDataString($fork.default_branch))" -Missing @(404, 409)
            if ($baseRef) { break }
        }
        if ($attempt -lt 29) { Start-Sleep -Seconds 10 }
    }
    if (-not $baseRef) { throw 'Fork git objects are not ready after bounded polling. Check fork access and prior artifacts before another run.' }
    if ($fork.archived -or $fork.disabled -or -not $fork.permissions.push) {
        throw 'Destination fork must be active and grant write access; no permissions will be changed.'
    }
    if ($baseRef.object.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Fork default branch has no valid commit.' }
    $report.baseBranch = $fork.default_branch
    $report.baseCommit = $baseRef.object.sha
    $workflows = Invoke-TrialApi GET "$forkRoute/actions/workflows?per_page=100"
    if ($workflows.total_count -ne @($workflows.workflows).Count -or $workflows.total_count -gt 100) {
        throw 'Cannot establish a complete workflow inventory; this trial supports at most 100 workflows.'
    }
    if (@($workflows.workflows | Where-Object state -eq 'active').Count) {
        throw 'Destination has active GitHub Actions workflows. Use a dedicated fork with workflows disabled before this trial; the pipeline will not change their permissions.'
    }
    if (@($workflows.workflows | Where-Object { $_.state -notin @('disabled_fork', 'disabled_inactivity', 'disabled_manually', 'deleted') }).Count) {
        throw 'Destination workflow inventory contains an unknown state.'
    }
    $existing = Invoke-TrialApi GET "$forkRoute/git/ref/heads/$($report.branch)" -Missing @(404)
    if ($existing) { throw 'Trial branch already exists. Inspect the earlier result; this run will not overwrite it or create a duplicate PR.' }
    $null = Invoke-TrialApi POST "$forkRoute/git/refs" @{ ref = "refs/heads/$($report.branch)"; sha = $report.baseCommit } -Expected @(201)
    $content = @"
# OpenArm pipeline integration trial

This is a documentation-only GitHub API connection test.
It is not a porting patch, agent benchmark, build result, or Arm64 validation.

Source repository: $($report.sourceRepository)
Source commit observed: $($report.sourceCommit)
Fork base commit: $($report.baseCommit)
Trial: $TrialId

No application code or workflow configuration is changed. No upstream PR is requested.
"@
    $commit = Invoke-TrialApi PUT "$forkRoute/contents/$filePath" @{
        message = "Add OpenArm documentation-only trial $TrialId [skip ci]"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        branch = $report.branch
    } -Expected @(201)
    if ($commit.commit.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'GitHub did not return a valid documentation commit.' }
    $report.commit = $commit.commit.sha
    $pull = Invoke-TrialApi POST "$forkRoute/pulls" @{
        title = "OpenArm documentation-only pipeline trial $TrialId"
        head = $report.branch; base = $report.baseBranch; draft = $true
        maintainer_can_modify = $false
        body = "Temporary GitHub API integration test inside this fork only. Adds $filePath; no application/workflow changes, native-validation claim, upstream PR, or automatic merge."
    } -Expected @(201)
    if (-not $pull.draft -or $pull.head.repo.id -ne $fork.id -or $pull.base.repo.id -ne $fork.id -or
        $pull.head.ref -cne $report.branch -or $pull.base.ref -cne $report.baseBranch -or [long]$pull.number -lt 1) {
        throw 'GitHub returned a PR outside the requested draft/fork/branch scope; inspect the recorded request before further action.'
    }
    $report.pullRequestUrl = "$web/$forkName/pull/$($pull.number)"
    $report.status = 'draft_created'
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    if ($token) { $report.error = $report.error.Replace($token, '[redacted]') }
    Set-Content -LiteralPath (Join-Path $Output 'failure.log') -Value $report.error -Encoding utf8
    throw $report.error
} finally {
    $report.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-Json $resultPath $report
    Write-Host "GitHub trial evidence: $Output"
}
