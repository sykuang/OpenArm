Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\repository-discovery-$([guid]::NewGuid())"
$fixture = "$root\fixture"
$null = New-Item -ItemType Directory -Path "$fixture\scripts", "$fixture\targets\discovery"
Copy-Item -LiteralPath "$repo\scripts\Common.ps1", "$repo\scripts\ReleaseEvidence.ps1",
    "$repo\scripts\RepositorySources.ps1", "$repo\scripts\DistributionEvidence.ps1",
    "$repo\scripts\Find-Arm64Candidate.ps1" -Destination "$fixture\scripts"
$savedEnvironment = @{}
foreach ($name in 'OPENARM_GITHUB_DISCOVERY_TOKEN', 'OPENARM_GITHUB_TOKEN', 'OPENARM_GITHUB_TRIAL_CREATE', 'OPENARM_DISCOVERY_TRACK') {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:OPENARM_GITHUB_TOKEN = 'enterprise-test-placeholder'
$env:OPENARM_GITHUB_TRIAL_CREATE = 'False'
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function New-Issue([int] $RepoNumber, [string] $Title, [int] $Number = 1) {
    @{ number = $Number; title = $Title; state = 'open'; body = 'Do not persist raw issue bodies.'
        html_url = "https://github.com/owner/repo$RepoNumber/issues/$Number"
        repository_url = "https://api.github.com/repos/owner/repo$RepoNumber" }
}
function New-Release([array] $Assets = @()) {
    @{ tag_name = 'v1'; published_at = '2026-09-16T00:00:00Z'; draft = $false; prerelease = $false; assets = $Assets }
}
function New-ReleaseAsset([string] $Name, [long] $Size = 256, [int] $RepoNumber = 2) {
    @{ name = $Name; size = $Size; state = 'uploaded'
        browser_download_url = "https://github.com/owner/repo$RepoNumber/releases/download/v1/$([uri]::EscapeDataString($Name))" }
}
function New-LinkedPullRequest([string] $State = 'OPEN', [int] $Number = 42, [string] $Repository = 'owner/repo2') {
    @{ number = $Number; url = "https://github.com/$Repository/pull/$Number"; state = $State
        merged = ($State -ceq 'MERGED'); repository = @{ nameWithOwner = $Repository } }
}
function Reset-Mock {
    $env:OPENARM_GITHUB_DISCOVERY_TOKEN = 'public-test-placeholder'
    $env:OPENARM_DISCOVERY_TRACK = 'both'
    Write-Json "$fixture\targets\discovery\foundational.json" @{
        schemaVersion = 1
        repositories = @(11..20 | ForEach-Object { @{ fullName = "owner/repo$_"; category = 'library'; reason = "Shared native dependency $_" } })
    }
    Write-Json "$fixture\targets\discovery\distribution-channels.json" @{
        schemaVersion = 1
        repositories = @(1..20 | ForEach-Object { @{ fullName = "owner/repo$_"; channels = @(@{ provider = 'github' }) } })
    }
    $global:DiscoveryMock = @{
        calls = [Collections.Generic.List[object]]::new()
        sleeps = [Collections.Generic.List[int]]::new()
        repositories = @(1..20 | ForEach-Object {
            @{ full_name = "owner/repo$_"; stargazers_count = 300000 - $_; language = 'C++'
                default_branch = 'main'; html_url = "https://github.com/owner/repo$_"
                private = $false; archived = $false; fork = $false }
        })
        issues = @{
            'repo1' = @(New-Issue 1 'Windows ARM64 already works: documentation')
            'repo2' = @(New-Issue 2 'Add Windows ARM64 support')
            'repo3' = @(New-Issue 3 'Missing Windows ARM64 binaries')
            'repo11' = @(New-Issue 11 'Provide native Windows ARM64 wheels')
        }
        trendingReads = 0; trendingHtml = $null; trendingError = $false
        releases = @{
            repo2 = (New-Release @(New-ReleaseAsset 'app-win-x64.exe'))
            repo3 = (New-Release @(New-ReleaseAsset 'app-win-x64.exe' -RepoNumber 3))
            repo11 = (New-Release @(New-ReleaseAsset 'app-win-x64.exe' -RepoNumber 11))
        }
        downloads = 0; assetMachine = 0x8664; assetMachines = @{}; assetFailure = $false
        registry = @{}; registryReads = [Collections.Generic.List[string]]::new(); registryError = $false
        issueTotal = @{}; incompleteAt = 0; failAt = 0; failStatus = 403
        throwAt = 0; malformedAt = 0
        linkedPullRequests = @{}; truncatedFixes = @(); graphError = ''; graphQueries = @()
        referencingPullRequests = @{}; referenceTotals = @{}
    }
}
function global:Start-Sleep { param($Seconds) $global:DiscoveryMock.sleeps.Add($Seconds) }
function global:Mock-DiscoveryTrending {
    $m = $global:DiscoveryMock
    $m.trendingReads++
    if ($m.trendingError) { throw 'GitHub Trending returned HTTP 429; no retry.' }
    if ($null -ne $m.trendingHtml) { return $m.trendingHtml }
    (1..12 | ForEach-Object {
        "<article class=`"Box-row`"><h2><a href=`"/owner/repo$_`">Repository</a></h2><span>$(1000 + $_) stars this week</span></article>"
    }) -join "`n"
}
Set-Alias -Name Receive-GitHubTrending -Value Mock-DiscoveryTrending -Scope Global
function global:Mock-DiscoveryBytes {
    param($Uri, $ExpectedSize, $PrefixOnly, $Budget)
    $m = $global:DiscoveryMock
    $m.downloads++
    if ($m.assetFailure) { throw 'Release download failed (HTTP 403).' }
    $bytes = [byte[]]::new(256)
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, 128)
    $repositoryName = ([uri]$Uri).AbsolutePath.Split('/')[2]
    $machine = if ($m.assetMachines.ContainsKey($repositoryName)) { $m.assetMachines[$repositoryName] } else { $m.assetMachine }
    [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes, 132)
    $Budget.remainingBytes -= $bytes.Length
    return ,$bytes
}
Set-Alias -Name Receive-ReleaseBytes -Value Mock-DiscoveryBytes -Scope Global
function global:Mock-DistributionMetadata {
    param($Uri, $Request)
    $m = $global:DiscoveryMock
    $m.registryReads.Add([string]$Uri)
    if ($m.registryError) { throw 'Package metadata request failed (HTTP 403); no retry was attempted.' }
    if (-not $m.registry.ContainsKey([string]$Uri)) { $Request.httpStatus = 404; return $null }
    $Request.httpStatus = 200
    $m.registry[[string]$Uri]
}
Set-Alias -Name Receive-DistributionMetadata -Value Mock-DistributionMetadata -Scope Global
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ContentType, $Body,
        [switch] $SkipHttpErrorCheck, $StatusCodeVariable, $ErrorAction)
    $m = $global:DiscoveryMock
    $url = [uri]$Uri
    $graph = $Method -ceq 'POST' -and $url.AbsolutePath -ceq '/graphql'
    if (($Method -cne 'GET' -and -not $graph) -or $url.Host -ne 'api.github.com' -or $url.Scheme -ne 'https' -or
        $MaximumRedirection -ne 0 -or $TimeoutSec -ne 30) { throw 'Unexpected network boundary.' }
    $authorization = if ($Headers.ContainsKey('Authorization')) { $Headers.Authorization } else { '' }
    $m.calls.Add(@{ route = [uri]::UnescapeDataString($url.PathAndQuery); authorization = $authorization })
    $call = $m.calls.Count
    if ($call -eq $m.throwAt) { throw 'Transport error public-test-placeholder enterprise-test-placeholder' }
    $status = if ($call -eq $m.failAt) { $m.failStatus } else { 200 }
    Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    if ($status -ne 200) { return [pscustomobject]@{ message = 'Secret public-test-placeholder' } }
    if ($call -eq $m.malformedAt) { return [pscustomobject]@{ message = 'Invalid response' } }
    if ($graph) {
        $payload = $Body | ConvertFrom-Json
        if ($ContentType -cne 'application/json' -or $payload.operationName -cne 'OpenArmUpstreamFixes' -or
            -not $payload.query.StartsWith('query OpenArmUpstreamFixes {') -or $payload.query -match '\bmutation\b') {
            throw 'Unexpected GraphQL operation.'
        }
        $m.graphQueries += $payload.query
        $data = @{}
        $targets = [regex]::Matches($payload.query, 'c(\d+): repository\(owner: "owner", name: "(repo\d+)"\) \{ issue\(number: (\d+)\)')
        if ($targets.Count -lt 1 -or $targets.Count -gt 100) { throw 'Unexpected GraphQL issue bound.' }
        foreach ($target in $targets) {
            $alias = 'c' + $target.Groups[1].Value
            $name = $target.Groups[2].Value
            $number = [int]$target.Groups[3].Value
            $key = "$name/$number"
            $nodes = @(if ($m.linkedPullRequests.ContainsKey($key)) { $m.linkedPullRequests[$key] })
            $data[$alias] = @{ issue = @{
                number = $number; url = "https://github.com/owner/$name/issues/$number"
                closedByPullRequestsReferences = @{ nodes = $nodes; pageInfo = @{ hasNextPage = ($key -in $m.truncatedFixes) } }
            } }
            $referenceNodes = @(if ($m.referencingPullRequests.ContainsKey($key)) { $m.referencingPullRequests[$key] })
            $referenceTotal = if ($m.referenceTotals.ContainsKey($key)) { $m.referenceTotals[$key] } else { $referenceNodes.Count }
            $data['s' + $target.Groups[1].Value] = @{
                issueCount = $referenceTotal; nodes = $referenceNodes; pageInfo = @{ hasNextPage = ($referenceTotal -gt 5) }
            }
            if (-not $payload.query.Contains("search(query: `"repo:owner/$name is:pr $number in:body sort:updated-desc`", type: ISSUE, first: 5)")) {
                throw 'The bounded PR reference query is missing.'
            }
        }
        $response = @{ data = $data }
        switch ($m.graphError) {
            'errors' { $response.errors = @(@{ message = 'Secret public-test-placeholder' }) }
            'partial' { $data.Remove('c1') }
            'null-issue' { $data.c0.issue = $null }
            'wrong-issue' { $data.c0.issue.number = 99 }
            'wrong-url' { $data.c0.issue.url = 'https://evil.invalid/issue' }
            'null-nodes' { $data.c0.issue.closedByPullRequestsReferences.nodes = $null }
            'bad-page' { $data.c0.issue.closedByPullRequestsReferences.pageInfo.hasNextPage = 'false' }
            'missing-search' { $data.Remove('s0') }
            'bad-search-total' { $data.s0.issueCount = -1 }
            'short-search' { $data.s0.issueCount = 1 }
        }
        return $response | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    }
    if ($url.AbsolutePath -match '^/repos/owner/(repo\d+)/releases/latest$') {
        if ($m.releases.ContainsKey($Matches[1])) {
            return $m.releases[$Matches[1]] | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        }
        Set-Variable -Name $StatusCodeVariable -Value 404 -Scope 1
        return [pscustomobject]@{ message = 'Not Found' }
    }
    if ($url.AbsolutePath -match '^/repos/owner/repo(\d+)$') {
        return $m.repositories[[int]$Matches[1] - 1] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    } elseif ($m.calls[-1].route -match '^/search/issues\?q=repo:owner/(repo\d+) is:issue is:open Windows ARM64 in:title,body&sort=updated&order=desc&per_page=5&page=1$') {
        $name = $Matches[1]
        $items = if ($m.issues.ContainsKey($name)) { @($m.issues[$name]) } else { @() }
        $total = if ($m.issueTotal.ContainsKey($name)) { $m.issueTotal[$name] } else { @($items).Count }
    } else { throw 'Unexpected query.' }
    @{ total_count = $total; incomplete_results = ($call -eq $m.incompleteAt); items = @($items) } |
        ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function Run-Discovery([string] $Name, [hashtable] $Arguments = @{}) {
    $output = Join-Path $root $Name
    $errorText = ''
    try { & "$fixture\scripts\Find-Arm64Candidate.ps1" -Output $output -OutputRoot $root @Arguments }
    catch { $errorText = $_.Exception.Message }
    $path = Join-Path $output 'discovery.json'
    @{ error = $errorText; output = $output
        report = $(if (Test-Path -LiteralPath $path) { Read-Json $path } else { $null }) }
}
try {
    Reset-Mock
    $run = Run-Discovery 'ranked'
    Assert (-not $run.error) "Public discovery command succeeds: $($run.error)"
    $r = $run.report
    Assert ($r.status -eq 'completed' -and $r.repositories.Count -eq 20 -and $r.assessedCount -eq 20) 'Exactly twenty repositories are assessed'
    Assert ($global:DiscoveryMock.calls.Count -eq 61 -and $global:DiscoveryMock.trendingReads -eq 1 -and
        $global:DiscoveryMock.graphQueries.Count -eq 1) 'One weekly page, sixty REST reads and one batched upstream fix query, with no repository star search'
    Assert ($r.upstreamFixReview.status -eq 'completed' -and $r.upstreamFixReview.assessedCount -eq 3 -and
        $r.repositories[1].issues[0].upstreamFixReview.status -eq 'no_active_linked_fix') 'Only title-eligible issues receive the linked-fix review'
    Assert ($r.releaseAssessedCount -eq 20 -and $r.repositories[0].release.status -eq 'no_published_release') 'A missing stable release stays unknown, not proof of absent Arm64 support'
    Assert ($global:DiscoveryMock.calls[0].route -eq '/repos/owner/repo1' -and $r.sources.Count -eq 2) 'Repository identity comes from the two reviewed sources, not an all-time-star search'
    Assert (($r.repositories.fullName -join ',') -eq ((1..20 | ForEach-Object { "owner/repo$_" }) -join ',')) 'Displayed Trending order and curated Foundational order are preserved independently'
    Assert ($r.repositories[0].assessment -eq 'needs_review' -and $r.repositories[3].assessment -eq 'no_matching_open_issue') 'Incidental mentions and no matches do not imply lack of support'
    Assert ($r.repositories[1].assessment -eq 'reported_missing_native_support' -and $r.repositories[2].assessment -eq 'reported_missing_native_support') 'Only explicit missing-support requests are eligible'
    Assert ($r.schemaVersion -eq 4 -and $r.selectionMode -eq 'missing_native_support_only' -and
        $r.distributionAssessedCount -eq 20 -and $r.repositories[1].nativeSupport.status -eq 'missing_in_reviewed_channels') 'Missing-only selection requires completed reviewed distribution evidence'
    Assert ($r.recommendations.Count -eq 2 -and $r.recommendations[0].fullName -eq 'owner/repo2' -and
        $r.recommendations[1].fullName -eq 'owner/repo11') 'One issue-backed candidate per track is selected'
    Assert ($r.nativeVerified -eq $false -and @($r.recommendations | Where-Object { -not $_.provisional }).Count -eq 0) 'Recommendations are explicitly provisional, never native proof'
    Assert ($r.repositories[0].weeklyStars -eq 1001 -and $r.repositories[10].sourceRanks.foundational -eq 1 -and
        $null -eq $r.repositories[10].weeklyStars) 'Weekly observations and curated priorities are not mixed or fabricated'
    Assert ($r.authMode -eq 'token' -and @($global:DiscoveryMock.calls | Where-Object authorization -ne 'Bearer public-test-placeholder').Count -eq 0) 'Only the separate public discovery token is used'
    Assert ($global:DiscoveryMock.sleeps.Count -eq 20 -and @($global:DiscoveryMock.sleeps | Where-Object { $_ -ne 3 }).Count -eq 0) 'Authenticated searches are paced below thirty per minute'
    $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
    Assert ($markdown -like '*owner/repo20*' -and $markdown -like '*Add Windows ARM64 support*' -and $markdown -like '*provisional*') 'Readable report includes the full ranking and evidence'
    Assert ($r.startedAt -and $r.completedAt -and $r.sources[0].snapshotSha256 -match '^[a-f0-9]{64}$' -and
        $r.sources[1].catalogSha256 -match '^[a-f0-9]{64}$' -and $r.limitations.Count -gt 0) 'Source provenance, timestamps and limitations are durable'

    Reset-Mock
    $global:DiscoveryMock.repositories[0].stargazers_count = 0
    $global:DiscoveryMock.repositories[1].stargazers_count = 9999999
    $global:DiscoveryMock.repositories[10].stargazers_count = 5
    $run = Run-Discovery 'no-star-threshold'
    Assert (-not $run.error -and $run.report.recommendations[1].fullName -eq 'owner/repo11') 'Low-star foundational dependencies remain eligible and lifetime stars do not rerank either track'

    foreach ($track in 'trending', 'foundational') {
        Reset-Mock
        $env:OPENARM_DISCOVERY_TRACK = $track
        $run = Run-Discovery "track-$track"
        Assert (-not $run.error -and $run.report.requestedCount -eq 10 -and $run.report.recommendations.Count -eq 1 -and
            $run.report.recommendations[0].track -eq $track -and $global:DiscoveryMock.calls.Count -eq 31) 'Either track can run independently using the real workflow environment input'
        Assert ($global:DiscoveryMock.trendingReads -eq $(if ($track -eq 'trending') { 1 } else { 0 })) 'Foundational-only mode does not fetch Trending'
    }
    Reset-Mock
    $catalog = Read-Json "$fixture\targets\discovery\foundational.json"
    $catalog.repositories[0].fullName = 'owner/repo2'
    Write-Json "$fixture\targets\discovery\foundational.json" $catalog
    $run = Run-Discovery 'shared-candidate'
    Assert (-not $run.error -and $run.report.requestedCount -eq 19 -and $global:DiscoveryMock.calls.Count -eq 58 -and
        $run.report.repositories[1].tracks.Count -eq 2 -and $run.report.recommendations.Count -eq 2 -and
        ($run.report.recommendations.fullName -join ',') -eq 'owner/repo2,owner/repo2') 'A shared candidate retains both ranks but is assessed only once'
    Assert ($run.report.upstreamFixReview.requestedCount -eq 2) 'Shared repositories do not duplicate linked-fix reads'

    foreach ($state in 'OPEN', 'MERGED', 'CLOSED') {
        Reset-Mock
        $global:DiscoveryMock.linkedPullRequests['repo2/1'] = @(New-LinkedPullRequest $state)
        $run = Run-Discovery "linked-$state"
        $expected = if ($state -eq 'CLOSED') { 'owner/repo2' } else { 'owner/repo3' }
        Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq $expected) "Skip open/merged fixes, not abandoned closed-unmerged work: $state ($($run.error))"
        $evidence = $run.report.repositories[1].issues[0].upstreamFixReview
        Assert ($evidence.pullRequests.Count -eq 1 -and $evidence.pullRequests[0].state -ceq $state -and
            $evidence.pullRequests[0].url -eq 'https://github.com/owner/repo2/pull/42') 'Linked PR identity and state remain inspectable'
        $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
        Assert ($markdown.Contains('https://github.com/owner/repo2/pull/42') -and
            $markdown.Contains($evidence.status)) 'Readable report explains upstream fix exclusions with links'
    }
    Reset-Mock
    $global:DiscoveryMock.issues['repo2'] += New-Issue 2 'Provide native Windows ARM64 packages' 2
    $global:DiscoveryMock.linkedPullRequests['repo2/1'] = @(New-LinkedPullRequest)
    $run = Run-Discovery 'other-issue'
    Assert (-not $run.error -and $run.report.recommendations[0].issueUrl -eq 'https://github.com/owner/repo2/issues/2') 'An unrelated unclaimed issue in the same repository remains eligible'
    Reset-Mock
    $global:DiscoveryMock.linkedPullRequests['repo2/1'] = @(New-LinkedPullRequest -Repository 'dependency/native-library')
    $run = Run-Discovery 'dependency-fix'
    Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq 'owner/repo3' -and
        $run.report.repositories[1].issues[0].upstreamFixReview.pullRequests[0].repository -eq 'dependency/native-library') 'A linked fix in the owning dependency also prevents duplicate work'
    foreach ($active in $false, $true) {
        Reset-Mock
        $global:DiscoveryMock.truncatedFixes = @('repo2/1')
        $global:DiscoveryMock.linkedPullRequests['repo2/1'] = @(1..10 | ForEach-Object { New-LinkedPullRequest 'CLOSED' $_ })
        if ($active) { $global:DiscoveryMock.linkedPullRequests['repo2/1'][0] = New-LinkedPullRequest 'OPEN' 1 }
        $run = Run-Discovery "truncated-fixes-$active"
        $expected = if ($active) { 'existing_upstream_fix' } else { 'unverified_truncated' }
        Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq 'owner/repo3' -and
            $run.report.repositories[1].issues[0].upstreamFixReview.status -eq $expected -and
            $global:DiscoveryMock.calls.Count -eq 61) 'Truncated connections never establish absence of active fixes and do not trigger pagination'
    }
    Reset-Mock
    foreach ($name in 'repo2', 'repo3', 'repo11') {
        $global:DiscoveryMock.linkedPullRequests["$name/1"] = @(New-LinkedPullRequest -Repository "owner/$name")
    }
    $run = Run-Discovery 'all-fixed'
    Assert (-not $run.error -and $run.report.recommendations.Count -eq 0) 'No recommendation is better than duplicating known upstream work'
    foreach ($state in 'OPEN', 'MERGED', 'CLOSED') {
        Reset-Mock
        $global:DiscoveryMock.referencingPullRequests['repo2/1'] = @(New-LinkedPullRequest $state)
        $run = Run-Discovery "referenced-$state"
        $expected = if ($state -eq 'CLOSED') { 'owner/repo2' } else { 'owner/repo3' }
        Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq $expected) "Referenced PR work is reviewed even without closing keywords: $state"
        Assert ($run.report.repositories[1].issues[0].upstreamFixReview.pullRequests[0].sources[0] -eq 'body_reference' -and
            $run.report.repositories[1].issues[0].upstreamFixReview.referenceMatchCount -eq 1) 'Reference-search provenance is distinct from a linked closing fix'
    }
    Reset-Mock
    $global:DiscoveryMock.linkedPullRequests['repo2/1'] = @(New-LinkedPullRequest)
    $global:DiscoveryMock.referencingPullRequests['repo2/1'] = @(New-LinkedPullRequest)
    $run = Run-Discovery 'overlapping-pr-evidence'
    $evidence = $run.report.repositories[1].issues[0].upstreamFixReview
    Assert (-not $run.error -and $evidence.pullRequests.Count -eq 1 -and
        $evidence.pullRequests[0].sources.Count -eq 2 -and $evidence.status -eq 'existing_upstream_fix') 'The same PR is joined once with both evidence sources'
    Reset-Mock
    $global:DiscoveryMock.referencingPullRequests['repo2/1'] = @(1..5 | ForEach-Object { New-LinkedPullRequest 'CLOSED' $_ })
    $global:DiscoveryMock.referenceTotals['repo2/1'] = 8
    $run = Run-Discovery 'truncated-reference-search'
    Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq 'owner/repo3' -and
        $run.report.repositories[1].issues[0].upstreamFixReview.status -eq 'unverified_truncated' -and
        $global:DiscoveryMock.calls.Count -eq 61) 'More than five PR references cannot prove absence of active work and do not widen the scan'
    foreach ($case in 'errors', 'partial', 'null-issue', 'wrong-issue', 'wrong-url', 'null-nodes', 'bad-page',
        'http', 'transport', 'malformed', 'bad-pr-url', 'bad-pr-repo', 'bad-state', 'inconsistent-merge', 'duplicate', 'too-many', 'short-page',
        'missing-search', 'bad-search-total', 'short-search', 'foreign-search-repo') {
        Reset-Mock
        $global:DiscoveryMock.graphError = $case
        $pullRequest = New-LinkedPullRequest
        switch ($case) {
            'http' { $global:DiscoveryMock.failAt = 61 }
            'transport' { $global:DiscoveryMock.throwAt = 61 }
            'malformed' { $global:DiscoveryMock.malformedAt = 61 }
            'bad-pr-url' { $pullRequest.url = 'https://evil.invalid/fix' }
            'bad-pr-repo' { $pullRequest.repository.nameWithOwner = 'owner/../../bad' }
            'bad-state' { $pullRequest.state = 'UNKNOWN' }
            'inconsistent-merge' { $pullRequest.merged = $true }
            'short-page' { $global:DiscoveryMock.truncatedFixes = @('repo2/1') }
            'foreign-search-repo' { $global:DiscoveryMock.referencingPullRequests['repo2/1'] = @(New-LinkedPullRequest -Repository 'other/project') }
        }
        $global:DiscoveryMock.linkedPullRequests['repo2/1'] = switch ($case) {
            'duplicate' { @($pullRequest, $pullRequest) }
            'too-many' { @(1..11 | ForEach-Object { New-LinkedPullRequest 'CLOSED' $_ }) }
            default { @($pullRequest) }
        }
        $run = Run-Discovery "invalid-fix-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.upstreamFixReview.status -eq 'error' -and
            $run.report.recommendations.Count -eq 0 -and $run.report.releaseAssessedCount -eq 20 -and
            $global:DiscoveryMock.calls.Count -eq 61) "Invalid linked-fix response fails visibly without retry or premature recommendations: $case"
    }
    Reset-Mock
    $global:DiscoveryMock.issues = @{}
    foreach ($n in 1..20) {
        $global:DiscoveryMock.issues["repo$n"] = @(1..5 | ForEach-Object { New-Issue $n "Add Windows ARM64 support $_" $_ })
        $global:DiscoveryMock.releases["repo$n"] = New-Release @(New-ReleaseAsset 'app-win-x64.exe' -RepoNumber $n)
    }
    $run = Run-Discovery 'max-linked-issues'
    Assert (-not $run.error -and $run.report.upstreamFixReview.assessedCount -eq 100 -and
        $global:DiscoveryMock.graphQueries.Count -eq 1 -and $global:DiscoveryMock.calls.Count -eq 61) 'All hundred eligible issue identities are joined in one bounded query'

    foreach ($case in 'empty', 'duplicate', 'bad-path', 'missing-weekly', 'oversized', 'http') {
        Reset-Mock
        $html = Mock-DiscoveryTrending
        $global:DiscoveryMock.trendingReads = 0
        $global:DiscoveryMock.trendingHtml = switch ($case) {
            'empty' { '<html>Unexpected page</html>' }
            'duplicate' { $html.Replace('/owner/repo2"', '/owner/repo1"') }
            'bad-path' { $html.Replace('/owner/repo1"', '/owner/../../bad"') }
            'missing-weekly' { $html.Replace('1001 stars this week', '1001 stars today') }
            'oversized' { 'x' * (2MB + 1) }
            default { $html }
        }
        if ($case -eq 'http') { $global:DiscoveryMock.trendingError = $true }
        $run = Run-Discovery "trending-error-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.recommendations.Count -eq 0 -and
            $run.report.sources[0].status -eq 'error' -and $global:DiscoveryMock.calls.Count -eq 0 -and
            $global:DiscoveryMock.trendingReads -eq 1) "Trending $case fails visibly without a lifetime-star fallback"
    }
    foreach ($case in 'empty', 'too-many', 'duplicate', 'bad-path', 'missing-reason') {
        Reset-Mock
        $catalog = Read-Json "$fixture\targets\discovery\foundational.json"
        switch ($case) {
            'empty' { $catalog.repositories = @() }
            'too-many' { $catalog.repositories += $catalog.repositories[0] }
            'duplicate' { $catalog.repositories[1] = $catalog.repositories[0] }
            'bad-path' { $catalog.repositories[0].fullName = 'owner/../../bad' }
            'missing-reason' { $catalog.repositories[0].reason = '' }
        }
        Write-Json "$fixture\targets\discovery\foundational.json" $catalog
        $run = Run-Discovery "catalog-error-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.sources[1].status -eq 'error' -and
            $global:DiscoveryMock.calls.Count -eq 0) "Invalid foundational catalog $case cannot drive API access"
    }
    foreach ($case in 'duplicate', 'bad-path', 'empty-channels', 'unreviewed-provider', 'bad-pypi', 'bad-npm') {
        Reset-Mock
        $catalog = Read-Json "$fixture\targets\discovery\distribution-channels.json"
        switch ($case) {
            'duplicate' { $catalog.repositories += $catalog.repositories[0] }
            'bad-path' { $catalog.repositories[0].fullName = 'owner/../../other' }
            'empty-channels' { $catalog.repositories[0].channels = @() }
            'unreviewed-provider' { $catalog.repositories[0].channels = @(@{ provider = 'untrusted' }) }
            'bad-pypi' { $catalog.repositories[0].channels = @(@{ provider = 'pypi'; package = '../numpy' }) }
            'bad-npm' { $catalog.repositories[0].channels = @(@{ provider = 'npm'; package = 'https://evil.invalid' }) }
        }
        Write-Json "$fixture\targets\discovery\distribution-channels.json" $catalog
        $run = Run-Discovery "invalid-channel-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and
            $global:DiscoveryMock.calls.Count -eq 0 -and $global:DiscoveryMock.registryReads.Count -eq 0) "Invalid channel review cannot authorize network access or recommendations: $case"
    }
    Reset-Mock
    $run = Run-Discovery 'invalid-track' @{ Track = 'unreviewed' }
    Assert ($run.error -and $global:DiscoveryMock.calls.Count -eq 0 -and $global:DiscoveryMock.trendingReads -eq 0) 'Unreviewed discovery tracks fail before network access'

    foreach ($case in 'arm64', 'x64', 'mislabeled', 'empty', 'msi', 'no-assets') {
        Reset-Mock
        $name = switch ($case) {
            'x64' { 'app-win-x64.exe' }; 'msi' { 'app-win-arm64.msi' }; default { 'app-win-arm64.exe' }
        }
        $size = if ($case -eq 'empty') { 0 } else { 256 }
        $assets = @(if ($case -ne 'no-assets') { New-ReleaseAsset $name $size })
        $global:DiscoveryMock.releases['repo2'] = New-Release $assets
        if ($case -eq 'arm64') { $global:DiscoveryMock.assetMachines['repo2'] = 0xAA64 }
        $run = Run-Discovery "release-$case"
        $expected = if ($case -eq 'x64') { 'owner/repo2' } else { 'owner/repo3' }
        Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq $expected -and
            $run.report.recommendations[0].workKind -eq 'investigate_missing_native_support') "Existing native advertisements, artifact bugs and unknown releases cannot be selected as missing: $case ($($run.error))"
        $release = $run.report.repositories[1].release
        Assert ($release.tag -eq 'v1' -and ([DateTimeOffset]$release.publishedAt).ToUniversalTime().ToString('o') -like '2026-09-16T00:00:00*' -and
            $release.url -eq 'https://github.com/owner/repo2/releases/tag/v1') 'Latest-release provenance is durable'
        if ($case -eq 'arm64') {
            Assert ($release.windowsArm64 -eq 'pe_header_found' -and $release.assets[0].binaries[0].machine -eq '0xAA64' -and
                $global:DiscoveryMock.downloads -eq 3) 'Public discovery inspects actual binary headers'
            $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
            Assert ($markdown -like '*Release binary evidence*' -and $markdown -like '*0xAA64*' -and $markdown -like '*app-win-arm64.exe*') 'Markdown exposes release and binary evidence, not just JSON'
        }
    }
    foreach ($case in 'http', 'malformed', 'draft', 'prerelease', 'date', 'asset-url', 'download') {
        Reset-Mock
        $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app.exe')
        switch ($case) {
            'http' { $global:DiscoveryMock.failAt = 42 }
            'malformed' { $global:DiscoveryMock.malformedAt = 42 }
            'draft' { $global:DiscoveryMock.releases['repo2'].draft = $true }
            'prerelease' { $global:DiscoveryMock.releases['repo2'].prerelease = $true }
            'date' { $global:DiscoveryMock.releases['repo2'].published_at = 'not a date' }
            'asset-url' { $global:DiscoveryMock.releases['repo2'].assets[0].browser_download_url = 'https://evil.invalid/app.exe' }
            'download' { $global:DiscoveryMock.assetFailure = $true }
        }
        $run = Run-Discovery "release-error-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.recommendations.Count -eq 0 -and
            $run.report.assessedCount -eq 20 -and $run.report.releaseAssessedCount -eq 1 -and
            $global:DiscoveryMock.calls.Count -eq 42) "Release failure retains issue progress but prevents premature recommendations: $case"
        Assert ($run.report.repositories[1].assessment -eq 'reported_missing_native_support' -and
            $run.report.repositories[1].release.status -eq 'error') 'Release errors do not erase completed issue assessments'
        if ($case -eq 'download') {
            Assert ($run.report.repositories[1].release.assets[0].inspection -eq 'download_error' -and
                $run.report.repositories[1].release.assets[0].error -like '*HTTP 403*') 'Download failure retains the exact asset and sanitized error'
        }
    }
    Reset-Mock
    $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app-win-arm64-[click](evil).msi')
    $run = Run-Discovery 'release-markdown'
    $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
    Assert (-not $run.error -and -not $markdown.Contains('[click](evil)') -and $markdown.Contains('%28evil%29')) 'Release filenames and URLs cannot inject Markdown links'

    Reset-Mock
    $global:DiscoveryMock.issues = @{}
    $run = Run-Discovery 'none'
    Assert (-not $run.error -and $run.report.status -eq 'completed' -and $run.report.recommendations.Count -eq 0) 'Complete scan can honestly recommend no candidate'
    Assert ($run.report.upstreamFixReview.status -eq 'no_eligible_issues' -and $global:DiscoveryMock.calls.Count -eq 60) 'No eligible issues require no GraphQL request'
    Assert ((Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw) -like '*No evidence-backed candidate*') 'No candidate is explicit in the readable report'

    foreach ($token in '', '$(OpenArm.GitHubDiscoveryToken)') {
        Reset-Mock
        $env:OPENARM_GITHUB_DISCOVERY_TOKEN = $token
        $run = Run-Discovery "anonymous-$([guid]::NewGuid())"
        Assert (-not $run.error -and $run.report.authMode -eq 'anonymous') "Missing or unexpanded optional token uses explicit anonymous mode: $($run.error)"
        Assert ($run.report.recommendations.Count -eq 0 -and $run.report.upstreamFixReview.status -eq 'unverified_no_auth' -and
            $run.report.repositories[1].issues[0].upstreamFixReview.status -eq 'unverified_no_auth' -and
            $global:DiscoveryMock.calls.Count -eq 60) 'Anonymous reads retain evidence but cannot assert that upstream fixes are absent'
        Assert (@($global:DiscoveryMock.calls | Where-Object authorization -ne '').Count -eq 0) 'Anonymous mode never falls back to the enterprise token'
        Assert ($global:DiscoveryMock.sleeps.Count -eq 20 -and @($global:DiscoveryMock.sleeps | Where-Object { $_ -ne 7 }).Count -eq 0) 'Anonymous searches are paced below ten per minute'
    }

    foreach ($title in 'Question about Windows ARM64 support', 'How does Windows ARM64 support work?',
        'Windows ARM64 documentation update', 'Windows ARM64 works on my machine', 'Add Linux ARM64 support',
        'ARM64 fails to build on macOS', 'Windows ARM64 support is already implemented',
        'Add Windows ARM64 x64 fallback', 'Fix Windows ARM64 emulation') {
        Reset-Mock
        $global:DiscoveryMock.issues = @{ 'repo1' = @(New-Issue 1 $title) }
        $run = Run-Discovery "mention-$([guid]::NewGuid())"
        Assert (-not $run.error -and $run.report.recommendations.Count -eq 0 -and
            $run.report.repositories[0].assessment -eq 'needs_review') "Not absence proof: $title"
    }

    foreach ($title in 'Build fails on Windows ARM64', 'BUG: linalg.inv crashing on windows arm64',
        'BUG: Windows-ARM64 tests failing in linalg.cond', 'Windows ARM64 Release crash',
        'Fix Windows ARM64 build errors', 'Windows ARM64 performance regression') {
        Reset-Mock
        $global:DiscoveryMock.issues = @{ repo2 = @(New-Issue 2 $title) }
        $run = Run-Discovery "existing-bug-$([guid]::NewGuid())"
        Assert (-not $run.error -and $run.report.recommendations.Count -eq 0 -and
            $run.report.repositories[1].assessment -eq 'existing_support_bug' -and
            $global:DiscoveryMock.graphQueries.Count -eq 0) "A native-support bug is not a missing-support candidate: $title"
    }
    Reset-Mock
    $titles = @('Missing Windows ARM64 binary', 'No Windows ARM64 wheel available',
        'Windows ARM64 is not supported', 'Windows ARM64 installer unavailable', 'Port to Windows on Arm')
    $global:DiscoveryMock.issues['repo2'] = @(for ($i = 0; $i -lt $titles.Count; $i++) { New-Issue 2 $titles[$i] ($i + 1) })
    $run = Run-Discovery 'explicit-missing-wording'
    Assert (-not $run.error -and $run.report.recommendations[0].fullName -eq 'owner/repo2' -and
        @($run.report.repositories[1].issues | Where-Object classification -ne 'reported_missing_native_support').Count -eq 0) 'Explicit missing support, singular binary/wheel/installer and port requests remain eligible with complete channel evidence'
    foreach ($case in 'unreviewed', 'no-release', 'uninspected', 'unlabeled', 'uninspected-shadow', 'no-windows-assets') {
        Reset-Mock
        $global:DiscoveryMock.issues = @{ repo2 = @(New-Issue 2 'Add Windows ARM64 support') }
        switch ($case) {
            'unreviewed' {
                $catalog = Read-Json "$fixture\targets\discovery\distribution-channels.json"
                $catalog.repositories = @($catalog.repositories | Where-Object fullName -ne 'owner/repo2')
                Write-Json "$fixture\targets\discovery\distribution-channels.json" $catalog
            }
            'no-release' { $global:DiscoveryMock.releases.Remove('repo2') }
            'uninspected' { $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app-win-x64.msi') }
            'unlabeled' { $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app.exe') }
            'uninspected-shadow' { $global:DiscoveryMock.releases['repo2'] = New-Release @((New-ReleaseAsset 'app-win-x64.exe'), (New-ReleaseAsset 'shadow-win-x64.msi')) }
            'no-windows-assets' { $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app-linux-x64.tar.gz') }
        }
        $run = Run-Discovery "unknown-support-$case"
        Assert (-not $run.error -and $run.report.recommendations.Count -eq 0 -and
            $run.report.repositories[1].nativeSupport.status -eq 'unverified') "Unknown support cannot be converted into missing support: $case"
    }
    foreach ($case in 'arm64', 'portable', 'x64', 'not-found', 'http', 'wrong-package') {
        Reset-Mock
        $catalog = Read-Json "$fixture\targets\discovery\distribution-channels.json"
        $catalog.repositories[1].channels = @(@{ provider = 'pypi'; package = 'numpy' })
        Write-Json "$fixture\targets\discovery\distribution-channels.json" $catalog
        $global:DiscoveryMock.releases.Remove('repo2')
        $global:DiscoveryMock.issues = @{ repo2 = @(New-Issue 2 'Add Windows ARM64 support') }
        $filename = switch ($case) {
            'portable' { 'numpy-2.5.3-py3-none-any.whl' }
            'x64' { 'numpy-2.5.3-cp312-cp312-win_amd64.whl' }
            default { 'numpy-2.5.3-cp312-cp312-win_arm64.whl' }
        }
        if ($case -ne 'not-found') {
            $global:DiscoveryMock.registry['https://pypi.org/pypi/numpy/json'] = @{
                info = @{ name = $(if ($case -eq 'wrong-package') { 'other' } else { 'numpy' }); version = '2.5.3' }
                urls = @(@{ filename = $filename; packagetype = 'bdist_wheel'; yanked = $false; size = 100 })
            }
        }
        if ($case -eq 'http') { $global:DiscoveryMock.registryError = $true }
        $run = Run-Discovery "pypi-support-$case"
        if ($case -in 'http', 'wrong-package') {
            Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.recommendations.Count -eq 0) 'Registry failures do not authorize missing-support recommendations'
        } else {
            Assert (-not $run.error -and $run.report.recommendations.Count -eq $(if ($case -eq 'x64') { 1 } else { 0 })) "Official PyPI distributions override stale GitHub requests and missing GitHub assets: $case ($($run.error))"
            if ($case -eq 'arm64') {
                Assert ($run.report.repositories[1].nativeSupport.status -eq 'native_distribution_available' -and
                    $run.report.repositories[1].nativeSupport.channels[1].examples[0] -eq $filename) 'NumPy win_arm64 wheels are explicit exclusion evidence, not a new porting opportunity'
            }
        }
        Assert ($global:DiscoveryMock.registryReads.Count -eq 1) 'The official registry read is bounded and never retried'
    }

    Reset-Mock
    $global:DiscoveryMock.issues['repo2'] = @(1..5 | ForEach-Object { New-Issue 2 "Windows ARM64 mention $_" $_ })
    $global:DiscoveryMock.issueTotal['repo2'] = 12
    $run = Run-Discovery 'bounded-issues'
    Assert (-not $run.error -and $run.report.repositories[1].matchingIssueCount -eq 12 -and
        $run.report.repositories[1].issues.Count -eq 5 -and $run.report.repositories[1].evidenceTruncated) 'Only five recent issue titles are inspected and truncation stays visible'
    Assert ($global:DiscoveryMock.calls.Count -eq 61 -and $run.report.recommendations[0].fullName -eq 'owner/repo3') 'Truncation does not widen the scan or manufacture evidence'

    foreach ($field in 'incompleteAt', 'malformedAt', 'throwAt') {
        $points = if ($field -eq 'incompleteAt') { @(21, 24) } else { @(1, 24) }
        foreach ($at in $points) {
            Reset-Mock
            $global:DiscoveryMock[$field] = $at
            $run = Run-Discovery "$field-$at"
            Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.recommendations.Count -eq 0) "$field at request $at cannot become a successful scan"
            Assert ($global:DiscoveryMock.calls.Count -eq $at -and $run.report.assessedCount -eq $(if ($at -le 20) { 0 } else { $at - 21 })) 'Failure is bounded and preserves assessed progress without premature recommendations'
            Assert (Test-Path -LiteralPath (Join-Path $run.output 'discovery.md')) 'Failure retains a readable report'
        }
    }
    foreach ($status in 301, 401, 403, 422, 429, 503) {
        Reset-Mock
        $global:DiscoveryMock.failAt = 24; $global:DiscoveryMock.failStatus = $status
        $run = Run-Discovery "http-$status"
        Assert ($run.error -like "*HTTP $status*" -and $run.report.status -eq 'failed' -and
            $global:DiscoveryMock.calls.Count -eq 24 -and $run.report.assessedCount -eq 3) "HTTP $status stops explicitly without widening or an authentication fallback"
    }

    foreach ($case in 'duplicate', 'private', 'archived', 'fork', 'name', 'negative-stars', 'bad-stars', 'branch') {
        Reset-Mock
        switch ($case) {
            'duplicate' { $global:DiscoveryMock.repositories[1] = $global:DiscoveryMock.repositories[0] }
            'private' { $global:DiscoveryMock.repositories[1].private = $true }
            'archived' { $global:DiscoveryMock.repositories[1].archived = $true }
            'fork' { $global:DiscoveryMock.repositories[1].fork = $true }
            'name' { $global:DiscoveryMock.repositories[1].full_name = 'owner/../../elsewhere' }
            'negative-stars' { $global:DiscoveryMock.repositories[1].stargazers_count = -1 }
            'bad-stars' { $global:DiscoveryMock.repositories[1].stargazers_count = 'many' }
            'branch' { $global:DiscoveryMock.repositories[1].default_branch = '' }
        }
        $run = Run-Discovery "invalid-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $global:DiscoveryMock.calls.Count -eq 2) "Invalid selected repository ($case) cannot drive issue or release requests"
    }
    foreach ($case in 'pull-request', 'closed', 'wrong-repo', 'extra') {
        Reset-Mock
        switch ($case) {
            'pull-request' { $global:DiscoveryMock.issues['repo2'][0].pull_request = @{} }
            'closed' { $global:DiscoveryMock.issues['repo2'][0].state = 'closed' }
            'wrong-repo' { $global:DiscoveryMock.issues['repo2'][0].repository_url = 'https://api.github.com/repos/other/repo' }
            'extra' { $global:DiscoveryMock.issues['repo2'] = @(1..6 | ForEach-Object { New-Issue 2 'Add Windows ARM64 support' $_ }) }
        }
        $run = Run-Discovery "invalid-issue-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $run.report.recommendations.Count -eq 0) "Unexpected issue data ($case) fails closed"
    }

    Reset-Mock
    $global:DiscoveryMock.issues['repo2'][0].title = "Add Windows ARM64 support | <img src=x> [click](https://example.invalid) user's #123"
    $run = Run-Discovery 'markdown'
    $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
    Assert (-not $run.error -and $markdown -notlike '*<img*' -and $markdown -notlike '*[[]click](https://example.invalid)*') 'Untrusted issue titles cannot inject HTML or Markdown links'
    Assert ($markdown.Contains('user&#39;s #123') -and -not $markdown.Contains('&\#39;')) 'HTML entities remain renderable rather than becoming literal escape text'

    Reset-Mock
    $run = Run-Discovery 'write-refused' @{ CreatePullRequest = $true }
    Assert ($run.error -and $run.report.status -eq 'failed' -and $global:DiscoveryMock.calls.Count -eq 0) 'Discovery explicitly refuses automatic fork/PR creation'
    Reset-Mock
    $env:OPENARM_GITHUB_TRIAL_CREATE = 'True'
    $run = Run-Discovery 'environment-write-refused'
    Assert ($run.error -and $global:DiscoveryMock.calls.Count -eq 0) 'Actual pipeline environment opt-in is also refused without a reviewed URL'
    $env:OPENARM_GITHUB_TRIAL_CREATE = 'False'
    Reset-Mock
    $run = Run-Discovery 'ranked'
    Assert ($run.error -like '*already exists*' -and $global:DiscoveryMock.calls.Count -eq 0) 'Existing evidence cannot be overwritten'
    $run = Run-Discovery '..\outside-discovery'
    Assert ($run.error -like '*inside OutputRoot*' -and $global:DiscoveryMock.calls.Count -eq 0) 'Output must remain in the caller output root'

    $artifacts = Get-ChildItem -LiteralPath $root -Recurse -File | Get-Content -Raw
    Assert (@($artifacts | Where-Object { $_ -match 'public-test-placeholder|enterprise-test-placeholder|Do not persist raw issue bodies' }).Count -eq 0) 'Artifacts exclude tokens, raw API bodies and raw transport errors'
    Write-Host "$checks repository discovery checks passed."
} finally {
    Remove-Item Alias:\Receive-GitHubTrending -ErrorAction SilentlyContinue
    Remove-Item Function:\Mock-DiscoveryTrending -ErrorAction SilentlyContinue
    Remove-Item Alias:\Receive-ReleaseBytes -ErrorAction SilentlyContinue
    Remove-Item Function:\Mock-DiscoveryBytes -ErrorAction SilentlyContinue
    Remove-Item Alias:\Receive-DistributionMetadata -ErrorAction SilentlyContinue
    Remove-Item Function:\Mock-DistributionMetadata -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable DiscoveryMock -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
