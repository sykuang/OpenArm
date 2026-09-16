[CmdletBinding()]
param(
    [switch] $CreatePullRequest = ($env:OPENARM_GITHUB_TRIAL_CREATE -eq 'true'),
    [string] $Output = (Join-Path $PSScriptRoot "..\out\discovery-$([guid]::NewGuid())"),
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\ReleaseEvidence.ps1"

$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Discovery output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$token = $env:OPENARM_GITHUB_DISCOVERY_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or $token.StartsWith('$(')) { $token = '' }
$interval = if ($token) { 3 } else { 7 }
$report = @{
    schemaVersion = 2; status = 'discovering'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    completedAt = $null; apiHost = 'api.github.com'; authMode = $(if ($token) { 'token' } else { 'anonymous' })
    repositoryQuery = 'stars:>=100000 is:public archived:false fork:false'
    sort = 'stars'; order = 'desc'; requestedCount = 20; matchingRepositoryCount = $null
    assessedCount = 0; releaseAssessedCount = 0; nativeVerified = $false; recommendation = $null; error = $null
    releaseScope = @{
        endpoint = 'releases/latest'; maxAssetsRecordedPerRepository = 100; maxDownloadsPerRepository = 3
        maxZipBytes = 16MB; maxTotalDownloadBytes = 128MB; maxReleasePhaseSeconds = 180
        maxDownloadSeconds = 30; maxRedirects = 3; maxPeHeaderBytes = 65536
        maxZipEntries = 512; maxPeEntriesPerZip = 16
    }
    repositories = @(); requests = @()
    limitations = @(
        'Popularity means GitHub.com stars, not suitability for Windows or Arm64.'
        'The 100000-star threshold preserves the top twenty only if at least twenty qualify; otherwise this scan fails.'
        'GitHub search is indexed, not a transactionally consistent global snapshot. Ties retain API order.'
        'Each repository search uses open issues containing Windows AND ARM64 in title/body, newest updated first, at most five.'
        'Only explicit Windows Arm64 support requests or failure wording in those titles can yield a provisional recommendation.'
        'Aliases, other languages, older matches beyond five, closed issues and undocumented support may be missed.'
        'No matching issue is not proof of support; an open issue is not proof of a reproduced failure or absent support.'
        'Release scope is the latest published non-prerelease GitHub release and up to 100 assets returned with it, not all distribution channels or older releases.'
        'Missing releases/assets, filenames, unsupported formats and inspection limits do not prove missing Arm64 support.'
        'Filename hints are not verified architecture. PE headers identify individual EXE/DLL machine types, not working applications, signatures, complete integrity or native runtime compatibility.'
        'At most three assets per repository: EXE/DLL prefixes (64 KiB) or complete ZIPs (16 MiB). No archive paths are extracted; at most 512 entries and sixteen 64-KiB PE headers per ZIP.'
        'Downloads are anonymous HTTPS to GitHub/allowlisted release CDNs, at most three redirects, 30 seconds each, 128 MiB total and a 180-second release-phase budget; limit hits remain unverified.'
        'An x64 observation without Arm64 in the inspected sample is only a possible distribution gap; existing Arm64 binaries can coexist with real reported bugs.'
        'No source is cloned, built or executed. No fork, branch, PR, native target configuration or upstream change is created.'
    )
}

function ConvertTo-MarkdownText([string] $Value) {
    $text = [Net.WebUtility]::HtmlEncode(($Value -replace '[\p{Cc}\p{Cf}]', ' '))
    $text -replace '([\\`*_\[\]{}()|!])', '\$1'
}

function Save-Discovery {
    Write-Json (Join-Path $Output 'discovery.json') $report
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Windows Arm64 repository discovery')
    $lines.Add('')
    $lines.Add("Status: **$($report.status)**. Issues assessed: $($report.assessedCount)/20. Releases assessed: $($report.releaseAssessedCount)/20. Authentication: $($report.authMode).")
    $lines.Add("Started: $($report.startedAt). Completed: $($report.completedAt).")
    $lines.Add("Repository query: ``$($report.repositoryQuery)``; stars descending; first page only.")
    if ($report.error) { $lines.Add("Error: $(ConvertTo-MarkdownText $report.error)") }
    $lines.Add('')
    if ($report.recommendation) {
        $candidate = $report.recommendation
        $lines.Add("Recommendation (provisional): [$($candidate.fullName)]($($candidate.repositoryUrl)).")
        $lines.Add("Reported work: [$(ConvertTo-MarkdownText $candidate.issueTitle)]($($candidate.issueUrl)).")
        $lines.Add("Release evidence: $($candidate.releaseEvidence). Next investigation: $($candidate.workKind).")
        $lines.Add('Review the issue and reproduce it on Windows Arm64 before selecting a build target or making changes.')
    } elseif ($report.status -eq 'completed') {
        $lines.Add('No evidence-backed candidate found within these twenty repositories and the bounded issue search.')
    } else {
        $lines.Add('No recommendation: discovery has not completed successfully.')
    }
    $lines.Add('')
    $lines.Add('| Rank | Repository | Stars | Language | Issue assessment | Open matches / inspected | Release / Arm64 evidence |')
    $lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
    foreach ($repository in $report.repositories) {
        $lines.Add("| $($repository.rank) | [$($repository.fullName)]($($repository.url)) | $($repository.stars) | $(ConvertTo-MarkdownText $repository.language) | $($repository.assessment) | $($repository.matchingIssueCount) / $($repository.issues.Count) | $($repository.release.status) / $($repository.release.windowsArm64) |")
    }
    $lines.Add('')
    $lines.Add('## Issue evidence')
    foreach ($repository in $report.repositories) {
        foreach ($issue in $repository.issues) {
            $lines.Add("- $($repository.fullName): [$(ConvertTo-MarkdownText $issue.title)]($($issue.url)) ($($issue.classification))")
        }
        if ($repository.evidenceTruncated) { $lines.Add("- $($repository.fullName): additional matching issues were not inspected.") }
    }
    $lines.Add('')
    $lines.Add('## Release binary evidence')
    foreach ($repository in $report.repositories) {
        $release = $repository.release
        if (-not $release.url) { continue }
        $lines.Add("### $($repository.fullName): [$(ConvertTo-MarkdownText $release.tag)]($($release.url))")
        $lines.Add("Published: $(ConvertTo-MarkdownText $release.publishedAt). Returned assets: $($release.returnedAssetCount). Metadata truncated: $($release.metadataTruncated).")
        foreach ($asset in $release.assets) {
            $lines.Add("- [$(ConvertTo-MarkdownText $asset.name)]($($asset.url)): $($asset.size) bytes; filename hints $($asset.platformHint)/$($asset.architectureHint); inspection $($asset.inspection); PE architectures: $($asset.architectures -join ', '); mismatch: $($asset.architectureMismatch).")
            foreach ($binary in $asset.binaries) {
                $lines.Add("  - $(ConvertTo-MarkdownText $binary.name): $($binary.status) $($binary.machine) $($binary.architecture).")
            }
            if ($asset.error) { $lines.Add("  - Error: $(ConvertTo-MarkdownText $asset.error)") }
        }
    }
    $lines.Add('')
    $lines.Add('## Limits')
    foreach ($limitation in $report.limitations) { $lines.Add("- $limitation") }
    $lines | Set-Content -LiteralPath (Join-Path $Output 'discovery.md') -Encoding utf8
}

function Invoke-DiscoveryApi([string] $Uri, [hashtable] $Entry, [switch] $AllowNotFound) {
    $report.requests += $entry
    Save-Discovery
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'OpenArm-Repository-Discovery' }
    if ($token) { $headers.Authorization = "Bearer $token" }
    $status = 0
    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -TimeoutSec 30 `
            -MaximumRedirection 0 -SkipHttpErrorCheck -StatusCodeVariable status -ErrorAction Stop
    } catch {
        # Transport exceptions can reflect request headers; keep raw exceptions out of logs and artifacts.
        throw 'GitHub discovery transport failed. No request was retried; check network connectivity and rerun.'
    }
    $entry.httpStatus = $status
    if ($AllowNotFound -and $status -eq 404) { return $null }
    if ($status -ne 200) {
        throw "GitHub discovery failed (HTTP $status). Check public GitHub access and API rate limits; rerun after resolving the error."
    }
    if ($null -eq $response) { throw 'GitHub discovery returned an empty API response.' }
    $response
}

function Invoke-DiscoverySearch([string] $Kind, [string] $Query, [int] $Count) {
    if ($Kind -notin 'repositories', 'issues') { throw 'Unexpected discovery endpoint.' }
    if ($report.requests.Count) { Start-Sleep -Seconds $interval }
    $sort = if ($Kind -eq 'repositories') { 'stars' } else { 'updated' }
    $uri = "https://api.github.com/search/${Kind}?q=$([uri]::EscapeDataString($Query))&sort=$sort&order=desc&per_page=$Count&page=1"
    $response = Invoke-DiscoveryApi $uri @{ endpoint = $Kind; query = $Query; httpStatus = $null }
    if ($null -eq $response -or -not $response.PSObject.Properties['incomplete_results'] -or
        $response.incomplete_results -isnot [bool] -or
        -not $response.PSObject.Properties['total_count'] -or
        ($response.total_count -isnot [int] -and $response.total_count -isnot [long]) -or
        $response.total_count -lt 0 -or -not $response.PSObject.Properties['items'] -or
        $response.items -isnot [array]) { throw 'GitHub discovery returned an invalid search response.' }
    if ($response.incomplete_results) { throw 'GitHub returned incomplete search results; this is not a complete top-twenty assessment. Rerun later.' }
    if ($response.items.Count -ne [Math]::Min($Count, $response.total_count)) {
        throw 'GitHub search returned an unexpected number of items; the assessment is incomplete.'
    }
    $response
}

function Get-IssueClassification([string] $Title) {
    if ($Title -notmatch '(?i)\bwindows\b' -or $Title -notmatch '(?i)\b(?:arm64|aarch64)\b' -or
        $Title -match '(?i)\b(?:question|how|documentation|docs|guide|already|works)\b') { return 'needs_review' }
    if ($Title -match '(?i)\b(?:fails?|failing|failure|errors?|crash(?:es|ing)?|broken|cannot|unable|unsupported)\b' -or
        $Title -match "(?i)\b(?:can.t|doesn.t work|not working|not supported)\b") { return 'reported_arm64_work' }
    if ($Title -match '(?i)\b(?:add|implement|enable|provide|port|request)\b' -or
        $Title -match '(?i)\bsupport\s+(?:for\s+)?windows\b|\bwindows\b.{0,40}\b(?:arm64|aarch64)\s+support\b') {
        return 'reported_arm64_work'
    }
    'needs_review'
}

$currentRepository = $null
try {
    if ($CreatePullRequest) {
        throw 'Discovery is read-only. Leave createForkPullRequest false; review a candidate and supply sourceRepositoryUrl in a separate run before creating a fork PR.'
    }
    Write-Host "Discovering the top twenty public repositories using $($report.authMode) GitHub.com reads ($interval seconds between searches)."
    $search = Invoke-DiscoverySearch 'repositories' $report.repositoryQuery 20
    $report.matchingRepositoryCount = $search.total_count
    if ($search.items.Count -ne 20 -or $search.total_count -gt 4000) {
        throw 'Cannot establish the top twenty within the star threshold and GitHub search scope; expected at least twenty and at most 4000 qualifying repositories.'
    }
    $previousStars = [long]::MaxValue
    $seen = @{}
    foreach ($repository in $search.items) {
        if ($repository.full_name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
            $seen.ContainsKey($repository.full_name) -or
            ($repository.stargazers_count -isnot [int] -and $repository.stargazers_count -isnot [long]) -or
            $repository.stargazers_count -lt 100000 -or $repository.stargazers_count -gt $previousStars -or
            $repository.private -isnot [bool] -or $repository.private -or
            $repository.archived -isnot [bool] -or $repository.archived -or
            $repository.fork -isnot [bool] -or $repository.fork -or
            $repository.default_branch -isnot [string] -or -not $repository.default_branch -or
            ($null -ne $repository.language -and $repository.language -isnot [string])) {
            throw 'GitHub returned an invalid, duplicated, ineligible or incorrectly ranked repository.'
        }
        $seen[$repository.full_name] = $true
        $previousStars = $repository.stargazers_count
        $report.repositories += @{
            rank = $report.repositories.Count + 1; fullName = $repository.full_name
            url = "https://github.com/$($repository.full_name)"; stars = $repository.stargazers_count
            language = $repository.language; defaultBranch = $repository.default_branch
            assessment = 'not_assessed'; matchingIssueCount = $null; evidenceTruncated = $false; issues = @()
            release = @{ status = 'not_assessed'; windowsArm64 = 'unknown'; url = $null }
            issueQuery = "repo:$($repository.full_name) is:issue is:open Windows ARM64 in:title,body"
        }
    }
    foreach ($repository in $report.repositories) {
        $currentRepository = $repository
        $issues = Invoke-DiscoverySearch 'issues' $repository.issueQuery 5
        $repository.matchingIssueCount = $issues.total_count
        $repository.evidenceTruncated = $issues.total_count -gt 5
        $seenIssues = @{}
        foreach ($issue in $issues.items) {
            if ($issue.state -ne 'open' -or $issue.PSObject.Properties['pull_request'] -or
                $issue.repository_url -ne "https://api.github.com/repos/$($repository.fullName)" -or
                ($issue.number -isnot [int] -and $issue.number -isnot [long]) -or $issue.number -lt 1 -or
                $seenIssues.ContainsKey([string]$issue.number) -or $issue.title -isnot [string] -or -not $issue.title) {
                throw 'GitHub returned an invalid, duplicated or out-of-scope issue.'
            }
            $seenIssues[[string]$issue.number] = $true
            $title = $issue.title
            if ($token) { $title = $title.Replace($token, '[redacted]') }
            $repository.issues += @{
                number = $issue.number; title = $title
                url = "https://github.com/$($repository.fullName)/issues/$($issue.number)"
                classification = Get-IssueClassification $title
            }
        }
        $repository.assessment = if (@($repository.issues | Where-Object classification -eq 'reported_arm64_work').Count) {
            'reported_arm64_work'
        } elseif ($repository.matchingIssueCount) { 'needs_review' } else { 'no_matching_open_issue' }
        $report.assessedCount++
        Save-Discovery
    }
    $budget = @{ remainingBytes = 128MB; assetCount = 0; clock = [Diagnostics.Stopwatch]::StartNew() }
    foreach ($repository in $report.repositories) {
        $currentRepository = $repository
        $repository.release.status = 'assessing'
        $release = Invoke-DiscoveryApi "https://api.github.com/repos/$($repository.fullName)/releases/latest" `
            @{ endpoint = 'latest_release'; repository = $repository.fullName; httpStatus = $null } -AllowNotFound
        $null = Get-ReleaseEvidence $release $repository.fullName $budget -Result $repository.release
        $report.releaseAssessedCount++
        Save-Discovery
    }
    $currentRepository = $null
    $candidate = $report.repositories | Where-Object assessment -eq 'reported_arm64_work' | Select-Object -First 1
    if ($candidate) {
        $issue = $candidate.issues | Where-Object classification -eq 'reported_arm64_work' | Select-Object -First 1
        $report.recommendation = @{
            fullName = $candidate.fullName; repositoryUrl = $candidate.url; stars = $candidate.stars
            issueUrl = $issue.url; issueTitle = $issue.title; provisional = $true
            releaseEvidence = $candidate.release.windowsArm64
            releaseUrl = $candidate.release.url
            workKind = $(if ($candidate.release.artifactProblem) { 'investigate_release_artifact' }
                elseif ($candidate.release.windowsArm64 -in 'pe_header_found', 'advertised_unverified') { 'investigate_existing_arm64_distribution' }
                elseif ($candidate.release.windowsArm64 -eq 'x64_observed_arm64_not_found_in_sample') { 'investigate_possible_distribution_gap' }
                else { 'investigate_reported_arm64_work' })
        }
    }
    $report.status = 'completed'
} catch {
    if ($currentRepository) {
        if ($currentRepository.release.status -ne 'not_assessed') { $currentRepository.release.status = 'error' }
        else { $currentRepository.assessment = 'error' }
    }
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    if ($token) { $report.error = $report.error.Replace($token, '[redacted]') }
    throw $report.error
} finally {
    $report.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-Discovery
}
Write-Host 'Discovery completed. Review discovery.md and discovery.json; results are provisional, not native verification.'
