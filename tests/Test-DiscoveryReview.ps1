Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\DiscoveryReview.ps1"
$root = Join-Path $repo ".local\discovery-review-$([guid]::NewGuid())"
$fixture = Join-Path $root 'fixture'
$null = New-Item -ItemType Directory -Path "$fixture\scripts", "$fixture\targets\discovery", "$root\input"
Copy-Item -LiteralPath "$repo\scripts\Common.ps1", "$repo\scripts\RepositorySources.ps1", "$repo\scripts\GitHubRepair.ps1",
    "$repo\scripts\DiscoveryReview.ps1", "$repo\scripts\Invoke-DiscoveryReview.ps1" -Destination "$fixture\scripts"
Copy-Item -LiteralPath "$repo\targets\discovery\review-focus.json" -Destination "$fixture\targets\discovery"
$saved = @{}
foreach ($name in 'OPENARM_GITHUB_DISCOVERY_TOKEN', 'GITHUB_TOKEN', 'GITHUB_RUN_ID', 'GITHUB_SHA', 'GITHUB_ACTIONS', 'OPENARM_DISCOVERY_FOCUS') {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message.Length -gt 0 -and $message -like $Pattern) "Expected '$Pattern', got '$message'"
}
function New-CollectedRepository([int] $Number) {
    @{
        fullName = "owner/repo$Number"; defaultBranch = 'main'; tracks = @('trending'); sourceRanks = @{ trending = $Number }
        nativeSupport = @{ status = 'unverified'; channels = @() }; matchingIssueCount = 0; evidenceTruncated = $false; issues = @()
        release = @{ status = 'no_published_release'; tag = ''; url = $null; assets = @(); windowsArm64 = 'unknown'
            returnedAssetCount = 0; metadataTruncated = $false; notesEvidence = Get-RepositoryExcerpt '' }
    }
}
function Reset-Mock {
    $env:OPENARM_GITHUB_DISCOVERY_TOKEN = 'offline-discovery-value'
    $env:GITHUB_TOKEN = 'offline-agent-value'
    $env:GITHUB_RUN_ID = '101'; $env:GITHUB_SHA = 'a' * 40; $env:GITHUB_ACTIONS = 'true'; $env:OPENARM_DISCOVERY_FOCUS = 'none'
    $global:ReviewMock = @{
        calls = @(); agentCalls = @(); failAt = 0; agentFailAt = 0; fileError = ''; prError = ''
        prNodes = @{}; issueComments = @{}
        stageText = 'The get-windows package has no Windows ARM64 prebuilt; preserve the desktop build and disable window enumeration.'
        dependencyAsset = 'napi-9-win32-unknown-x64.tar.gz'
    }
    $repositories = @(1..100 | ForEach-Object { New-CollectedRepository $_ })
    Write-Json "$root\input\discovery.json" @{
        schemaVersion = 4; status = 'completed'; requestedCount = 100; assessedCount = 100
        releaseAssessedCount = 100; distributionAssessedCount = 100; repositories = $repositories
    }
}
function global:Start-Sleep { param($Seconds) }
function New-DiscussionConnection([array] $Nodes = @(), [int] $Total = -1) {
    if ($Total -lt 0) { $Total = $Nodes.Count }
    @{ totalCount = $Total; filteredCount = $Total; nodes = $Nodes; pageInfo = @{ hasPreviousPage = ($Total -gt $Nodes.Count) } }
}
function global:Invoke-RestMethod {
    param($Uri, $Headers, $Method, $TimeoutSec, $MaximumRedirection, [switch] $SkipHttpErrorCheck, $StatusCodeVariable,
        $ErrorAction, $ContentType, $Body)
    $m = $global:ReviewMock
    if (([uri]$Uri).Host -cne 'api.github.com' -or $TimeoutSec -ne 30 -or $MaximumRedirection -ne 0 -or
        $Headers.Authorization -cne 'Bearer offline-discovery-value') { throw 'Unexpected review network or credential boundary.' }
    $m.calls += @{ uri = $Uri; method = $Method }
    $status = if ($m.calls.Count -eq $m.failAt) { 429 } else { 200 }
    Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    if ($status -ne 200) { return [pscustomobject]@{ message = 'offline-discovery-value' } }
    $url = [uri]$Uri
    if ($Method -ceq 'POST') {
        $payload = $Body | ConvertFrom-Json
        if ($url.AbsolutePath -cne '/graphql' -or $ContentType -cne 'application/json' -or
            $payload.operationName -cne 'OpenArmDiscoveryReview' -or $payload.query -match '\bmutation\b') { throw 'Unexpected GraphQL write.' }
        $data = @{}
        $queries = [regex]::Matches($payload.query, 'r(\d+): search\(query: ("(?:[^"\\]|\\.)*")')
        if ($queries.Count -lt 1 -or $queries.Count -gt 10) { throw 'Unexpected GraphQL batch size.' }
        foreach ($query in $queries) {
            $text = $query.Groups[2].Value | ConvertFrom-Json
            $name = [regex]::Match($text, '^repo:([^ ]+) ').Groups[1].Value
            $nodes = @()
            if ($name -eq 'NousResearch/hermes-agent') {
                $nodes += @{ number = 7; url = "https://github.com/$name/pull/7"; title = 'Keep desktop packaging working'
                    body = $m.stageText; state = 'MERGED'; merged = $true; repository = @{ nameWithOwner = $name }
                    author = @{ login = 'maintainer' }; closedAt = '2026-06-17T20:44:43Z'
                    comments = New-DiscussionConnection; reviews = New-DiscussionConnection; timelineItems = New-DiscussionConnection }
            }
            if ($m.prNodes.ContainsKey($name)) { $nodes = @($m.prNodes[$name]) }
            $data['r' + $query.Groups[1].Value] = @{ issueCount = $nodes.Count; nodes = $nodes; pageInfo = @{ hasNextPage = $false } }
            $index = [int]$query.Groups[1].Value
            $start = $payload.query.IndexOf("d${index}: repository(")
            if ($start -ge 0) {
                $end = $payload.query.IndexOf("r$($index + 1): search", $start)
                if ($end -lt 0) { $end = $payload.query.Length }
                $discussion = @{ nameWithOwner = $name }
                foreach ($entry in [regex]::Matches($payload.query.Substring($start, $end - $start), 'i(\d+): issue\(number: ([1-9][0-9]*)\)')) {
                    $number = [int]$entry.Groups[2].Value
                    $key = "$name/$number"
                    $comments = if ($m.issueComments.ContainsKey($key)) { $m.issueComments[$key] } else { New-DiscussionConnection }
                    $discussion['i' + $entry.Groups[1].Value] = @{ number = $number; url = "https://github.com/$name/issues/$number"
                        state = 'OPEN'; comments = $comments }
                }
                $data["d$index"] = $discussion
            }
        }
        if ($m.prError -eq 'missing') { $data.Remove('r0') }
        $response = @{ data = $data }
        if ($m.prError -eq 'errors') { $response.errors = @(@{ message = 'bad response' }) }
        return $response | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    }
    if ($Method -cne 'GET') { throw 'Only public reads are allowed.' }
    if ($url.AbsolutePath -eq '/search/issues') {
        return [pscustomobject]@{ total_count = 0; incomplete_results = $false; items = @() }
    }
    if ($url.AbsolutePath -match '^/repos/([^/]+/[^/]+)$') {
        return [pscustomobject]@{ full_name = $Matches[1]; default_branch = 'main'; private = $false; archived = $false; fork = $false }
    }
    if ($url.AbsolutePath -match '^/repos/([^/]+/[^/]+)/releases/latest$') {
        $asset = if ($Matches[1] -eq 'NousResearch/hermes-agent') { 'desktop-win32-arm64.exe' } else { $m.dependencyAsset }
        return [pscustomobject]@{ tag_name = 'v9.3.0'; draft = $false; prerelease = $false; body = 'Current stable distribution.'
            assets = @([pscustomobject]@{ name = $asset }) }
    }
    if ($url.AbsolutePath -match '^/repos/([^/]+/[^/]+)/(readme|contents/(.+))$') {
        $path = if ($Matches[2] -eq 'readme') { 'README.md' } else { $Matches[3] }
        $text = if ($path -like '*stage-native-deps.mjs') { $m.stageText } elseif ($path -like '*package.json') {
            '{"optionalDependencies":{"get-windows":"9.3.0"},"repository":"sindresorhus/get-windows"}'
        } else { 'This README describes the project. It does not establish native Windows ARM64 support.' }
        if ($m.fileError -eq '404') {
            Set-Variable -Name $StatusCodeVariable -Value 404 -Scope 1
            return [pscustomobject]@{ message = 'Not Found' }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $response = @{ type = 'file'; encoding = 'base64'; size = $bytes.Length; path = $path; sha = 'b' * 40
            content = [Convert]::ToBase64String($bytes) }
        switch ($m.fileError) {
            'size' { $response.size++ }
            'oversized' { $response.size = 1MB + 1 }
            'base64' { $response.content = 'not base64' }
        }
        return [pscustomobject]$response
    }
    throw "Unexpected evidence route: $($url.AbsolutePath)"
}
function New-Assessment([hashtable] $Repository) {
    $item = @{
        fullName = $Repository.fullName; assessment = 'unknown'; scope = 'project'; dependency = $null
        upstreamDisposition = 'unknown'; reason = 'The supplied public evidence does not establish a native gap.'
        blockerKind = 'unknown'; blockerCitation = $null; closedPrDisposition = 'none'
        reviewedSurfaces = @('readme', 'issues', 'pull_requests', 'releases'); citations = @()
    }
    if ($Repository.fullName -eq 'NousResearch/hermes-agent') {
        $item.assessment = 'reported_missing_native_support'; $item.scope = 'dependency'
        $item.dependency = @{ name = 'get-windows'; repository = 'sindresorhus/get-windows' }
        $item.upstreamDisposition = 'workaround_only'
        $item.blockerKind = 'native_dependency_gap'
        $item.reason = 'The native desktop package disables window enumeration when its dependency is absent; this is not a native feature fix.'
        $source = $Repository.documents | Where-Object { $_.id -like '*stage-native-deps.mjs' } | Select-Object -First 1
        $release = $Repository.dependency.documents | Where-Object kind -eq 'release' | Select-Object -First 1
        $item.blockerCitation = @{ sourceId = $source.id; passage = 1 }
        $item.citations = @(
            @{ sourceId = $source.id; passage = 1 },
            @{ sourceId = $release.id; passage = 1 }
        )
    }
    $item
}
function New-AzaharReview {
    $name = 'azahar-emu/azahar'
    $url = "https://github.com/$name/pull/2062"
    $closing = "For now, we've decided not to pursue this. We would like to be able to make use of the MXE build environment to provide builds, as our MSYS2 builds are deprecated and MSVC is proprietary and has proven itself to be unreliable, however MXE doesn't yet support Windows for ARM.`r`n`r`nI will be closing this for now, but hopefully we can support Windows for ARM in the future."
    $global:ReviewMock.prNodes[$name] = @(@{
        number = 2062; url = $url; title = 'Windows ARM64'; body = 'Native Windows ARM64 build proposal.'
        state = 'CLOSED'; merged = $false; repository = @{ nameWithOwner = $name }
        author = @{ login = 'talynone' }; closedAt = '2026-06-17T20:44:43Z'
        comments = New-DiscussionConnection @(
            @{ url = "$url#issuecomment-1"; body = 'Verification required; closing automatically.'
                author = @{ login = 'verification[bot]' }; authorAssociation = 'NONE'
                createdAt = '2026-04-25T00:00:00Z'; updatedAt = '2026-04-25T00:00:00Z' },
            @{ url = "$url#issuecomment-4735193886"; body = $closing
                author = @{ login = 'OpenSauce04' }; authorAssociation = 'MEMBER'
                createdAt = '2026-06-17T20:44:43Z'; updatedAt = '2026-06-17T20:44:43Z' })
        reviews = New-DiscussionConnection
        timelineItems = New-DiscussionConnection @(
            @{ __typename = 'ReopenedEvent'; createdAt = '2026-04-25T01:00:00Z'; actor = @{ login = 'talynone' } },
            @{ __typename = 'ClosedEvent'; createdAt = '2026-06-17T20:44:43Z'; actor = @{ login = 'OpenSauce04' } }) 3
    })
    $global:ReviewMock.prNodes[$name][0].timelineItems.totalCount = 18
    $collected = New-CollectedRepository 1
    $collected.fullName = $name
    $repository = New-ReviewRepository $collected
    $repository.documents += New-ReviewDocument $name 'readme' 'readme' "https://github.com/$name" `
        'Windows ARM64 release builds are not available.'
    Add-ReviewPullRequests @($repository) @{ requests = @() }
    $repository
}
function New-GapAssessment([hashtable] $Repository) {
    $answer = New-Assessment $Repository
    $answer.assessment = 'reported_missing_native_support'
    $answer.upstreamDisposition = 'no_native_fix_identified'
    $answer.blockerKind = 'upstream_prerequisite'
    $answer.closedPrDisposition = 'maintainer_deferred'
    $answer.reason = 'The maintainer deferred distribution pending the preferred MXE toolchain, not a demonstrated impossibility of native builds.'
    $answer.citations = @(
        @{ sourceId = "$($Repository.fullName)/readme"; passage = 1 },
        @{ sourceId = "$($Repository.fullName)/release"; passage = 1 })
    $answer.blockerCitation = @{ sourceId = "$($Repository.fullName)/pr-2062-issuecomment-4735193886"; passage = 1 }
    $answer
}
function Read-Assessment([hashtable] $Answer, [hashtable] $Repository) {
    @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($Answer) } | ConvertTo-Json -Depth 12) @($Repository))[0]
}
function global:Mock-ReviewCopilot {
    param($Prompt, $WorkingDirectory, $Log, $EditableFiles, [switch] $PromptOnStdin, $TimeoutSeconds, $UsageFile)
    $m = $global:ReviewMock
    if (-not $PromptOnStdin -or $TimeoutSeconds -ne 180 -or $EditableFiles -or
        $Prompt -notlike '*Do not use tools*') { throw 'Unexpected paid-review boundary.' }
    $data = [regex]::Match($Prompt, '(?s)\r?\nDATA:\r?\n(.*)$').Groups[1].Value | ConvertFrom-Json -AsHashtable
    $repositories = @($data)
    if ($repositories.Count -lt 1 -or $repositories.Count -gt 10) { throw 'Unexpected CLI input shape.' }
    $m.agentCalls += @{ count = $repositories.Count; names = @($repositories.fullName); prompt = $Prompt }
    if ($m.agentCalls.Count -eq $m.agentFailAt) { throw 'Offline simulated Copilot request failure; no retry.' }
    Write-Json $UsageFile @{ input_tokens = 10000; output_tokens = 500; model = 'offline-fixture' }
    Write-Json $Log @{ schemaVersion = 3; repositories = @($repositories | ForEach-Object { New-Assessment $_ }) }
}
Set-Alias -Name Invoke-RepairCopilot -Value Mock-ReviewCopilot -Scope Global
function Run-Review([string] $Name, [string] $Phase, [string] $InputDirectory = "$root\input", [string] $Focus = 'none') {
    $output = Join-Path $root $Name
    $errorText = ''
    try { & "$fixture\scripts\Invoke-DiscoveryReview.ps1" -Phase $Phase -InputPath $InputDirectory -Output $output -OutputRoot $root -Focus $Focus }
    catch { $errorText = $_.Exception.Message }
    @{ error = $errorText; output = $output; report = Read-Json "$output\report.json" }
}
try {
    Reset-Mock
    Assert ((Read-DiscoveryFocus 'none') -eq $null) 'No focus does not add an unranked project'
    Assert ((Read-DiscoveryFocus 'hermes-get-windows').dependency.repository -eq 'sindresorhus/get-windows') 'The focus identifies the real upstream dependency'
    Assert-Throws { Read-DiscoveryFocus '../arbitrary' } '*tracked*'
    Assert-Throws { Invoke-ReviewApi 'https://evil.invalid/repos/owner/repo' @{ requests = @() } } '*fixed public GitHub reads*'
    Assert-Throws { Get-ReviewFile @{ fullName = 'owner/repo'; defaultBranch = 'main' } @{ requests = @() } '../file.md' } '*reviewed source text*'
    $excerpt = Get-RepositoryExcerpt (('prefix ' * 1000) + 'Windows ARM64 native wheels are missing.' + (' tail' * 1000)) 2000
    Assert ($excerpt.truncated -and $excerpt.text.Length -le 2000 -and $excerpt.text -like '*Windows ARM64*' -and
        $excerpt.sha256 -match '^[a-f0-9]{64}$') 'Architecture excerpts preserve a bounded, hash-linked source statement'
    $formatted = '**Windows / missing binding self-heal:** `native.node` requires a native Windows ARM64 prebuild.'
    $passages = @(Get-ReviewPassages $formatted)
    Assert ($passages.Count -eq 1 -and $passages[0].number -eq 1 -and $passages[0].text -ceq $formatted) 'Numbered source passages retain Markdown syntax rather than asking the model to regenerate a quote'
    $unicodeText = ('x' * 499) + [char]::ConvertFromUtf32(0x1F680) + ('y' * 600)
    $passages = @(Get-ReviewPassages $unicodeText)
    Assert (@($passages | Where-Object { -not $unicodeText.Contains($_.text) -or $_.text.Length -gt 500 }).Count -eq 0) 'Passages are bounded contiguous source slices'
    foreach ($passage in $passages) { $null = [Text.UTF8Encoding]::new($false, $true).GetBytes($passage.text) }
    Assert ($passages.Count -eq 3) 'Passage boundaries preserve Unicode surrogate pairs'
    $prepared = Run-Review 'prepared-100' 'Prepare'
    Assert (-not $prepared.error -and $prepared.report.status -eq 'prepared' -and $prepared.report.requestedCount -eq 100 -and
        $prepared.report.assessedCount -eq 100 -and $global:ReviewMock.calls.Count -eq 110) "All 100 get README and PR content, even without issues or reviewed distributions: $($prepared.error)"
    $context = Read-Json "$($prepared.output)\context.json"
    Assert ($context.repositories.Count -eq 100 -and @($context.repositories.fullName | Sort-Object -Unique).Count -eq 100 -and
        @($context.repositories | Where-Object { $_.coverage.pullRequestMatches -ne 0 -or $_.documents.Count -ne 2 }).Count -eq 0) 'The prepared corpus covers every unique ranked repository with explicit empty-search evidence'
    $reviewed = Run-Review 'reviewed-100' 'Agent' $prepared.output
    Assert (-not $reviewed.error -and $reviewed.report.status -eq 'completed' -and $reviewed.report.assessedCount -eq 100 -and
        $reviewed.report.authVerified -and $global:ReviewMock.agentCalls.Count -eq 10) "Ten real-shaped CLI invocations review all hundred, not only heuristic candidates: $($reviewed.error)"
    Assert ($reviewed.report.recommendations.Count -eq 0 -and $reviewed.report.nativeVerified -eq $false -and
        @($reviewed.report.batches | Where-Object { $_.status -ne 'completed' -or $_.promptSha256 -notmatch '^[a-f0-9]{64}$' -or
            $_.usageSha256 -notmatch '^[a-f0-9]{64}$' }).Count -eq 0) 'Unknown evidence stays ineligible and exact prompts/usage receipts remain durable'

    Reset-Mock
    $focusPrepared = Run-Review 'prepared-focus' 'Prepare' "$root\input" 'hermes-get-windows'
    Assert (-not $focusPrepared.error -and $focusPrepared.report.rankedCount -eq 100 -and $focusPrepared.report.requestedCount -eq 101 -and
        $global:ReviewMock.calls.Count -eq 122) "Hermes and one upstream dependency are a bounded additional reference check: $($focusPrepared.error)"
    $focusContext = Read-Json "$($focusPrepared.output)\context.json"
    $hermes = $focusContext.repositories | Where-Object fullName -eq 'NousResearch/hermes-agent' | Select-Object -First 1
    Assert ($hermes.scope -eq 'focus' -and $hermes.tracks.Count -eq 0 -and $hermes.nativeSupport -eq 'native_distribution_available' -and
        $hermes.dependency.fullName -eq 'sindresorhus/get-windows' -and
        ($hermes.documents | Where-Object kind -eq 'pull_request').details.state -eq 'MERGED') 'A native parent package does not erase the dependency, and merged workaround bodies are preserved'
    $promptRepository = Get-ReviewPromptRepository $hermes
    $promptDocuments = @($promptRepository.documents) + @($promptRepository.dependency.documents)
    Assert (@($promptDocuments | Where-Object { $_.passageCount -ne $_.passages.Count -or
        @($_.passages | Where-Object number -lt 1).Count }).Count -eq 0) 'Every root and dependency document explicitly supplies its own citation range'
    $focusReview = Run-Review 'reviewed-focus' 'Agent' $focusPrepared.output
    Assert (-not $focusReview.error -and $focusReview.report.assessedCount -eq 101 -and
        $global:ReviewMock.agentCalls.Count -eq 11 -and $global:ReviewMock.agentCalls[0].count -eq 1) "The named focus receives priority content review without changing the ranked 100: $($focusReview.error)"
    $finding = $focusReview.report.focusFindings[0]
    Assert ($finding.assessment -eq 'reported_missing_native_support' -and $finding.scope -eq 'dependency' -and $finding.eligible -and
        $finding.upstreamDisposition -eq 'workaround_only' -and $finding.citations.Count -eq 2 -and
        $focusReview.report.recommendations.Count -eq 0) 'Disabling window enumeration is a reported native dependency gap, not an invented ranked candidate or a native fix'
    Assert ($global:ReviewMock.agentCalls[-1].prompt -notlike '*Focus question (if any): Does Hermes*' -and
        $global:ReviewMock.agentCalls[0].prompt -like '*Focus question (if any): Does Hermes*') 'The special focus does not bias unrelated repository batches'
    $focusPrompt = $global:ReviewMock.agentCalls[0].prompt
    $requestedNames = @([regex]::Match($focusPrompt, '(?m)^REQUESTED_REPOSITORIES: (.+)$').Groups[1].Value | ConvertFrom-Json)
    Assert (@($requestedNames).Count -eq 1 -and $requestedNames[0] -ceq 'NousResearch/hermes-agent' -and
        $focusPrompt -like '*do NOT return extra entries for nested dependencies*') 'The focus prompt explicitly requests only its root, while retaining upstream dependency evidence'
    $normalNames = [regex]::Match($global:ReviewMock.agentCalls[-1].prompt, '(?m)^REQUESTED_REPOSITORIES: (.+)$').Groups[1].Value | ConvertFrom-Json
    Assert (@($normalNames).Count -eq 10 -and
        (@($normalNames | Sort-Object) -join ',') -ceq (@($global:ReviewMock.agentCalls[-1].names | Sort-Object) -join ',')) 'Every ranked batch names its exact output repository set independently of nested context'
    $extraDependency = New-Assessment $hermes.dependency
    Assert-Throws { ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @((New-Assessment $hermes), $extraDependency) } | ConvertTo-Json -Depth 12) @($hermes) } '*exact requested repository set*'
    $markdown = Get-Content "$($focusReview.output)\copilot-review.md" -Raw
    Assert ($markdown -like '*sindresorhus/get-windows*' -and $markdown -like '*window enumeration*' -and $markdown -like '*native Windows Arm64*') 'Final readable evidence explains the dependency instead of reporting a false empty success'

    foreach ($case in 'active_native_fix', 'merged_native_fix', 'unknown') {
        $answer = New-Assessment $hermes
        $answer.upstreamDisposition = $case
        $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
        Assert (-not $result[0].eligible) "Incomplete or existing native fixes cannot become a duplicate recommendation: $case"
    }
    $answer = New-Assessment $hermes
    $answer.scope = 'project'; $answer.dependency = $null
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'project_already_advertises_native_distribution') 'Already-native project distribution cannot be recommended as a new project port'
    $hermes.nativeSupport = 'not_a_native_port_candidate'
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'platform_independent_project_distribution') 'Portable distributions are not mistaken for projects needing a native port'
    $hermes.nativeSupport = 'native_distribution_available'
    $hermes.dependency.nativeSupport = 'native_distribution_available'
    $answer = New-Assessment $hermes
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'dependency_already_advertises_native_distribution') 'A stale application comment cannot hide an already-published native dependency'
    $hermes.dependency.nativeSupport = 'unverified'
    $hermes.dependency.coverage.pullRequestsTruncated = $true
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'upstream_work_not_fully_assessed') 'Incomplete dependency PR evidence also prevents duplicate recommendations'
    $hermes.dependency.coverage.pullRequestsTruncated = $false
    $hermes.coverage.pullRequestsTruncated = $true
    $answer = New-Assessment $hermes
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'upstream_work_not_fully_assessed') 'A reported dependency gap with truncated upstream evidence remains a follow-up, not an automatic repair'
    $hermes.coverage.pullRequestsTruncated = $false
    $answer = New-Assessment $hermes
    $answer.citations[0].quote = 'A model-generated paraphrase must never replace the actual source.'
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].citations[0].quote -ceq $global:ReviewMock.stageText) 'Only the selected original passage, never model-generated quote text, enters the report'
    $answer = New-Assessment $hermes
    $answer.citations = @($answer.citations[0])
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].assessment -eq 'reported_missing_native_support' -and $result[0].evidenceStatus -eq 'uncorroborated_report' -and
        -not $result[0].eligible -and $result[0].reviewWarning) 'A genuine one-source report is retained as explicitly unconfirmed without aborting unrelated reviews'
    $answer = New-Assessment $hermes
    $answer.citations = @($answer.citations[1])
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].assessment -eq 'unknown' -and $result[0].evidenceStatus -eq 'no_explicit_gap_citation' -and
        -not $result[0].eligible -and $result[0].modelAssessment -eq 'reported_missing_native_support' -and
        $result[0].reviewWarning) 'A model-labelled gap without an explicit source statement is visibly rejected, not silently promoted'
    $answer = New-Assessment $hermes
    $answer.scope = 'feature'
    $answer.dependency.name = 'get-windows window enumeration'
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].dependency.name -ceq 'get-windows window enumeration' -and
        $result[0].dependency.repository -ceq 'sindresorhus/get-windows' -and $result[0].eligible) 'A bounded component display name is not incorrectly rejected as a package-manager identifier'
    $source = $hermes.documents | Where-Object { $_.id -like '*stage-native-deps.mjs' } | Select-Object -First 1
    $originalContent = $source.content
    $source.content = Get-RepositoryExcerpt "Four independent reviews: no blockers.`nWindows ARM64 runtime verification (archive verified; runtime tested on x64)."
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 3; repositories = @((New-Assessment $hermes)) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].assessment -eq 'unknown' -and $result[0].evidenceStatus -eq 'no_explicit_gap_citation' -and
        -not $result[0].eligible) 'An unrelated no-blockers sentence cannot turn an unverified ARM64 runtime checklist into a missing-support recommendation'
    $source.content = $originalContent
    foreach ($case in 'passage', 'passage-type', 'foreign-source', 'owner', 'missing-surface', 'duplicate', 'wrong-repository', 'missing-repository',
        'blank-dependency', 'long-dependency', 'control-dependency', 'wrong-dependency-type') {
        $answer = New-Assessment $hermes
        $payload = @{ schemaVersion = 3; repositories = @($answer) }
        switch ($case) {
            'passage' { $answer.citations[0].passage = 9999 }
            'passage-type' { $answer.citations[0].passage = '1' }
            'foreign-source' { $answer.citations[0].sourceId = 'other/project/issue-1' }
            'owner' { $answer.dependency.repository = 'unrelated/owner' }
            'missing-surface' { $answer.reviewedSurfaces = @('readme') }
            'duplicate' { $payload.repositories += $answer }
            'wrong-repository' { $answer.fullName = 'other/project' }
            'missing-repository' { $payload.repositories = @() }
            'blank-dependency' { $answer.dependency.name = ' ' }
            'long-dependency' { $answer.dependency.name = 'x' * 152 }
            'control-dependency' { $answer.dependency.name = "package`ncommand" }
            'wrong-dependency-type' { $answer.dependency.name = @('package') }
        }
        Assert-Throws { ConvertFrom-DiscoveryReview ($payload | ConvertTo-Json -Depth 12) @($hermes) } '*'
    }
    Assert-Throws { ConvertFrom-DiscoveryReview 'not JSON' @($hermes) } '*valid review JSON*'
    Assert-Throws { Get-DiscoveryReviewPrompt (@($hermes) * 11) } '*ten repositories*'
    foreach ($kind in 'unknown', 'not_applicable', 'source_gap', 'upstream_prerequisite', 'maintainer_policy') {
        $answer = New-Assessment $hermes
        $answer.blockerKind = $kind; $answer.blockerCitation = $null
        $result = Read-Assessment $answer $hermes
        Assert (-not $result.eligible -and $result.eligibilityReason -eq 'missing_support_reason_not_established') "Uncited $kind cannot establish an underlying cause or maintainer decision"
    }

    Reset-Mock
    $azahar = New-AzaharReview
    $pr = $azahar.documents | Where-Object kind -eq 'pull_request'
    $closing = $azahar.documents | Where-Object id -like '*4735193886'
    Assert ($global:ReviewMock.calls.Count -eq 1 -and $azahar.coverage.discussionEvidenceComplete -and
        $pr.details.closedBy -ceq 'OpenSauce04' -and $pr.details.author -ceq 'talynone' -and
        $pr.details.closureHistory[0].__typename -eq 'ReopenedEvent' -and
        $closing.details.authorAssociation -eq 'MEMBER' -and $closing.content.text -like '*MXE*') 'The real closing explanation and final actor survive the earlier reopened bot closure without additional HTTP reads'
    $promptRepository = Get-ReviewPromptRepository $azahar
    $prompt = Get-DiscoveryReviewPrompt @($azahar)
    Assert ($promptRepository.closedPullRequestIds -contains 'azahar-emu/azahar/pr-2062' -and
        $prompt -like '*Closed/unmerged does NOT mean available work*' -and
        $prompt -like '*OpenSauce04*' -and $prompt -like '*MXE*' -and $prompt -like '*upstream_prerequisite*') 'Copilot receives explicit closed PR identities, authority and the actual cause, not only a better instruction'
    Assert ($prompt -like '*compact JSON without indentation*' -and $prompt -like '*40-80 words*' -and
        $prompt -like '*final closure decisions and material uncertainty*') 'Bounded concise explanations preserve cause and maintainer intent without repeating the collected evidence'
    $answer = New-GapAssessment $azahar
    $result = Read-Assessment $answer $azahar
    Assert ($result.evidenceStatus -eq 'corroborated_report' -and $result.assessment -eq 'reported_missing_native_support' -and
        $result.rootCauseEvidenceStatus -eq 'cited' -and $result.closedPrReviewStatus -eq 'maintainer_deferred' -and
        -not $result.eligible -and $result.eligibilityReason -eq 'maintainer_or_prerequisite_blocks_repair' -and
        $result.blockerCitation.quote -ceq $closing.content.text) 'Azahar remains a visible native distribution gap but its cited MXE deferral cannot become automatic repair work'
    foreach ($case in 'author_withdrew', 'none', 'unknown') {
        $answer = New-GapAssessment $azahar
        $answer.blockerKind = 'source_gap'; $answer.closedPrDisposition = $case
        $result = Read-Assessment $answer $azahar
        Assert (-not $result.eligible -and $result.closedPrReviewStatus -eq 'unresolved') "A maintainer closure cannot be treated as available work by labelling it $case"
    }
    $answer = New-GapAssessment $azahar
    $answer.blockerCitation = $null
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.closedPrReviewStatus -eq 'unresolved' -and
        $result.rootCauseEvidenceStatus -eq 'unknown' -and $result.reviewWarning) 'An uncited closure and cause remain explicit unknown evidence'
    $answer = New-GapAssessment $azahar
    $answer.blockerCitation.sourceId = 'azahar-emu/azahar/pr-2062-issuecomment-1'
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.closedPrReviewStatus -eq 'unresolved') 'The earlier bot comment does not establish the final maintainer decision'
    $closing.details.author = 'talynone'; $closing.details.authorAssociation = 'CONTRIBUTOR'
    $closing.content = Get-RepositoryExcerpt 'I am withdrawing this Windows ARM64 patch because I lack time to finish the missing compiler configuration.'
    $pr.details.closedBy = 'talynone'
    $answer = New-GapAssessment $azahar
    $answer.blockerKind = 'source_gap'; $answer.closedPrDisposition = 'author_withdrew'
    $result = Read-Assessment $answer $azahar
    Assert ($result.eligible -and $result.closedPrReviewStatus -eq 'author_withdrew') 'An author-closed voluntary withdrawal with cited actionable cause and corroboration can remain provisional work'
    foreach ($case in 'unknown', 'mixed', 'superseded', 'maintainer_deferred', 'maintainer_declined') {
        $answer.closedPrDisposition = $case
        $result = Read-Assessment $answer $azahar
        Assert (-not $result.eligible) "Closed PR disposition $case cannot authorize repair"
    }
    $answer.closedPrDisposition = 'author_withdrew'
    $closing.details.parentId = 'azahar-emu/azahar/pr-99'
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.closedPrReviewStatus -eq 'unresolved') 'A discussion from another PR cannot explain this closure'
    $closing.details.parentId = $pr.id
    $otherPr = New-ReviewDocument $azahar.fullName 'pr-99' 'pull_request' 'https://github.com/azahar-emu/azahar/pull/99' 'Another closed proposal' `
        -Details @{ state = 'CLOSED'; author = 'talynone'; closedBy = 'talynone' }
    $azahar.documents += $otherPr
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.closedPrReviewStatus -eq 'unresolved') 'Each closed PR requires its own cited explanation; one withdrawal does not cover all closures'
    $azahar.documents = @($azahar.documents | Where-Object id -ne $otherPr.id)
    $azahar.dependency = $hermes.dependency
    $azahar.dependency.coverage.discussionEvidenceComplete = $false
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.eligibilityReason -eq 'discussion_evidence_incomplete') 'Incomplete dependency discussion also blocks automatic repair'
    $azahar.dependency = $null
    $azahar.coverage.discussionEvidenceComplete = $false
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.eligibilityReason -eq 'discussion_evidence_incomplete') 'Incomplete root discussion blocks otherwise actionable repair'
    $azahar.coverage.discussionEvidenceComplete = $true
    $answer.blockerCitation = $null
    $result = Read-Assessment $answer $azahar
    Assert (-not $result.eligible -and $result.rootCauseEvidenceStatus -eq 'unknown') 'Actionable-looking classifications do not substitute for a cited cause'
    foreach ($case in 'source', 'zero', 'range', 'type') {
        $answer = New-GapAssessment $azahar
        switch ($case) {
            'source' { $answer.blockerCitation.sourceId = 'foreign/repo/issue-1' }
            'zero' { $answer.blockerCitation.passage = 0 }
            'range' { $answer.blockerCitation.passage = 999 }
            'type' { $answer.blockerCitation.passage = '1' }
        }
        Assert-Throws { Read-Assessment $answer $azahar } '*source*'
    }
    Assert-Throws { ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @((New-Assessment $hermes)) } | ConvertTo-Json -Depth 12) @($hermes) } '*exact requested repository set*'
    $oldContext = Read-Json "$($prepared.output)\context.json"
    $oldContext.evidencePolicyVersion = 1
    Write-Json "$($prepared.output)\context.json" $oldContext
    $failed = Run-Review 'old-policy-rejected' 'Agent' $prepared.output
    Assert ($failed.error -and $global:ReviewMock.agentCalls.Count -eq 0) 'A prepared corpus from before discussion collection cannot invoke paid review'
    $oldContext.evidencePolicyVersion = 2
    Write-Json "$($prepared.output)\context.json" $oldContext
    $boundedDocuments = $oldContext.repositories[-1].documents
    $oldContext.repositories[-1].documents += New-ReviewDocument 'owner/repo100' 'oversized' 'source' 'https://github.com/owner/repo100' ('x' * 400001) 450000
    Write-Json "$($prepared.output)\context.json" $oldContext
    $failed = Run-Review 'late-oversized-batch' 'Agent' $prepared.output
    Assert ($failed.error -like '*400,000 characters*' -and $global:ReviewMock.agentCalls.Count -eq 0) 'All expanded discussion prompts are size-checked before the first paid call, including a later oversized batch'
    $oldContext.repositories[-1].documents = $boundedDocuments
    Write-Json "$($prepared.output)\context.json" $oldContext

    foreach ($case in 'complete', 'pages', 'text', 'inline', 'malformed', 'foreign') {
        Reset-Mock
        $collected = New-CollectedRepository 1
        $collected.issues = @(@{ number = 9; title = 'Windows ARM64'; url = 'https://github.com/owner/repo1/issues/9'
            bodyEvidence = Get-RepositoryExcerpt 'Missing Windows ARM64 compiler support.' })
        $repository = New-ReviewRepository $collected
        $comment = @{ url = 'https://github.com/owner/repo1/issues/9#issuecomment-10'
            body = 'The compiler configuration needs a native ARM64 target.'
            author = @{ login = 'maintainer' }; authorAssociation = 'MEMBER'
            createdAt = '2026-06-17T20:44:43Z'; updatedAt = '2026-06-17T20:44:43Z' }
        if ($case -eq 'text') { $comment.body = 'x' * 1200 }
        if ($case -eq 'foreign') { $comment.url = 'https://github.com/foreign/repo/issues/9#issuecomment-10' }
        $connection = New-DiscussionConnection @($comment)
        if ($case -eq 'pages') {
            $other = $comment.Clone(); $other.url = $comment.url -replace '-10$', '-11'
            $third = $comment.Clone(); $third.url = $comment.url -replace '-10$', '-12'
            $connection = New-DiscussionConnection @($comment, $other, $third) 4
        }
        if ($case -eq 'malformed') { $connection.totalCount = 2 }
        $global:ReviewMock.issueComments['owner/repo1/9'] = $connection
        if ($case -in @('malformed', 'foreign')) {
            Assert-Throws { Add-ReviewPullRequests @($repository) @{ requests = @() } } '*discussion*'
            continue
        }
        Add-ReviewPullRequests @($repository) @{ requests = @() }
        if ($case -eq 'inline') {
            $parent = $repository.documents | Where-Object kind -eq 'issue'
            $review = @{ url = "$($parent.url)#pullrequestreview-22"; body = 'See inline discussion.'
                author = @{ login = 'maintainer' }; authorAssociation = 'MEMBER'; state = 'COMMENTED'
                submittedAt = '2026-06-17T20:44:43Z'; comments = @{ totalCount = 1 } }
            Add-ReviewDiscussion $repository $parent (New-DiscussionConnection @($review)) 'pull_request_review' 2
        }
        $expectedComplete = $case -eq 'complete'
        Assert ($repository.coverage.discussionEvidenceComplete -eq $expectedComplete -and
            ($repository.documents | Where-Object id -eq 'owner/repo1/issue-9-issuecomment-10').details.parentId -eq 'owner/repo1/issue-9' -and
            $global:ReviewMock.calls.Count -eq 1) "Issue identity and completeness are preserved for $case discussion without extra HTTP requests"
    }
    $repository = New-ReviewRepository (New-CollectedRepository 1)
    $repository.coverage.discussionEvidenceComplete = $true
    $parent = New-ReviewDocument $repository.fullName 'pr-1' 'pull_request' 'https://github.com/owner/repo1/pull/1' 'Budget fixture' `
        -Details @{ discussionComplete = $true }
    for ($i = 1; $i -le 12; $i++) {
        $comment = @{ url = "$($parent.url)#issuecomment-$i"; body = 'x' * 1000
            author = $null; authorAssociation = 'NONE'; createdAt = '2026-06-17T20:44:43Z'; updatedAt = '2026-06-17T20:44:43Z' }
        Add-ReviewDiscussion $repository $parent (New-DiscussionConnection @($comment)) 'pull_request_comment' 4
    }
    Assert ($repository.coverage.discussionCharacters -eq 9000 -and
        ($repository.documents.content.text.Length | Measure-Object -Sum).Sum -le 9000 -and
        -not $repository.coverage.discussionEvidenceComplete -and -not $parent.details.discussionComplete) 'Repository discussion budget stays within 9000 characters and exposes omitted text'
    foreach ($case in 'open', 'closed', 'filtered-count', 'pagination') {
        Reset-Mock
        $collected = New-CollectedRepository 1
        $repository = New-ReviewRepository $collected
        $history = New-DiscussionConnection
        $history.totalCount = 16
        $node = @{ number = 1; url = 'https://github.com/owner/repo1/pull/1'; title = 'Windows ARM64'
            body = ''; state = 'OPEN'; merged = $false; closedAt = $null; author = @{ login = 'author' }
            repository = @{ nameWithOwner = 'owner/repo1' }; comments = New-DiscussionConnection
            reviews = New-DiscussionConnection; timelineItems = $history }
        if ($case -eq 'closed') {
            $node.state = 'CLOSED'; $node.closedAt = '2026-06-17T20:44:43Z'
            $history.nodes = @(@{ __typename = 'ClosedEvent'; createdAt = $node.closedAt; actor = @{ login = 'author' } })
            $history.filteredCount = 1
        }
        if ($case -eq 'filtered-count') { $history.filteredCount = 17 }
        if ($case -eq 'pagination') { $history.pageInfo.hasPreviousPage = $true }
        $global:ReviewMock.prNodes['owner/repo1'] = @($node)
        if ($case -in 'filtered-count', 'pagination') {
            Assert-Throws { Add-ReviewPullRequests @($repository) @{ requests = @() } } '*closure history*'
        } else {
            Add-ReviewPullRequests @($repository) @{ requests = @() }
            Assert ($repository.coverage.discussionEvidenceComplete -and
                @($repository.documents | Where-Object kind -eq 'pull_request').Count -eq 1) "Filtered closure history, not all $($history.totalCount) timeline events, determines completeness for $case PRs"
        }
    }

    Reset-Mock
    $global:ReviewMock.agentFailAt = 2
    $failed = Run-Review 'agent-partial-failure' 'Agent' $prepared.output
    Assert ($failed.error -and $failed.report.status -eq 'failed' -and $failed.report.assessedCount -eq 10 -and
        $failed.report.recommendations.Count -eq 0 -and $global:ReviewMock.agentCalls.Count -eq 2 -and
        $failed.report.batches[-1].status -eq 'failed') 'A later AI failure preserves ten reviews but emits no successful recommendation set or retry'
    Reset-Mock
    $global:ReviewMock.agentFailAt = 2
    $failed = Run-Review 'focus-survives-later-failure' 'Agent' $focusPrepared.output
    Assert ($failed.error -and $failed.report.status -eq 'failed' -and $failed.report.assessedCount -eq 1 -and
        $failed.report.focusFindings.Count -eq 1 -and $failed.report.recommendations.Count -eq 0) 'The specifically requested focus survives a later batch failure without claiming overall success'
    $env:GITHUB_ACTIONS = 'false'
    $failed = Run-Review 'agent-local-blocked' 'Agent' $prepared.output
    Assert ($failed.error -like '*only inside the GitHub Action*' -and $global:ReviewMock.agentCalls.Count -eq 2) 'Tests and local preparation never silently invoke paid AI'
    foreach ($case in 'size', 'oversized', 'base64') {
        Reset-Mock
        $global:ReviewMock.fileError = $case
        $failed = Run-Review "file-$case" 'Prepare'
        Assert ($failed.error -and $failed.report.status -eq 'failed' -and $global:ReviewMock.calls.Count -eq 1 -and
            $global:ReviewMock.agentCalls.Count -eq 0) "Malformed README data fails before AI rather than being treated as missing support: $case"
    }
    Reset-Mock
    $global:ReviewMock.failAt = 2
    $failed = Run-Review 'http-failure' 'Prepare'
    Assert ($failed.error -like '*HTTP 429*' -and $failed.report.assessedCount -eq 1 -and
        $global:ReviewMock.calls.Count -eq 2 -and $failed.report.recommendations.Count -eq 0) 'HTTP failures preserve progress without authentication fallback or retries'
    Reset-Mock
    $global:ReviewMock.fileError = '404'
    $document = Get-ReviewFile @{ fullName = 'owner/repo1'; defaultBranch = 'main' } @{ requests = @() }
    Assert ($document.details.status -eq 'not_found' -and $document.content.text -eq '') 'A missing README is explicit unknown evidence'
    Reset-Mock
    $collected = Read-Json "$root\input\discovery.json"
    $collected.repositories[0].fullName = 'NousResearch/hermes-agent'
    $collected.repositories[1].fullName = 'sindresorhus/get-windows'
    Write-Json "$root\input\discovery.json" $collected
    $overlap = Run-Review 'focus-already-ranked' 'Prepare' "$root\input" 'hermes-get-windows'
    Assert (-not $overlap.error -and $overlap.report.requestedCount -eq 100 -and $global:ReviewMock.calls.Count -eq 113) "Focus/dependency identities already in the pool reuse their evidence and PR reads: $($overlap.error)"
    Write-Host "$checks Copilot discovery review checks passed."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item Alias:\Invoke-RepairCopilot -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod, Function:\Start-Sleep, Function:\Mock-ReviewCopilot -Force -ErrorAction SilentlyContinue
    Remove-Variable ReviewMock -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
