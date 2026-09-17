[CmdletBinding()]
param(
    [switch] $CreatePullRequest = ($env:OPENARM_GITHUB_TRIAL_CREATE -eq 'true'),
    [string] $Track = $(if ($env:OPENARM_DISCOVERY_TRACK) { $env:OPENARM_DISCOVERY_TRACK } else { 'both' }),
    [int] $MaxRepositories = 100,
    [string] $Output = (Join-Path $PSScriptRoot "..\out\discovery-$([guid]::NewGuid())"),
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\ReleaseEvidence.ps1"
. "$PSScriptRoot\RepositorySources.ps1"
. "$PSScriptRoot\DistributionEvidence.ps1"

$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Discovery output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$token = $env:OPENARM_GITHUB_DISCOVERY_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or $token.StartsWith('$(')) { $token = '' }
$interval = if ($token) { 3 } else { 7 }
$report = @{
    schemaVersion = 4; status = 'discovering'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    completedAt = $null; apiHost = 'api.github.com'; authMode = $(if ($token) { 'token' } else { 'anonymous' })
    track = $Track; requestedCount = 0; maxRepositories = $MaxRepositories; selectionShortfall = $null
    selectionMode = 'missing_native_support_only'; distributionCatalogSha256 = $null
    distributionAssessedCount = 0
    assessedCount = 0; releaseAssessedCount = 0; nativeVerified = $false; recommendations = @(); error = $null
    sources = @()
    upstreamFixReview = @{
        status = 'not_assessed'; requestedCount = 0; assessedCount = 0
        relationship = 'closing_links_and_issue_number_references'
        maxPullRequestsPerIssue = 10; maxReferencingPullRequestsPerIssue = 5
        maxIssuesPerQuery = 100; maxQueries = 5
    }
    releaseScope = @{
        endpoint = 'releases/latest'; maxAssetsRecordedPerRepository = 100; maxDownloadsPerRepository = 3
        maxZipBytes = 16MB; maxTotalDownloadBytes = 128MB; maxReleasePhaseSeconds = 180
        maxDownloadSeconds = 30; maxRedirects = 3; maxPeHeaderBytes = 65536
        maxZipEntries = 512; maxPeEntriesPerZip = 16
    }
    repositories = @(); requests = @()
    limitations = @(
        'The default budget is 100 distinct repositories total. Both tracks reserve up to half the budget for available Foundational entries, then fill with Trending; overlap does not consume another slot and remaining Foundational entries backfill a Trending shortfall.'
        'Trending pools weekly pages in this fixed order: global, C, C++, Rust, Go, Python, JavaScript, TypeScript, C#. Pages are fetched only until the unique budget is filled (at most nine pages); first encounter preserves page/display order. This is not an official global top-100 ranking, lifetime-star order or a computed growth score.'
        'Weekly-star counts are observations reported by GitHub, not independently reconstructed star histories. Markup/source failures stop the scan; lifetime stars are never substituted.'
        'Foundational uses a reviewed catalog of at most 100 runtimes, toolchains and shared libraries (currently ten). Catalog order and rationale are curated priorities, not measured dependency counts or proof of missing native support. Source exhaustion is reported as selectionShortfall, never filled with an unrelated ranking.'
        'Tracks are ranked independently. Repositories appearing in both are assessed once and retain both source ranks; two recommendation slots can identify the same underlying repair candidate.'
        'There is no minimum lifetime-star threshold. Repository metadata, issue search and release reads are not a transactionally consistent snapshot.'
        'Each repository search uses open issues containing Windows AND ARM64 in title/body, newest updated first, at most five.'
        'Only explicit requests/reports of missing native Windows Arm64 support or distributions can qualify. Crashes, regressions and ordinary build failures in existing support are not porting candidates.'
        'A recommendation also requires a reviewed official distribution-channel profile, completed channel evidence showing the reported gap, and no advertised native or portable distribution. Unknown, unconfigured, truncated and uninspected support stays ineligible.'
        'The tracked distribution-channel catalog identifies official GitHub, PyPI and npm channels; package names are never guessed. Unreviewed repositories remain visible but cannot become recommendations until their channels are reviewed.'
        'Up to two anonymous registry GETs per repository inspect current PyPI/npm metadata, at most 16 MiB/30 seconds each; no redirects, credentials, package downloads, installs or execution. PyPI considers at most 500 current-release files; npm at most 100 optional dependencies.'
        'Registry platform tags and GitHub asset names are advertised availability, not native execution proof. Existing native advertisements exclude porting candidates even if their binaries need separate bug investigation.'
        'Aliases, other languages, older matches beyond five, closed issues and undocumented support may be missed.'
        'No matching issue is not proof of support; an open issue is not proof of a reproduced failure or absent support.'
        'At most five authenticated read-only GraphQL queries, each at most 100 issues, check up to ten linked closing PRs and five repository PRs referencing each eligible issue number in their body (at most 500 issues total). Open or merged work is skipped; closed unmerged PRs alone do not disqualify an issue. No recommendation is emitted until every batch succeeds.'
        'PR body references are review leads, not proof that the PR fixes the issue. Existing open/merged referenced work prevents automatic duplicate repair; PRs without closing links or matching body references can still be missed.'
        'Missing authentication or a truncated linked-PR connection without a known active fix leaves an issue unverified and ineligible. GraphQL errors stop the scan; unlinked fixes still require human review.'
        'Before editing, review existing fixes and trace a reported application blocker to its owning dependency. A shared dependency should be repaired once, not patched separately in every caller.'
        'Only native Windows Arm64 support is an eligible repair goal. Emulation/fallback reports require review, not automatic remediation; native builds, 0xAA64 runtime binaries and an installed core workflow remain mandatory.'
        'Release scope is the latest published non-prerelease GitHub release and up to 100 assets returned with it, not all distribution channels or older releases.'
        'Missing releases/assets, filenames, unsupported formats and inspection limits do not prove missing Arm64 support.'
        'Filename hints are not verified architecture. PE headers identify individual EXE/DLL machine types, not working applications, signatures, complete integrity or native runtime compatibility.'
        'At most three assets per repository: EXE/DLL prefixes (64 KiB) or complete ZIPs (16 MiB). No archive paths are extracted; at most 512 entries and sixteen 64-KiB PE headers per ZIP.'
        'Downloads are anonymous HTTPS to GitHub/allowlisted release CDNs, at most three redirects, 30 seconds each, 128 MiB total and a 180-second release-phase budget; limit hits remain unverified.'
        'An x64 observation alone is not absence proof. Only a complete reviewed channel inventory plus an explicit missing-support report can form a provisional porting candidate; an older open request can still be stale.'
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
    $lines.Add("Selected discovery track: ``$(ConvertTo-MarkdownText $report.track)``. Budget: $($report.maxRepositories) distinct repositories total. Selected: $($report.requestedCount). Source shortfall: $($report.selectionShortfall). No lifetime-star threshold.")
    $lines.Add("Selection: **missing native support only**. Distribution channels assessed: $($report.distributionAssessedCount)/$($report.requestedCount). Existing-support bugs and unverified support are excluded.")
    $lines.Add("Upstream fix review: $($report.upstreamFixReview.status); issues assessed: $($report.upstreamFixReview.assessedCount)/$($report.upstreamFixReview.requestedCount).")
    foreach ($source in $report.sources) {
        $lines.Add("- $($source.track): $($source.method); status $($source.status); source $(ConvertTo-MarkdownText $source.location).")
        if ($source.track -eq 'trending') {
            foreach ($page in $source.pages) {
                $lines.Add("  Weekly page: $(ConvertTo-MarkdownText $page.uri); status $($page.status); returned $($page.availableCount); first-seen repositories $($page.uniqueAddedCount).")
            }
        }
    }
    if ($report.error) { $lines.Add("Error: $(ConvertTo-MarkdownText $report.error)") }
    $lines.Add('')
    foreach ($candidate in $report.recommendations) {
        $lines.Add("$($candidate.track) recommendation (provisional): [$($candidate.fullName)]($($candidate.repositoryUrl)).")
        $lines.Add("Reported work: [$(ConvertTo-MarkdownText $candidate.issueTitle)]($($candidate.issueUrl)).")
        $lines.Add("Release evidence: $($candidate.releaseEvidence). Next investigation: $($candidate.workKind).")
        $lines.Add('Verify that native support is still missing on Windows Arm64 before selecting a build target or making changes.')
    }
    if ($report.status -eq 'completed') {
        foreach ($source in $report.sources) {
            if (-not @($report.recommendations | Where-Object track -eq $source.track).Count) {
                $lines.Add("No evidence-backed candidate found for $($source.track) within this bounded scan.")
            }
        }
    } else { $lines.Add('No recommendations: discovery has not completed successfully.') }
    $lines.Add('')
    $lines.Add('| Source ranks | Repository | Lifetime stars | Weekly stars | Language | Issue assessment | Open matches / inspected | Native support selection |')
    $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($repository in $report.repositories) {
        $ranks = ($repository.tracks | ForEach-Object { "$_ #$($repository.sourceRanks[$_])" }) -join ', '
        $lines.Add("| $ranks | [$($repository.fullName)]($($repository.url)) | $($repository.stars) | $($repository.weeklyStars) | $(ConvertTo-MarkdownText $repository.language) | $($repository.assessment) | $($repository.matchingIssueCount) / $($repository.issues.Count) | $($repository.nativeSupport.status) |")
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
            $lines.Add("  Upstream fix review: $($issue.upstreamFixReview.status); linked PRs truncated: $($issue.upstreamFixReview.truncated).")
            foreach ($pullRequest in $issue.upstreamFixReview.pullRequests) {
                $lines.Add("  Upstream work: [$($pullRequest.repository) #$($pullRequest.number)]($($pullRequest.url)) ($($pullRequest.state)); evidence: $($pullRequest.sources -join ', ').")
            }
        }
        if ($repository.evidenceTruncated) { $lines.Add("- $($repository.fullName): additional matching issues were not inspected.") }
    }
    $lines.Add('')
    $lines.Add('## Official distribution evidence')
    foreach ($repository in $report.repositories) {
        $lines.Add("- $($repository.fullName): $($repository.nativeSupport.status) ($($repository.nativeSupport.reason)).")
        foreach ($channel in $repository.nativeSupport.channels) {
            $lines.Add("  $($channel.provider): $($channel.status); version $(ConvertTo-MarkdownText $channel.version); source $(ConvertTo-MarkdownText $channel.url).")
            foreach ($example in $channel.examples) { $lines.Add("  Advertised file/package: $(ConvertTo-MarkdownText $example)") }
        }
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

function Invoke-DiscoveryApi([string] $Uri, [hashtable] $Entry, [switch] $AllowNotFound, [string] $Query = '') {
    if ($Query -and ($Uri -cne 'https://api.github.com/graphql' -or
        -not $Query.StartsWith('query OpenArmUpstreamFixes {') -or $Query -match '\bmutation\b')) {
        throw 'Only the fixed read-only upstream fix query may use POST.'
    }
    $report.requests += $entry
    Save-Discovery
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'OpenArm-Repository-Discovery' }
    if ($token) { $headers.Authorization = "Bearer $token" }
    $status = 0
    $request = @{ Method = 'GET'; Uri = $Uri; Headers = $headers; TimeoutSec = 30
        MaximumRedirection = 0; SkipHttpErrorCheck = $true; StatusCodeVariable = 'status'; ErrorAction = 'Stop' }
    if ($Query) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $request.Body = @{ query = $Query; operationName = 'OpenArmUpstreamFixes' } | ConvertTo-Json -Compress
    }
    try {
        $response = Invoke-RestMethod @request
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
    if ($Title -match '(?i)\b(?:fails?|failing|failure|errors?|crash(?:es|ing)?|broken|regress\w*|slow|performance|incorrect)\b') {
        return 'existing_support_bug'
    }
    $distribution = '(?:support|binar(?:y|ies)|builds?|wheels?|packages?|installers?)'
    if ($Title -match "(?i)\b(?:add|implement|enable|provide|request)\b.{0,80}\b$distribution\b" -or
        $Title -match '(?i)\bport\b.{0,30}\b(?:to|for)\b' -or
        $Title -match "(?i)\b(?:missing|no|lack(?:s|ing)?)\b.{0,60}\b$distribution\b" -or
        $Title -match "(?i)\b$distribution\b.{0,60}\b(?:missing|unavailable|not available)\b" -or
        $Title -match '(?i)\b(?:windows[\s-]+(?:on[\s-]+)?(?:arm64|aarch64|arm)|(?:arm64|aarch64)[\s-]+windows)\b.{0,15}\b(?:is\s+)?(?:unsupported|not supported)\b') {
        return 'reported_missing_native_support'
    }
    'needs_review'
}

function Get-UpstreamFixEvidence {
    $targets = @(
        foreach ($repository in $report.repositories) {
            if ($repository.nativeSupport.status -ne 'missing_in_reviewed_channels') { continue }
            foreach ($issue in $repository.issues) {
                if ($issue.classification -eq 'reported_missing_native_support') {
                    @{ repository = $repository.fullName; issue = $issue }
                }
            }
        }
    )
    $review = $report.upstreamFixReview
    $review.requestedCount = $targets.Count
    if (-not $targets.Count) { $review.status = 'no_eligible_issues'; return }
    if ($targets.Count -gt 500) { throw 'Upstream fix review exceeded the issue bound.' }
    if (-not $token) {
        $review.status = 'unverified_no_auth'
        foreach ($target in $targets) { $target.issue.upstreamFixReview.status = 'unverified_no_auth' }
        return
    }
    $review.status = 'assessing'
    for ($offset = 0; $offset -lt $targets.Count; $offset += 100) {
        $batch = @($targets | Select-Object -Skip $offset -First 100)
        $fields = [Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $target = $batch[$i]
            if ($target.repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') {
                throw 'Invalid repository identity in upstream fix review.'
            }
            $owner, $name = $target.repository.Split('/')
            $fields.Add("c${i}: repository(owner: `"$owner`", name: `"$name`") { issue(number: $($target.issue.number)) { number url closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number url state merged repository { nameWithOwner } } pageInfo { hasNextPage } } } }")
            $target.issue.upstreamFixReview.referenceQuery = "repo:$($target.repository) is:pr $($target.issue.number) in:body sort:updated-desc"
            $fields.Add("s${i}: search(query: `"$($target.issue.upstreamFixReview.referenceQuery)`", type: ISSUE, first: 5) { issueCount nodes { ... on PullRequest { number url state merged repository { nameWithOwner } } } pageInfo { hasNextPage } }")
        }
        $response = Invoke-DiscoveryApi 'https://api.github.com/graphql' `
            @{ endpoint = 'upstream_fixes'; batch = [int]($offset / 100) + 1; issueCount = $batch.Count; httpStatus = $null } `
            -Query "query OpenArmUpstreamFixes { $($fields -join ' ') }"
        if (($response.PSObject.Properties['errors'] -and $null -ne $response.errors -and
                ($response.errors -isnot [array] -or $response.errors.Count)) -or
            -not $response.PSObject.Properties['data'] -or $null -eq $response.data) {
            throw 'GitHub upstream fix query returned errors or missing data; no candidate is verified.'
        }
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $target = $batch[$i]
            $alias = "c$i"
            if (-not $response.data.PSObject.Properties[$alias] -or $null -eq $response.data.$alias -or
                -not $response.data.$alias.PSObject.Properties['issue'] -or $null -eq $response.data.$alias.issue) {
                throw 'GitHub upstream fix query returned incomplete issue data.'
            }
            $issue = $response.data.$alias.issue
            if (($issue.number -isnot [int] -and $issue.number -isnot [long]) -or $issue.number -ne $target.issue.number -or
                $issue.url -cne $target.issue.url) { throw 'GitHub upstream fix query returned a mismatched issue.' }
            $connection = $issue.closedByPullRequestsReferences
            if ($null -eq $connection -or $connection.nodes -isnot [array] -or $connection.nodes.Count -gt 10 -or
                $null -eq $connection.pageInfo -or $connection.pageInfo.hasNextPage -isnot [bool] -or
                ($connection.pageInfo.hasNextPage -and $connection.nodes.Count -ne 10)) {
                throw 'GitHub upstream fix query returned an invalid linked-PR connection.'
            }
            $evidence = $target.issue.upstreamFixReview
            $searchAlias = "s$i"
            if (-not $response.data.PSObject.Properties[$searchAlias] -or $null -eq $response.data.$searchAlias) {
                throw 'GitHub upstream fix query returned missing PR reference search data.'
            }
            $search = $response.data.$searchAlias
            if (($search.issueCount -isnot [int] -and $search.issueCount -isnot [long]) -or $search.issueCount -lt 0 -or
                $search.nodes -isnot [array] -or $search.nodes.Count -ne [Math]::Min(5, $search.issueCount) -or
                $null -eq $search.pageInfo -or $search.pageInfo.hasNextPage -isnot [bool] -or
                $search.pageInfo.hasNextPage -ne ($search.issueCount -gt 5)) {
                throw 'GitHub upstream fix query returned an invalid PR reference search.'
            }
            $evidence.referenceMatchCount = $search.issueCount
            $seen = @{}
            $references = @(
                foreach ($node in $connection.nodes) { @{ node = $node; source = 'closing_link' } }
                foreach ($node in $search.nodes) { @{ node = $node; source = 'body_reference' } }
            )
            foreach ($reference in $references) {
                $pullRequest = $reference.node
                if ($null -eq $pullRequest -or ($pullRequest.number -isnot [int] -and $pullRequest.number -isnot [long]) -or
                    $pullRequest.number -lt 1 -or $pullRequest.number -gt [int]::MaxValue -or
                    $pullRequest.state -cnotin @('OPEN', 'CLOSED', 'MERGED') -or $pullRequest.merged -isnot [bool] -or
                    $pullRequest.merged -ne ($pullRequest.state -ceq 'MERGED') -or $null -eq $pullRequest.repository -or
                    $pullRequest.repository.nameWithOwner -isnot [string] -or
                    $pullRequest.repository.nameWithOwner -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$' -or
                    $pullRequest.url -cne "https://github.com/$($pullRequest.repository.nameWithOwner)/pull/$($pullRequest.number)" -or
                    ($reference.source -eq 'body_reference' -and $pullRequest.repository.nameWithOwner -ine $target.repository)) {
                    throw 'GitHub upstream fix query returned an invalid or duplicate linked PR.'
                }
                if ($seen.ContainsKey($pullRequest.url)) {
                    $existing = $seen[$pullRequest.url]
                    if ($existing.sources -contains $reference.source -or $existing.state -cne $pullRequest.state) {
                        throw 'GitHub upstream fix query returned duplicate or inconsistent PR evidence.'
                    }
                    $existing.sources += $reference.source
                    continue
                }
                $record = @{
                    number = $pullRequest.number; url = $pullRequest.url; state = $pullRequest.state
                    merged = $pullRequest.merged; repository = $pullRequest.repository.nameWithOwner
                    sources = @($reference.source)
                }
                $seen[$pullRequest.url] = $record
                $evidence.pullRequests += $record
            }
            $evidence.truncated = $connection.pageInfo.hasNextPage -or $search.pageInfo.hasNextPage
            $active = @($evidence.pullRequests | Where-Object state -cin @('OPEN', 'MERGED'))
            $evidence.status = if (@($active | Where-Object { $_.sources -contains 'closing_link' }).Count) {
                'existing_upstream_fix'
            } elseif ($active.Count) {
                'existing_upstream_work'
            } elseif ($evidence.truncated) { 'unverified_truncated' } else { 'no_active_linked_fix' }
            $review.assessedCount++
        }
        Save-Discovery
    }
    $review.status = 'completed'
}

function Get-DistributionEvidence([hashtable] $Catalog) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($repository in $report.repositories) {
        $support = $repository.nativeSupport
        $support.status = 'assessing'
        $github = Get-GitHubDistributionEvidence $repository.release
        $support.channels += $github
        $profile = $Catalog.repositories[$repository.fullName]
        $reviewed = @()
        foreach ($channel in $profile) {
            if ($channel.provider -eq 'github') { $reviewed += $github; continue }
            if ($clock.Elapsed.TotalSeconds -ge 180) { throw 'Distribution metadata phase exceeded its time budget; support remains unverified.' }
            $package = [uri]::EscapeDataString($channel.package)
            $uri = if ($channel.provider -eq 'pypi') { "https://pypi.org/pypi/$package/json" }
                else { "https://registry.npmjs.org/$package/latest" }
            $request = @{ endpoint = "$($channel.provider)_distribution"; repository = $repository.fullName
                uri = $uri; httpStatus = $null }
            $report.requests += $request
            Save-Discovery
            $metadata = Receive-DistributionMetadata -Uri $uri -Request $request
            $evidence = Get-RegistryDistributionEvidence $channel $metadata
            $evidence.url = $uri
            $support.channels += $evidence
            $reviewed += $evidence
        }
        if (@($support.channels | Where-Object status -eq 'native_advertised').Count) {
            $support.status = 'native_distribution_available'; $support.reason = 'already_publishes_or_advertises_windows_arm64'
        } elseif (@($reviewed | Where-Object status -eq 'portable_distribution').Count) {
            $support.status = 'not_a_native_port_candidate'; $support.reason = 'platform_independent_distribution'
        } elseif (-not $profile) {
            $support.status = 'unverified'; $support.reason = 'official_distribution_channels_not_reviewed'
        } elseif (@($reviewed | Where-Object status -ne 'missing_in_channel').Count -or $repository.release.artifactProblem) {
            $support.status = 'unverified'; $support.reason = 'channel_evidence_incomplete_or_artifact_bug'
        } else {
            $support.status = 'missing_in_reviewed_channels'; $support.reason = 'no_native_distribution_in_reviewed_channel_inventory'
        }
        $report.distributionAssessedCount++
        Save-Discovery
    }
}

$currentRepository = $null
try {
    if ($CreatePullRequest) {
        throw 'Discovery is read-only. Leave createForkPullRequest false; review a candidate and supply sourceRepositoryUrl in a separate run before creating a fork PR.'
    }
    if ($Track -cnotin @('both', 'trending', 'foundational')) { throw 'Select both, trending or foundational discovery.' }
    if ($MaxRepositories -lt 1 -or $MaxRepositories -gt 100) { throw 'The total repository budget must be between 1 and 100.' }
    $distributionCatalog = Read-DistributionChannels
    $report.distributionCatalogSha256 = $distributionCatalog.sha256
    Write-Host "Discovering $Track repositories using $($report.authMode) GitHub.com reads ($interval seconds between searches)."
    $seeds = [Collections.Generic.List[object]]::new()
    $selected = @{}; $sources = @{}; $foundationItems = @()
    $trendingItems = [Collections.Generic.List[object]]::new()
    $trendingSeen = @{}
    foreach ($sourceTrack in @('trending', 'foundational')) {
        if ($Track -ne 'both' -and $Track -ne $sourceTrack) { continue }
        $source = @{ track = $sourceTrack; status = 'reading'; selectedCount = 0; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
            method = $(if ($sourceTrack -eq 'trending') { 'github_weekly_trending_pool' } else { 'reviewed_catalog_order' })
            location = $(if ($sourceTrack -eq 'trending') { 'https://github.com/trending?since=weekly' } else { 'targets\discovery\foundational.json' }) }
        if ($sourceTrack -eq 'trending') { $source.pages = @() }
        $sources[$sourceTrack] = $source
        $report.sources += $source
    }
    Save-Discovery
    if ($sources.ContainsKey('foundational')) {
        $selection = Read-FoundationalRepositories
        $foundationItems = $selection.items
        $sources.foundational.catalogSha256 = $selection.catalogSha256
        $sources.foundational.availableCount = $foundationItems.Count
        $sources.foundational.status = 'completed'
        $reserve = if ($Track -eq 'both') { [int][Math]::Floor($MaxRepositories / 2) } else { $MaxRepositories }
        foreach ($item in ($foundationItems | Select-Object -First $reserve)) { $selected[$item.fullName] = $true }
    }
    if ($sources.ContainsKey('trending')) {
        $source = $sources.trending
        $source.availableCount = 0
        foreach ($language in @('', 'c', 'c++', 'rust', 'go', 'python', 'javascript', 'typescript', 'c#')) {
            if ($selected.Count -ge $MaxRepositories) { break }
            $uri = Get-GitHubTrendingUri $language
            $page = @{ uri = $uri; language = $language; status = 'reading'
                observedAt = [DateTimeOffset]::UtcNow.ToString('o'); availableCount = 0; uniqueAddedCount = 0; snapshotSha256 = $null }
            $source.pages += $page
            $request = @{ endpoint = 'weekly_trending'; uri = $uri; httpStatus = $null }
            $report.requests += $request
            Save-Discovery
            $html = Receive-GitHubTrending -Language $language
            $request.httpStatus = 200
            $selection = ConvertFrom-GitHubTrending $html
            $page.snapshotSha256 = $selection.snapshotSha256
            $page.availableCount = $selection.availableCount
            if (-not $language) { $source.snapshotSha256 = $selection.snapshotSha256 }
            foreach ($item in $selection.items) {
                if ($trendingSeen.ContainsKey($item.fullName)) { continue }
                $trendingSeen[$item.fullName] = $true
                $page.uniqueAddedCount++
                $trendingItems.Add(@{
                    fullName = $item.fullName; rank = $trendingItems.Count + 1; weeklyStars = $item.weeklyStars
                    evidence = @{ pageUrl = $uri; language = $language; pageRank = $item.rank }
                })
                if ($selected.Count -lt $MaxRepositories) { $selected[$item.fullName] = $true }
            }
            $source.availableCount = $trendingItems.Count
            $page.status = 'completed'
        }
        $source.status = 'completed'
    }
    foreach ($item in $foundationItems) {
        if ($selected.Count -ge $MaxRepositories) { break }
        $selected[$item.fullName] = $true
    }
    $seen = @{}
    foreach ($source in $report.sources) {
        $sourceTrack = $source.track
        $items = if ($sourceTrack -eq 'trending') { $trendingItems } else { $foundationItems }
        foreach ($item in $items) {
            if (-not $selected.ContainsKey($item.fullName)) { continue }
            if (-not $seen.ContainsKey($item.fullName)) {
                $seed = @{ fullName = $item.fullName; tracks = @(); sourceRanks = @{}; weeklyStars = $null
                    trendingEvidence = $null; foundationReason = $null; foundationCategory = $null }
                $seen[$item.fullName] = $seed
                $seeds.Add($seed)
            }
            $seed = $seen[$item.fullName]
            $seed.tracks += $sourceTrack; $seed.sourceRanks[$sourceTrack] = $item.rank
            if ($sourceTrack -eq 'trending') { $seed.weeklyStars = $item.weeklyStars; $seed.trendingEvidence = $item.evidence }
            else { $seed.foundationReason = $item.reason; $seed.foundationCategory = $item.category }
            $source.selectedCount++
        }
        Save-Discovery
    }
    $report.requestedCount = $seeds.Count
    $report.selectionShortfall = $MaxRepositories - $seeds.Count
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
            trendingEvidence = $seed.trendingEvidence
            foundationReason = $seed.foundationReason; foundationCategory = $seed.foundationCategory
            url = "https://github.com/$($repository.full_name)"; stars = $repository.stargazers_count
            language = $repository.language; defaultBranch = $repository.default_branch
            assessment = 'not_assessed'; matchingIssueCount = $null; evidenceTruncated = $false; issues = @()
            release = @{ status = 'not_assessed'; windowsArm64 = 'unknown'; url = $null }
            nativeSupport = @{ status = 'not_assessed'; reason = ''; channels = @() }
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
                ($issue.number -isnot [int] -and $issue.number -isnot [long]) -or $issue.number -lt 1 -or $issue.number -gt [int]::MaxValue -or
                $seenIssues.ContainsKey([string]$issue.number) -or $issue.title -isnot [string] -or -not $issue.title) {
                throw 'GitHub returned an invalid, duplicated or out-of-scope issue.'
            }
            $seenIssues[[string]$issue.number] = $true
            $title = $issue.title
            if ($token) { $title = $title.Replace($token, '[redacted]') }
            $classification = Get-IssueClassification $title
            $repository.issues += @{
                number = $issue.number; title = $title
                url = "https://github.com/$($repository.fullName)/issues/$($issue.number)"
                classification = $classification
                upstreamFixReview = @{
                    status = $(if ($classification -eq 'reported_missing_native_support') { 'not_assessed' } else { 'not_applicable' })
                    truncated = $false; pullRequests = @(); referenceQuery = $null; referenceMatchCount = $null
                }
            }
        }
        $repository.assessment = if (@($repository.issues | Where-Object classification -eq 'reported_missing_native_support').Count) {
            'reported_missing_native_support'
        } elseif (@($repository.issues | Where-Object classification -eq 'existing_support_bug').Count) {
            'existing_support_bug'
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
    Get-DistributionEvidence $distributionCatalog
    Get-UpstreamFixEvidence
    Save-Discovery
    foreach ($source in $report.sources) {
        $sourceTrack = $source.track
        $candidate = $report.repositories | Where-Object {
            $_.nativeSupport.status -eq 'missing_in_reviewed_channels' -and $_.tracks -contains $sourceTrack -and
            @($_.issues | Where-Object { $_.upstreamFixReview.status -eq 'no_active_linked_fix' }).Count
        } |
            Sort-Object { $_.sourceRanks[$sourceTrack] } | Select-Object -First 1
        if (-not $candidate) { continue }
        $issue = $candidate.issues | Where-Object { $_.upstreamFixReview.status -eq 'no_active_linked_fix' } | Select-Object -First 1
        $report.recommendations += @{
            track = $sourceTrack; sourceRank = $candidate.sourceRanks[$sourceTrack]; nativeGoal = 'native_windows_arm64'
            fullName = $candidate.fullName; repositoryUrl = $candidate.url; stars = $candidate.stars
            issueUrl = $issue.url; issueTitle = $issue.title; provisional = $true
            releaseEvidence = $candidate.release.windowsArm64
            releaseUrl = $candidate.release.url
            distributionEvidence = $candidate.nativeSupport.status
            workKind = 'investigate_missing_native_support'
        }
    }
    $report.status = 'completed'
} catch {
    $report.recommendations = @()
    if ($report.upstreamFixReview.status -eq 'assessing') { $report.upstreamFixReview.status = 'error' }
    foreach ($repository in $report.repositories) {
        if ($repository.nativeSupport.status -eq 'assessing') { $repository.nativeSupport.status = 'error' }
    }
    foreach ($source in $report.sources) {
        if ($source.status -eq 'reading') { $source.status = 'error' }
        if ($source.track -eq 'trending') {
            foreach ($page in $source.pages) { if ($page.status -eq 'reading') { $page.status = 'error' } }
        }
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
