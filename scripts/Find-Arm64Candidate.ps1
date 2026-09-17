[CmdletBinding()]
param(
    [switch] $CreatePullRequest = ($env:OPENARM_GITHUB_TRIAL_CREATE -eq 'true'),
    [string] $Track = $(if ($env:OPENARM_DISCOVERY_TRACK) { $env:OPENARM_DISCOVERY_TRACK } else { 'both' }),
    [string] $Output = (Join-Path $PSScriptRoot "..\out\discovery-$([guid]::NewGuid())"),
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\ReleaseEvidence.ps1"
. "$PSScriptRoot\RepositorySources.ps1"

$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Discovery output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$token = $env:OPENARM_GITHUB_DISCOVERY_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or $token.StartsWith('$(')) { $token = '' }
$interval = if ($token) { 3 } else { 7 }
$report = @{
    schemaVersion = 3; status = 'discovering'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    completedAt = $null; apiHost = 'api.github.com'; authMode = $(if ($token) { 'token' } else { 'anonymous' })
    track = $Track; requestedCount = 0; maxRepositoriesPerTrack = 10
    assessedCount = 0; releaseAssessedCount = 0; nativeVerified = $false; recommendations = @(); error = $null
    sources = @()
    releaseScope = @{
        endpoint = 'releases/latest'; maxAssetsRecordedPerRepository = 100; maxDownloadsPerRepository = 3
        maxZipBytes = 16MB; maxTotalDownloadBytes = 128MB; maxReleasePhaseSeconds = 180
        maxDownloadSeconds = 30; maxRedirects = 3; maxPeHeaderBytes = 65536
        maxZipEntries = 512; maxPeEntriesPerZip = 16
    }
    repositories = @(); requests = @()
    limitations = @(
        'Trending uses the first ten entries on the public GitHub weekly Trending page, preserving its displayed order, not lifetime-star order or a computed growth score.'
        'Weekly-star counts are observations reported by GitHub, not independently reconstructed star histories. Markup/source failures stop the scan; lifetime stars are never substituted.'
        'Foundational uses a reviewed catalog of at most ten runtimes, toolchains and shared libraries. Catalog order and rationale are curated priorities, not measured dependency counts or proof of missing native support.'
        'Tracks are ranked independently. Repositories appearing in both are assessed once and retain both source ranks; two recommendation slots can identify the same underlying repair candidate.'
        'There is no minimum lifetime-star threshold. Repository metadata, issue search and release reads are not a transactionally consistent snapshot.'
        'Each repository search uses open issues containing Windows AND ARM64 in title/body, newest updated first, at most five.'
        'Only explicit Windows Arm64 support requests or failure wording in those titles can yield a provisional recommendation.'
        'Aliases, other languages, older matches beyond five, closed issues and undocumented support may be missed.'
        'No matching issue is not proof of support; an open issue is not proof of a reproduced failure or absent support.'
        'Before editing, review existing fixes and trace a reported application blocker to its owning dependency. A shared dependency should be repaired once, not patched separately in every caller.'
        'Only native Windows Arm64 support is an eligible repair goal. Emulation/fallback reports require review, not automatic remediation; native builds, 0xAA64 runtime binaries and an installed core workflow remain mandatory.'
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
    $lines.Add("Status: **$($report.status)**. Issues assessed: $($report.assessedCount)/$($report.requestedCount). Releases assessed: $($report.releaseAssessedCount)/$($report.requestedCount). Authentication: $($report.authMode).")
    $lines.Add("Started: $($report.startedAt). Completed: $($report.completedAt).")
    $lines.Add("Selected discovery track: ``$(ConvertTo-MarkdownText $report.track)``. At most ten repositories per track; no lifetime-star threshold.")
    foreach ($source in $report.sources) {
        $lines.Add("- $($source.track): $($source.method); status $($source.status); source $(ConvertTo-MarkdownText $source.location).")
    }
    if ($report.error) { $lines.Add("Error: $(ConvertTo-MarkdownText $report.error)") }
    $lines.Add('')
    foreach ($candidate in $report.recommendations) {
        $lines.Add("$($candidate.track) recommendation (provisional): [$($candidate.fullName)]($($candidate.repositoryUrl)).")
        $lines.Add("Reported work: [$(ConvertTo-MarkdownText $candidate.issueTitle)]($($candidate.issueUrl)).")
        $lines.Add("Release evidence: $($candidate.releaseEvidence). Next investigation: $($candidate.workKind).")
        $lines.Add('Review the issue and reproduce it on Windows Arm64 before selecting a build target or making changes.')
    }
    if ($report.status -eq 'completed') {
        foreach ($source in $report.sources) {
            if (-not @($report.recommendations | Where-Object track -eq $source.track).Count) {
                $lines.Add("No evidence-backed candidate found for $($source.track) within this bounded scan.")
            }
        }
    } else { $lines.Add('No recommendations: discovery has not completed successfully.') }
    $lines.Add('')
    $lines.Add('| Source ranks | Repository | Lifetime stars | Weekly stars | Language | Issue assessment | Open matches / inspected | Release / Arm64 evidence |')
    $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($repository in $report.repositories) {
        $ranks = ($repository.tracks | ForEach-Object { "$_ #$($repository.sourceRanks[$_])" }) -join ', '
        $lines.Add("| $ranks | [$($repository.fullName)]($($repository.url)) | $($repository.stars) | $($repository.weeklyStars) | $(ConvertTo-MarkdownText $repository.language) | $($repository.assessment) | $($repository.matchingIssueCount) / $($repository.issues.Count) | $($repository.release.status) / $($repository.release.windowsArm64) |")
    }
    $lines.Add('')
    $lines.Add('## Foundational selection rationale')
    foreach ($repository in $report.repositories) {
        if ($repository.foundationReason) { $lines.Add("- $($repository.fullName): $(ConvertTo-MarkdownText $repository.foundationReason)") }
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

function Invoke-DiscoverySearch([string] $Query) {
    if ($report.requests.Count) { Start-Sleep -Seconds $interval }
    $uri = "https://api.github.com/search/issues?q=$([uri]::EscapeDataString($Query))&sort=updated&order=desc&per_page=5&page=1"
    $response = Invoke-DiscoveryApi $uri @{ endpoint = 'issues'; query = $Query; httpStatus = $null }
    if ($null -eq $response -or -not $response.PSObject.Properties['incomplete_results'] -or
        $response.incomplete_results -isnot [bool] -or
        -not $response.PSObject.Properties['total_count'] -or
        ($response.total_count -isnot [int] -and $response.total_count -isnot [long]) -or
        $response.total_count -lt 0 -or -not $response.PSObject.Properties['items'] -or
        $response.items -isnot [array]) { throw 'GitHub discovery returned an invalid search response.' }
    if ($response.incomplete_results) { throw 'GitHub returned incomplete search results; this is not a complete assessment of the selected repositories. Rerun later.' }
    if ($response.items.Count -ne [Math]::Min(5, $response.total_count)) {
        throw 'GitHub search returned an unexpected number of items; the assessment is incomplete.'
    }
    $response
}

function Get-IssueClassification([string] $Title) {
    if ($Title -notmatch '(?i)\bwindows\b' -or $Title -notmatch '(?i)\b(?:arm64|aarch64)\b|\bwindows on arm\b' -or
        $Title -match '(?i)\b(?:question|how|documentation|docs|guide|already|works|emulat\w*)\b|\bx(?:64|86)\s+fallback\b') { return 'needs_review' }
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
    if ($Track -cnotin @('both', 'trending', 'foundational')) { throw 'Select both, trending or foundational discovery.' }
    Write-Host "Discovering $Track repositories using $($report.authMode) GitHub.com reads ($interval seconds between searches)."
    $seeds = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($sourceTrack in @('trending', 'foundational')) {
        if ($Track -ne 'both' -and $Track -ne $sourceTrack) { continue }
        $source = @{ track = $sourceTrack; status = 'reading'; selectedCount = 0; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
            method = $(if ($sourceTrack -eq 'trending') { 'github_weekly_trending' } else { 'reviewed_catalog_order' })
            location = $(if ($sourceTrack -eq 'trending') { 'https://github.com/trending?since=weekly' } else { 'targets\discovery\foundational.json' }) }
        $report.sources += $source
        Save-Discovery
        if ($sourceTrack -eq 'trending') {
            $request = @{ endpoint = 'weekly_trending'; uri = $source.location; httpStatus = $null }
            $report.requests += $request
            $html = Receive-GitHubTrending
            $request.httpStatus = 200
            $selection = ConvertFrom-GitHubTrending $html
            $source.snapshotSha256 = $selection.snapshotSha256
            $source.availableCount = $selection.availableCount
        } else {
            $selection = Read-FoundationalRepositories
            $source.catalogSha256 = $selection.catalogSha256
            $source.availableCount = $selection.items.Count
        }
        foreach ($item in $selection.items) {
            if (-not $seen.ContainsKey($item.fullName)) {
                $seed = @{ fullName = $item.fullName; tracks = @(); sourceRanks = @{}; weeklyStars = $null; foundationReason = $null; foundationCategory = $null }
                $seen[$item.fullName] = $seed
                $seeds.Add($seed)
            }
            $seed = $seen[$item.fullName]
            $seed.tracks += $sourceTrack; $seed.sourceRanks[$sourceTrack] = $item.rank
            if ($sourceTrack -eq 'trending') { $seed.weeklyStars = $item.weeklyStars }
            else { $seed.foundationReason = $item.reason; $seed.foundationCategory = $item.category }
        }
        $source.selectedCount = $selection.items.Count; $source.status = 'completed'
    }
    $report.requestedCount = $seeds.Count
    foreach ($seed in $seeds) {
        $repository = Invoke-DiscoveryApi "https://api.github.com/repos/$($seed.fullName)" `
            @{ endpoint = 'repository'; repository = $seed.fullName; httpStatus = $null }
        if ($repository.full_name -ine $seed.fullName -or
            ($repository.stargazers_count -isnot [int] -and $repository.stargazers_count -isnot [long]) -or
            $repository.stargazers_count -lt 0 -or
            $repository.private -isnot [bool] -or $repository.private -or
            $repository.archived -isnot [bool] -or $repository.archived -or
            $repository.fork -isnot [bool] -or $repository.fork -or
            $repository.default_branch -isnot [string] -or -not $repository.default_branch -or
            ($null -ne $repository.language -and $repository.language -isnot [string])) {
            throw 'GitHub returned an invalid, renamed or ineligible selected repository.'
        }
        $report.repositories += @{
            rank = $report.repositories.Count + 1; fullName = $repository.full_name
            tracks = $seed.tracks; sourceRanks = $seed.sourceRanks; weeklyStars = $seed.weeklyStars
            foundationReason = $seed.foundationReason; foundationCategory = $seed.foundationCategory
            url = "https://github.com/$($repository.full_name)"; stars = $repository.stargazers_count
            language = $repository.language; defaultBranch = $repository.default_branch
            assessment = 'not_assessed'; matchingIssueCount = $null; evidenceTruncated = $false; issues = @()
            release = @{ status = 'not_assessed'; windowsArm64 = 'unknown'; url = $null }
            issueQuery = "repo:$($repository.full_name) is:issue is:open Windows ARM64 in:title,body"
        }
    }
    foreach ($repository in $report.repositories) {
        $currentRepository = $repository
        $issues = Invoke-DiscoverySearch $repository.issueQuery
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
    foreach ($source in $report.sources) {
        $sourceTrack = $source.track
        $candidate = $report.repositories | Where-Object { $_.assessment -eq 'reported_arm64_work' -and $_.tracks -contains $sourceTrack } |
            Sort-Object { $_.sourceRanks[$sourceTrack] } | Select-Object -First 1
        if (-not $candidate) { continue }
        $issue = $candidate.issues | Where-Object classification -eq 'reported_arm64_work' | Select-Object -First 1
        $report.recommendations += @{
            track = $sourceTrack; sourceRank = $candidate.sourceRanks[$sourceTrack]; nativeGoal = 'native_windows_arm64'
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
    foreach ($source in $report.sources) {
        if ($source.status -eq 'reading') { $source.status = 'error' }
    }
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
