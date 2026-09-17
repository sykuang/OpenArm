[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Agent')] [string] $Phase,
    [Parameter(Mandatory)] [string] $InputPath,
    [string] $Focus = $(if ($env:OPENARM_DISCOVERY_FOCUS) { $env:OPENARM_DISCOVERY_FOCUS } else { 'none' }),
    [string] $Output = (Join-Path $PSScriptRoot "..\out\copilot-discovery-$([guid]::NewGuid())"),
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\DiscoveryReview.ps1"

$InputPath = Resolve-OutputPath $InputPath $OutputRoot
$Output = Resolve-OutputPath $Output $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Review output already exists; choose a fresh directory.' }
$null = New-Item -ItemType Directory -Path $Output
$report = @{
    schemaVersion = 1; phase = $Phase; status = 'starting'; error = $null
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); completedAt = $null
    runId = $env:GITHUB_RUN_ID; workflowCommit = $env:GITHUB_SHA; reviewer = 'github_copilot_cli'
    nativeVerified = $false; authVerified = $false; sourceDiscoverySha256 = $null
    citationMode = 'numbered_source_passages'
    focus = $Focus; rankedCount = 0; requestedCount = 0; assessedCount = 0
    requests = @(); batches = @(); assessments = @(); recommendations = @(); focusFindings = @()
    limits = @{ maxRankedRepositories = 100; maxFocusRepositories = 1; maxDependencyRepositories = 1
        maxPreparationRequests = 150; maxRepositoriesPerPrompt = 10; maxAgentCalls = 11
        maxPromptDataCharacters = 400000; maxAgentSecondsPerCall = 180; maxResponseCharacters = 100000 }
    limitations = @(
        'All results are provisional analysis of public text, not native builds or execution proof.'
        'Every ranked repository is reviewed, including unconfigured distribution channels and non-matching issue titles.'
        'README text is bounded to 6,000 characters; issue and PR text to about 2,000 each. Excerpts retain hashes and truncation. Only five matching issues and five PRs per repository are included.'
        'Missing matches, truncated evidence or absent packages alone do not prove missing native support.'
        'A native parent installer cannot prove that an optional native dependency or disabled feature works. Source-build feasibility still requires native reproduction.'
        'Open/merged native fixes exclude duplicate recommendations; merged disabled-feature/emulation workarounds are not native fixes. Incomplete PR searches require human review.'
        'The named focus is outside the ranked pool unless independently present there; it never invents a source rank.'
        'Copilot receives prepared public evidence over standard input with no tools, custom instructions, MCPs or target execution. There are no AI or network retries and no automatic edits, forks or PRs.'
    )
}
$context = $null

function Save-Review {
    Write-Json (Join-Path $Output 'report.json') $report
    if ($Phase -eq 'Prepare' -and $context) { Write-Json (Join-Path $Output 'context.json') $context }
}

function ConvertTo-ReviewMarkdown([string] $Value) {
    [Net.WebUtility]::HtmlEncode(($Value -replace '[\p{Cc}\p{Cf}]', ' ')) -replace '([\\`*_\[\]{}()|!])', '\$1'
}

function Save-ReviewMarkdown {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Copilot CLI native Windows Arm64 discovery review')
    $lines.Add('')
    $lines.Add("Status: **$($report.status)**. Reviewed $($report.assessedCount)/$($report.requestedCount) repositories; $($report.rankedCount) belong to the ranked source pool.")
    $lines.Add('This is the content-review report. The earlier discovery report is evidence collection, not the final recommendation queue.')
    $lines.Add("Focus: $(ConvertTo-ReviewMarkdown $report.focus). Native execution verified: **false**.")
    if ($report.error) { $lines.Add("Error: $(ConvertTo-ReviewMarkdown $report.error)") }
    foreach ($candidate in $report.recommendations) {
        $lines.Add("- $($candidate.track) provisional candidate: [$($candidate.fullName)](https://github.com/$($candidate.fullName)); scope $($candidate.scope).")
    }
    if ($report.status -eq 'completed' -and -not $report.recommendations.Count) {
        $lines.Add('No automatic recommendation qualified. Reported gaps below can still require follow-up because upstream work or native reproduction is incomplete.')
    }
    $lines.Add('')
    $lines.Add('## Reported missing support and focus checks')
    foreach ($item in $report.assessments) {
        if ($item.assessment -ne 'reported_missing_native_support' -and $item.fullName -notin @($report.focusFindings | ForEach-Object fullName)) { continue }
        $lines.Add("### $($item.fullName)")
        $lines.Add("Assessment: $($item.assessment); scope $($item.scope); upstream $($item.upstreamDisposition); eligibility $($item.eligibilityReason).")
        $lines.Add((ConvertTo-ReviewMarkdown $item.reason))
        if ($item.dependency) { $lines.Add("Dependency: $(ConvertTo-ReviewMarkdown $item.dependency.name); owner $(ConvertTo-ReviewMarkdown $item.dependency.repository).") }
        foreach ($citation in $item.citations) {
            $lines.Add("- [$(ConvertTo-ReviewMarkdown $citation.sourceId)]($($citation.url)): $(ConvertTo-ReviewMarkdown $citation.quote)")
        }
    }
    $lines.Add('')
    $lines.Add('## All repository assessments')
    $lines.Add('| Repository | Review scope | Assessment | Native gap scope | Upstream disposition |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($item in $report.assessments) {
        $lines.Add("| $($item.fullName) | $($item.reviewScope) | $($item.assessment) | $($item.scope) | $($item.upstreamDisposition) |")
    }
    $lines.Add('')
    $lines.Add('## Limits')
    foreach ($limitation in $report.limitations) { $lines.Add("- $limitation") }
    $lines | Set-Content -LiteralPath (Join-Path $Output 'copilot-review.md') -Encoding utf8
}

try {
    if ($Phase -eq 'Prepare') {
        $report.status = 'preparing'
        $focusConfig = Read-DiscoveryFocus $Focus
        $discoveryPath = Join-Path $InputPath 'discovery.json'
        if ((Get-Item -LiteralPath $discoveryPath).Length -gt 32MB) { throw 'Discovery evidence exceeds 32 MiB.' }
        $discovery = Read-Json $discoveryPath
        if ($discovery.status -ne 'completed' -or $discovery.repositories -isnot [array] -or
            $discovery.repositories.Count -lt 1 -or $discovery.repositories.Count -gt 100 -or
            $discovery.requestedCount -ne $discovery.repositories.Count -or
            $discovery.assessedCount -ne $discovery.requestedCount -or
            $discovery.releaseAssessedCount -ne $discovery.requestedCount -or
            $discovery.distributionAssessedCount -ne $discovery.requestedCount) { throw 'Review requires a completed, bounded discovery evidence set.' }
        $report.sourceDiscoverySha256 = (Get-FileHash -LiteralPath $discoveryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.rankedCount = $discovery.repositories.Count
        $context = @{ schemaVersion = 1; sourceDiscoverySha256 = $report.sourceDiscoverySha256
            runId = $env:GITHUB_RUN_ID; workflowCommit = $env:GITHUB_SHA
            focus = $Focus; focusRepository = $null; focusQuestion = ''; repositories = @() }
        $seen = @{}
        foreach ($repository in $discovery.repositories) {
            if ($seen.ContainsKey($repository.fullName)) { throw 'Duplicate repository in discovery evidence.' }
            $seen[$repository.fullName] = $true
            $entry = New-ReviewRepository $repository
            $entry.documents += Get-ReviewFile $entry $report
            $context.repositories += $entry
            $report.assessedCount++
            Save-Review
        }
        if ($focusConfig) {
            $context.focusRepository = $focusConfig.repository
            $context.focusQuestion = $focusConfig.question
            $entry = $context.repositories | Where-Object fullName -eq $focusConfig.repository | Select-Object -First 1
            if (-not $entry) {
                $entry = Get-FocusRepository $focusConfig $report 'focus'
                $entry.documents += Get-ReviewFile $entry $report
                $context.repositories += $entry
                $report.assessedCount++
            }
            $entry.searchTerms = $focusConfig.searchTerms
            foreach ($path in $focusConfig.files) { $entry.documents += Get-ReviewFile $entry $report $path }
            $dependency = $context.repositories | Where-Object fullName -eq $focusConfig.dependency.repository | Select-Object -First 1
            if (-not $dependency) {
                $dependency = Get-FocusRepository $focusConfig.dependency $report 'dependency'
                $dependency.documents += Get-ReviewFile $dependency $report
            }
            foreach ($path in $focusConfig.dependency.files) { $dependency.documents += Get-ReviewFile $dependency $report $path }
            $entry.dependency = $dependency
        }
        $all = @($context.repositories)
        foreach ($entry in $context.repositories) {
            if ($entry.dependency -and $entry.dependency.fullName -notin $all.fullName) { $all += $entry.dependency }
        }
        for ($i = 0; $i -lt $all.Count; $i += 10) {
            Add-ReviewPullRequests @($all | Select-Object -Skip $i -First 10) $report
            Save-Review
        }
        $report.requestedCount = $context.repositories.Count
        $report.status = 'prepared'
    } else {
        if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Paid Copilot discovery review runs only inside the GitHub Action.' }
        $prepared = Read-Json (Join-Path $InputPath 'report.json')
        $contextPath = Join-Path $InputPath 'context.json'
        if ((Get-Item -LiteralPath $contextPath).Length -gt 16MB) { throw 'Prepared review context exceeds 16 MiB.' }
        $context = Read-Json $contextPath
        if ($prepared.phase -ne 'Prepare' -or $prepared.status -ne 'prepared' -or $context.schemaVersion -ne 1 -or
            $context.runId -cne $env:GITHUB_RUN_ID -or $context.workflowCommit -cne $env:GITHUB_SHA -or
            $context.sourceDiscoverySha256 -cne $prepared.sourceDiscoverySha256 -or
            $context.repositories -isnot [array] -or $context.repositories.Count -lt 1 -or $context.repositories.Count -gt 101 -or
            $context.repositories.Count -ne $prepared.requestedCount -or
            @($context.repositories.fullName | Sort-Object -Unique).Count -ne $context.repositories.Count) {
            throw 'Prepared context does not match this workflow run, commit and repository set.'
        }
        $report.status = 'reviewing'
        $report.focus = $context.focus
        $report.sourceDiscoverySha256 = $context.sourceDiscoverySha256
        $report.preparedContextSha256 = (Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.rankedCount = $prepared.rankedCount
        $report.requestedCount = $context.repositories.Count
        $workspace = Join-Path $Output 'workspace'
        $null = New-Item -ItemType Directory -Path $workspace
        $batches = [Collections.Generic.List[object]]::new()
        $normal = @($context.repositories | Where-Object fullName -ne $context.focusRepository)
        for ($i = 0; $i -lt $normal.Count; $i += 10) { $batches.Add(@($normal | Select-Object -Skip $i -First 10)) }
        if ($context.focusRepository) { $batches.Add(@($context.repositories | Where-Object fullName -eq $context.focusRepository)) }
        if ($batches.Count -gt 11) { throw 'Copilot review exceeded eleven bounded calls.' }
        foreach ($batch in $batches) {
            $number = $report.batches.Count + 1
            $prefix = 'batch-{0:D2}' -f $number
            $question = if ($batch.fullName -contains $context.focusRepository) { $context.focusQuestion } else { '' }
            $prompt = Get-DiscoveryReviewPrompt $batch $question
            $promptPath = Join-Path $Output "$prefix.prompt.txt"
            [IO.File]::WriteAllText($promptPath, $prompt, [Text.UTF8Encoding]::new($false))
            $receipt = @{ number = $number; repositories = @($batch.fullName); status = 'running'
                promptSha256 = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash.ToLowerInvariant()
                log = "$prefix.log"; usage = "$prefix.usage.json"; completedAt = $null }
            $report.batches += $receipt
            Save-Review
            $log = Join-Path $Output $receipt.log
            $usage = Join-Path $Output $receipt.usage
            Invoke-RepairCopilot $prompt $workspace $log -PromptOnStdin -TimeoutSeconds 180 -UsageFile $usage
            $usageData = Read-Json $usage
            if ($usageData -isnot [hashtable] -or -not $usageData.Count) { throw 'Copilot did not preserve a usage receipt.' }
            $report.authVerified = $true
            $items = @(ConvertFrom-DiscoveryReview (Get-Content -LiteralPath $log -Raw) $batch)
            $report.assessments += $items
            $report.assessedCount += $items.Count
            $receipt.usageSha256 = (Get-FileHash -LiteralPath $usage -Algorithm SHA256).Hash.ToLowerInvariant()
            $receipt.status = 'completed'
            $receipt.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Save-Review
        }
        foreach ($track in @('trending', 'foundational')) {
            $candidate = $report.assessments | Where-Object { $_.eligible -and $_.tracks -contains $track } |
                Sort-Object { $_.sourceRanks[$track] } | Select-Object -First 1
            if ($candidate) {
                $recommendation = $candidate.Clone()
                $recommendation.track = $track
                $recommendation.workKind = if ($candidate.scope -eq 'project') { 'investigate_missing_native_support' } else { 'investigate_missing_native_dependency_or_feature' }
                $report.recommendations += $recommendation
            }
        }
        $report.focusFindings = @($report.assessments | Where-Object fullName -eq $context.focusRepository)
        $report.status = 'completed'
    }
} catch {
    $report.status = 'failed'
    $report.recommendations = @()
    foreach ($batch in $report.batches) { if ($batch.status -eq 'running') { $batch.status = 'failed' } }
    $report.error = $_.Exception.Message
    foreach ($secret in @($env:OPENARM_GITHUB_DISCOVERY_TOKEN, $env:GITHUB_TOKEN)) {
        if ($secret) { $report.error = $report.error.Replace($secret, '[redacted]') }
    }
    throw $report.error
} finally {
    $report.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-Review
    Save-ReviewMarkdown
}
Write-Host "Copilot discovery $Phase completed: $($report.status). Evidence: $Output"
