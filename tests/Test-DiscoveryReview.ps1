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
                    body = $m.stageText; state = 'MERGED'; merged = $true; repository = @{ nameWithOwner = $name } }
            }
            $data['r' + $query.Groups[1].Value] = @{ issueCount = $nodes.Count; nodes = $nodes; pageInfo = @{ hasNextPage = $false } }
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
        reviewedSurfaces = @('readme', 'issues', 'pull_requests', 'releases'); citations = @()
    }
    if ($Repository.fullName -eq 'NousResearch/hermes-agent') {
        $item.assessment = 'reported_missing_native_support'; $item.scope = 'dependency'
        $item.dependency = @{ name = 'get-windows'; repository = 'sindresorhus/get-windows' }
        $item.upstreamDisposition = 'workaround_only'
        $item.reason = 'The native desktop package disables window enumeration when its dependency is absent; this is not a native feature fix.'
        $source = $Repository.documents | Where-Object { $_.id -like '*stage-native-deps.mjs' } | Select-Object -First 1
        $release = $Repository.dependency.documents | Where-Object kind -eq 'release' | Select-Object -First 1
        $item.citations = @(
            @{ sourceId = $source.id; passage = 1 },
            @{ sourceId = $release.id; passage = 1 }
        )
    }
    $item
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
    Write-Json $Log @{ schemaVersion = 2; repositories = @($repositories | ForEach-Object { New-Assessment $_ }) }
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
    $focusReview = Run-Review 'reviewed-focus' 'Agent' $focusPrepared.output
    Assert (-not $focusReview.error -and $focusReview.report.assessedCount -eq 101 -and
        $global:ReviewMock.agentCalls.Count -eq 11 -and $global:ReviewMock.agentCalls[-1].count -eq 1) "The named focus receives its own content review without changing the ranked 100: $($focusReview.error)"
    $finding = $focusReview.report.focusFindings[0]
    Assert ($finding.assessment -eq 'reported_missing_native_support' -and $finding.scope -eq 'dependency' -and $finding.eligible -and
        $finding.upstreamDisposition -eq 'workaround_only' -and $finding.citations.Count -eq 2 -and
        $focusReview.report.recommendations.Count -eq 0) 'Disabling window enumeration is a reported native dependency gap, not an invented ranked candidate or a native fix'
    Assert ($global:ReviewMock.agentCalls[0].prompt -notlike '*Focus question (if any): Does Hermes*' -and
        $global:ReviewMock.agentCalls[-1].prompt -like '*Focus question (if any): Does Hermes*') 'The special focus does not bias unrelated repository batches'
    $markdown = Get-Content "$($focusReview.output)\copilot-review.md" -Raw
    Assert ($markdown -like '*sindresorhus/get-windows*' -and $markdown -like '*window enumeration*' -and $markdown -like '*native Windows Arm64*') 'Final readable evidence explains the dependency instead of reporting a false empty success'

    foreach ($case in 'active_native_fix', 'merged_native_fix', 'unknown') {
        $answer = New-Assessment $hermes
        $answer.upstreamDisposition = $case
        $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
        Assert (-not $result[0].eligible) "Incomplete or existing native fixes cannot become a duplicate recommendation: $case"
    }
    $answer = New-Assessment $hermes
    $answer.scope = 'project'; $answer.dependency = $null
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'project_already_advertises_native_distribution') 'Already-native project distribution cannot be recommended as a new project port'
    $hermes.nativeSupport = 'not_a_native_port_candidate'
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'platform_independent_project_distribution') 'Portable distributions are not mistaken for projects needing a native port'
    $hermes.nativeSupport = 'native_distribution_available'
    $hermes.dependency.nativeSupport = 'native_distribution_available'
    $answer = New-Assessment $hermes
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'dependency_already_advertises_native_distribution') 'A stale application comment cannot hide an already-published native dependency'
    $hermes.dependency.nativeSupport = 'unverified'
    $hermes.dependency.coverage.pullRequestsTruncated = $true
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'upstream_work_not_fully_assessed') 'Incomplete dependency PR evidence also prevents duplicate recommendations'
    $hermes.dependency.coverage.pullRequestsTruncated = $false
    $hermes.coverage.pullRequestsTruncated = $true
    $answer = New-Assessment $hermes
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert (-not $result[0].eligible -and $result[0].eligibilityReason -eq 'upstream_work_not_fully_assessed') 'A reported dependency gap with truncated upstream evidence remains a follow-up, not an automatic repair'
    $hermes.coverage.pullRequestsTruncated = $false
    $answer = New-Assessment $hermes
    $answer.citations[0].quote = 'A model-generated paraphrase must never replace the actual source.'
    $result = @(ConvertFrom-DiscoveryReview (@{ schemaVersion = 2; repositories = @($answer) } | ConvertTo-Json -Depth 12) @($hermes))
    Assert ($result[0].citations[0].quote -ceq $global:ReviewMock.stageText) 'Only the selected original passage, never model-generated quote text, enters the report'
    foreach ($case in 'passage', 'passage-type', 'foreign-source', 'one-source', 'owner', 'missing-surface', 'duplicate', 'wrong-repository', 'missing-repository') {
        $answer = New-Assessment $hermes
        $payload = @{ schemaVersion = 2; repositories = @($answer) }
        switch ($case) {
            'passage' { $answer.citations[0].passage = 9999 }
            'passage-type' { $answer.citations[0].passage = '1' }
            'foreign-source' { $answer.citations[0].sourceId = 'other/project/issue-1' }
            'one-source' { $answer.citations = @($answer.citations[0]) }
            'owner' { $answer.dependency.repository = 'unrelated/owner' }
            'missing-surface' { $answer.reviewedSurfaces = @('readme') }
            'duplicate' { $payload.repositories += $answer }
            'wrong-repository' { $answer.fullName = 'other/project' }
            'missing-repository' { $payload.repositories = @() }
        }
        Assert-Throws { ConvertFrom-DiscoveryReview ($payload | ConvertTo-Json -Depth 12) @($hermes) } '*'
    }
    Assert-Throws { ConvertFrom-DiscoveryReview 'not JSON' @($hermes) } '*valid review JSON*'
    Assert-Throws { Get-DiscoveryReviewPrompt (@($hermes) * 11) } '*ten repositories*'

    Reset-Mock
    $global:ReviewMock.agentFailAt = 2
    $failed = Run-Review 'agent-partial-failure' 'Agent' $prepared.output
    Assert ($failed.error -and $failed.report.status -eq 'failed' -and $failed.report.assessedCount -eq 10 -and
        $failed.report.recommendations.Count -eq 0 -and $global:ReviewMock.agentCalls.Count -eq 2 -and
        $failed.report.batches[-1].status -eq 'failed') 'A later AI failure preserves ten reviews but emits no successful recommendation set or retry'
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
