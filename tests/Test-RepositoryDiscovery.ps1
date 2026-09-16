Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\repository-discovery-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $root
$savedEnvironment = @{}
foreach ($name in 'OPENARM_GITHUB_DISCOVERY_TOKEN', 'OPENARM_GITHUB_TOKEN', 'OPENARM_GITHUB_TRIAL_CREATE') {
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
function New-ReleaseAsset([string] $Name, [long] $Size = 256) {
    @{ name = $Name; size = $Size; state = 'uploaded'
        browser_download_url = "https://github.com/owner/repo2/releases/download/v1/$([uri]::EscapeDataString($Name))" }
}
function Reset-Mock {
    $env:OPENARM_GITHUB_DISCOVERY_TOKEN = 'public-test-placeholder'
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
            'repo3' = @(New-Issue 3 'Build fails on Windows ARM64')
        }
        releases = @{}; downloads = 0; assetMachine = 0xAA64; assetFailure = $false
        issueTotal = @{}; incompleteAt = 0; failAt = 0; failStatus = 403
        throwAt = 0; malformedAt = 0; total = 100
    }
}
function global:Start-Sleep { param($Seconds) $global:DiscoveryMock.sleeps.Add($Seconds) }
function global:Mock-DiscoveryBytes {
    param($Uri, $ExpectedSize, $PrefixOnly, $Budget)
    $m = $global:DiscoveryMock
    $m.downloads++
    if ($m.assetFailure) { throw 'Release download failed (HTTP 403).' }
    $bytes = [byte[]]::new(256)
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, 128)
    [BitConverter]::GetBytes([uint16]$m.assetMachine).CopyTo($bytes, 132)
    $Budget.remainingBytes -= $bytes.Length
    return ,$bytes
}
Set-Alias -Name Receive-ReleaseBytes -Value Mock-DiscoveryBytes -Scope Global
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection,
        [switch] $SkipHttpErrorCheck, $StatusCodeVariable, $ErrorAction)
    $m = $global:DiscoveryMock
    $url = [uri]$Uri
    if ($Method -ne 'GET' -or $url.Host -ne 'api.github.com' -or $url.Scheme -ne 'https' -or
        $MaximumRedirection -ne 0 -or $TimeoutSec -ne 30) { throw 'Unexpected network boundary.' }
    $authorization = if ($Headers.ContainsKey('Authorization')) { $Headers.Authorization } else { '' }
    $m.calls.Add(@{ route = [uri]::UnescapeDataString($url.PathAndQuery); authorization = $authorization })
    $call = $m.calls.Count
    if ($call -eq $m.throwAt) { throw 'Transport error public-test-placeholder enterprise-test-placeholder' }
    $status = if ($call -eq $m.failAt) { $m.failStatus } else { 200 }
    Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    if ($status -ne 200) { return [pscustomobject]@{ message = 'Secret public-test-placeholder' } }
    if ($call -eq $m.malformedAt) { return [pscustomobject]@{ message = 'Invalid response' } }
    if ($url.AbsolutePath -match '^/repos/owner/(repo\d+)/releases/latest$') {
        if ($m.releases.ContainsKey($Matches[1])) {
            return $m.releases[$Matches[1]] | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        }
        Set-Variable -Name $StatusCodeVariable -Value 404 -Scope 1
        return [pscustomobject]@{ message = 'Not Found' }
    }
    if ($url.AbsolutePath -eq '/search/repositories') {
        $items = $m.repositories
        $total = $m.total
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
    try { & "$repo\scripts\Find-Arm64Candidate.ps1" -Output $output -OutputRoot $root @Arguments }
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
    Assert ($global:DiscoveryMock.calls.Count -eq 41) 'One repository search, twenty issue searches and twenty latest-release reads only'
    Assert ($r.releaseAssessedCount -eq 20 -and $r.repositories[0].release.status -eq 'no_published_release') 'A missing stable release stays unknown, not proof of absent Arm64 support'
    Assert ($global:DiscoveryMock.calls[0].route -eq '/search/repositories?q=stars:>=100000 is:public archived:false fork:false&sort=stars&order=desc&per_page=20&page=1') 'Ranking uses an explicit safe threshold, descending stars and only the first twenty'
    Assert (($r.repositories.fullName -join ',') -eq ((1..20 | ForEach-Object { "owner/repo$_" }) -join ',')) 'API star order and all repository identities are preserved'
    Assert ($r.repositories[0].assessment -eq 'needs_review' -and $r.repositories[3].assessment -eq 'no_matching_open_issue') 'Incidental mentions and no matches do not imply lack of support'
    Assert ($r.repositories[1].assessment -eq 'reported_arm64_work' -and $r.repositories[2].assessment -eq 'reported_arm64_work') 'Explicit support requests and build failures are recognized'
    Assert ($r.recommendation.fullName -eq 'owner/repo2' -and $r.recommendation.issueUrl -eq 'https://github.com/owner/repo2/issues/1') 'Highest-star issue-backed candidate is selected'
    Assert ($r.nativeVerified -eq $false -and $r.recommendation.provisional -eq $true) 'Recommendation is explicitly provisional, never native proof'
    Assert ($r.authMode -eq 'token' -and @($global:DiscoveryMock.calls | Where-Object authorization -ne 'Bearer public-test-placeholder').Count -eq 0) 'Only the separate public discovery token is used'
    Assert ($global:DiscoveryMock.sleeps.Count -eq 20 -and @($global:DiscoveryMock.sleeps | Where-Object { $_ -ne 3 }).Count -eq 0) 'Authenticated searches are paced below thirty per minute'
    $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
    Assert ($markdown -like '*owner/repo20*' -and $markdown -like '*Add Windows ARM64 support*' -and $markdown -like '*provisional*') 'Readable report includes the full ranking and evidence'
    Assert ($r.startedAt -and $r.completedAt -and $r.repositoryQuery -and $r.limitations.Count -gt 0) 'Search scope, timestamps and limitations are durable'

    foreach ($case in 'arm64', 'x64', 'mislabeled', 'empty', 'msi', 'no-assets') {
        Reset-Mock
        $name = switch ($case) {
            'x64' { 'app-win-x64.exe' }; 'msi' { 'app-win-arm64.msi' }; default { 'app-win-arm64.exe' }
        }
        $size = if ($case -eq 'empty') { 0 } else { 256 }
        $assets = @(if ($case -ne 'no-assets') { New-ReleaseAsset $name $size })
        $global:DiscoveryMock.releases['repo2'] = New-Release $assets
        if ($case -in 'x64', 'mislabeled') { $global:DiscoveryMock.assetMachine = 0x8664 }
        $run = Run-Discovery "release-$case"
        $expected = switch ($case) {
            'x64' { 'investigate_possible_distribution_gap' }
            { $_ -in 'empty', 'mislabeled' } { 'investigate_release_artifact' }
            'no-assets' { 'investigate_reported_arm64_work' }
            default { 'investigate_existing_arm64_distribution' }
        }
        Assert (-not $run.error -and $run.report.recommendation.fullName -eq 'owner/repo2' -and
            $run.report.recommendation.workKind -eq $expected) "Release evidence changes the investigation, not the issue-backed star ranking: $case ($($run.error))"
        $release = $run.report.repositories[1].release
        Assert ($release.tag -eq 'v1' -and ([DateTimeOffset]$release.publishedAt).ToUniversalTime().ToString('o') -like '2026-09-16T00:00:00*' -and
            $release.url -eq 'https://github.com/owner/repo2/releases/tag/v1') 'Latest-release provenance is durable'
        if ($case -eq 'arm64') {
            Assert ($release.windowsArm64 -eq 'pe_header_found' -and $release.assets[0].binaries[0].machine -eq '0xAA64' -and
                $global:DiscoveryMock.downloads -eq 1) 'Public discovery inspects actual binary headers'
            $markdown = Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw
            Assert ($markdown -like '*Release binary evidence*' -and $markdown -like '*0xAA64*' -and $markdown -like '*app-win-arm64.exe*') 'Markdown exposes release and binary evidence, not just JSON'
        }
    }
    foreach ($case in 'http', 'malformed', 'draft', 'prerelease', 'date', 'asset-url', 'download') {
        Reset-Mock
        $global:DiscoveryMock.releases['repo2'] = New-Release @(New-ReleaseAsset 'app.exe')
        switch ($case) {
            'http' { $global:DiscoveryMock.failAt = 23 }
            'malformed' { $global:DiscoveryMock.malformedAt = 23 }
            'draft' { $global:DiscoveryMock.releases['repo2'].draft = $true }
            'prerelease' { $global:DiscoveryMock.releases['repo2'].prerelease = $true }
            'date' { $global:DiscoveryMock.releases['repo2'].published_at = 'not a date' }
            'asset-url' { $global:DiscoveryMock.releases['repo2'].assets[0].browser_download_url = 'https://evil.invalid/app.exe' }
            'download' { $global:DiscoveryMock.assetFailure = $true }
        }
        $run = Run-Discovery "release-error-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $null -eq $run.report.recommendation -and
            $run.report.assessedCount -eq 20 -and $run.report.releaseAssessedCount -eq 1 -and
            $global:DiscoveryMock.calls.Count -eq 23) "Release failure retains issue progress but prevents a premature recommendation: $case"
        Assert ($run.report.repositories[1].assessment -eq 'reported_arm64_work' -and
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
    Assert (-not $run.error -and $run.report.status -eq 'completed' -and $null -eq $run.report.recommendation) 'Complete scan can honestly recommend no candidate'
    Assert ((Get-Content -LiteralPath (Join-Path $run.output 'discovery.md') -Raw) -like '*No evidence-backed candidate*') 'No candidate is explicit in the readable report'

    foreach ($token in '', '$(OpenArm.GitHubDiscoveryToken)') {
        Reset-Mock
        $env:OPENARM_GITHUB_DISCOVERY_TOKEN = $token
        $run = Run-Discovery "anonymous-$([guid]::NewGuid())"
        Assert (-not $run.error -and $run.report.authMode -eq 'anonymous') 'Missing or unexpanded optional token uses explicit anonymous mode'
        Assert (@($global:DiscoveryMock.calls | Where-Object authorization -ne '').Count -eq 0) 'Anonymous mode never falls back to the enterprise token'
        Assert ($global:DiscoveryMock.sleeps.Count -eq 20 -and @($global:DiscoveryMock.sleeps | Where-Object { $_ -ne 7 }).Count -eq 0) 'Anonymous searches are paced below ten per minute'
    }

    foreach ($title in 'Question about Windows ARM64 support', 'How does Windows ARM64 support work?',
        'Windows ARM64 documentation update', 'Windows ARM64 works on my machine', 'Add Linux ARM64 support',
        'ARM64 fails to build on macOS', 'Windows ARM64 support is already implemented') {
        Reset-Mock
        $global:DiscoveryMock.issues = @{ 'repo1' = @(New-Issue 1 $title) }
        $run = Run-Discovery "mention-$([guid]::NewGuid())"
        Assert (-not $run.error -and $null -eq $run.report.recommendation -and
            $run.report.repositories[0].assessment -eq 'needs_review') "Not absence proof: $title"
    }

    Reset-Mock
    $global:DiscoveryMock.issues['repo2'] = @(1..5 | ForEach-Object { New-Issue 2 "Windows ARM64 mention $_" $_ })
    $global:DiscoveryMock.issueTotal['repo2'] = 12
    $run = Run-Discovery 'bounded-issues'
    Assert (-not $run.error -and $run.report.repositories[1].matchingIssueCount -eq 12 -and
        $run.report.repositories[1].issues.Count -eq 5 -and $run.report.repositories[1].evidenceTruncated) 'Only five recent issue titles are inspected and truncation stays visible'
    Assert ($global:DiscoveryMock.calls.Count -eq 41 -and $run.report.recommendation.fullName -eq 'owner/repo3') 'Truncation does not widen the scan or manufacture evidence'

    foreach ($field in 'incompleteAt', 'malformedAt', 'throwAt') {
        foreach ($at in 1, 4) {
            Reset-Mock
            $global:DiscoveryMock[$field] = $at
            $run = Run-Discovery "$field-$at"
            Assert ($run.error -and $run.report.status -eq 'failed' -and $null -eq $run.report.recommendation) "$field at request $at cannot become a successful scan"
            Assert ($global:DiscoveryMock.calls.Count -eq $at -and $run.report.assessedCount -eq $(if ($at -eq 1) { 0 } else { 2 })) 'Failure is bounded and preserves assessed progress without a premature recommendation'
            Assert (Test-Path -LiteralPath (Join-Path $run.output 'discovery.md')) 'Failure retains a readable report'
        }
    }
    foreach ($status in 301, 401, 403, 422, 429, 503) {
        Reset-Mock
        $global:DiscoveryMock.failAt = 4; $global:DiscoveryMock.failStatus = $status
        $run = Run-Discovery "http-$status"
        Assert ($run.error -like "*HTTP $status*" -and $run.report.status -eq 'failed' -and
            $global:DiscoveryMock.calls.Count -eq 4 -and $run.report.assessedCount -eq 2) "HTTP $status stops explicitly without widening or an authentication fallback"
    }

    foreach ($case in 'fewer', 'extra', 'order', 'duplicate', 'private', 'archived', 'fork', 'name', 'threshold', 'scope') {
        Reset-Mock
        switch ($case) {
            'fewer' { $global:DiscoveryMock.repositories = @($global:DiscoveryMock.repositories | Select-Object -First 19) }
            'extra' { $global:DiscoveryMock.repositories += $global:DiscoveryMock.repositories[0] }
            'order' { $global:DiscoveryMock.repositories[1].stargazers_count = 900000 }
            'duplicate' { $global:DiscoveryMock.repositories[1] = $global:DiscoveryMock.repositories[0] }
            'private' { $global:DiscoveryMock.repositories[1].private = $true }
            'archived' { $global:DiscoveryMock.repositories[1].archived = $true }
            'fork' { $global:DiscoveryMock.repositories[1].fork = $true }
            'name' { $global:DiscoveryMock.repositories[1].full_name = 'owner/../../elsewhere' }
            'threshold' { $global:DiscoveryMock.repositories[19].stargazers_count = 99999 }
            'scope' { $global:DiscoveryMock.total = 4001 }
        }
        $run = Run-Discovery "invalid-$case"
        Assert ($run.error -and $run.report.status -eq 'failed' -and $global:DiscoveryMock.calls.Count -eq 1) "Invalid top twenty ($case) cannot drive further requests"
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
        Assert ($run.error -and $run.report.status -eq 'failed' -and $null -eq $run.report.recommendation) "Unexpected issue data ($case) fails closed"
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
    Remove-Item Alias:\Receive-ReleaseBytes -ErrorAction SilentlyContinue
    Remove-Item Function:\Mock-DiscoveryBytes -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable DiscoveryMock -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
