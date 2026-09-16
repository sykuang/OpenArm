Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\GitHubRepair.ps1"
$root = Join-Path $repo ".local\repair-checks-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path "$root\scripts", "$root\targets\github", "$root\input"
Copy-Item -LiteralPath "$repo\scripts\Common.ps1", "$repo\scripts\GitHubRepair.ps1",
    "$repo\scripts\Publish-GitHubRepair.ps1" -Destination "$root\scripts"
$saved = @{}
foreach ($name in 'GITHUB_TOKEN', 'COPILOT_GITHUB_TOKEN', 'OPENARM_GITHUB_TOKEN', 'GITHUB_RUN_ID',
    'GITHUB_SHA', 'GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY', 'OPENARM_PUBLISH_DRAFT', 'GITHUB_STEP_SUMMARY', 'GITHUB_OUTPUT') {
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
    Assert ($message -like $Pattern) "Expected '$Pattern', received '$message'"
}
$task = @{
    id = 'fixture'; mode = 'cmake'; repository = 'https://github.com/upstream/widget'; commit = 'a' * 40
    sourceSubdirectory = '.'; generator = 'Visual Studio 17 2022'; executable = 'bin\widget.exe'
    smokeArguments = @('--smoke-test'); performanceSamples = 3; context = 'Offline fixture'; issue = 'https://github.com/upstream/widget/issues/1'
    allowedFiles = @('main.cpp'); fork = 'tester/widget'
}
function New-Candidate {
    @{ schemaVersion = 1; taskId = 'fixture'; runId = '101'; workflowCommit = 'b' * 40; sourceCommit = 'a' * 40
        files = @(@{ path = 'main.cpp'; baseSha256 = Get-RepairHash 'old source'; content = 'new source' }) }
}
function Save-Candidate($Candidate) {
    Write-Json "$root\input\candidate.json" $Candidate
    Write-Json "$root\input\report.json" @{
        phase = 'Validate'; status = 'validated'; taskId = 'fixture'; runId = '101'; workflowCommit = 'b' * 40
        sourceCommit = 'a' * 40
        candidateSha256 = (Get-FileHash "$root\input\candidate.json").Hash.ToLowerInvariant()
        native = @{ nativeVerified = $true; route = 'validated'; host = @{ osArchitecture = 'Arm64'; processArchitecture = 'Arm64' } }
    }
}
function Reset-Mock {
    $global:RepairMock = @{ calls = [Collections.Generic.List[object]]::new(); branch = $false; workflows = @()
        workflowCount = 0; base = 'a' * 40; network = 10; writable = $true; lostResponse = $false; wrongPr = $false
        badOriginal = $false; failStatus = 0; moveBase = $false; baseReads = 0 }
}
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection,
        $SkipHttpErrorCheck, $StatusCodeVariable)
    $m = $global:RepairMock
    if (([uri]$Uri).Host -ne 'api.github.com' -or $MaximumRedirection -ne 0 -or
        $Headers.Authorization -ne 'Bearer offline-publisher-value' -or $TimeoutSec -ne 30) {
        throw 'Unexpected API boundary; no network is permitted.'
    }
    $route = [uri]::UnescapeDataString(([uri]$Uri).PathAndQuery)
    $payload = if ($Body) { ConvertFrom-Json $Body -AsHashtable } else { $null }
    $m.calls.Add(@{ method = $Method; route = $route; body = $payload })
    $fork = '/repos/tester/widget'
    $status = 200; $result = $null
    if ($m.failStatus) { $status = $m.failStatus; $result = @{} }
    elseif ($Method -eq 'GET' -and $route -eq '/repos/upstream/widget') {
        $result = @{ id = 10; fork = $false; full_name = 'upstream/widget' }
    } elseif ($Method -eq 'GET' -and $route -eq $fork) {
        $result = @{ id = 20; fork = $true; full_name = 'tester/widget'; source = @{ id = $m.network }
            archived = $false; disabled = $false; permissions = @{ push = $m.writable }; default_branch = 'main' }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/git/ref/heads/main") {
        $m.baseReads++
        $result = @{ object = @{ sha = $(if ($m.moveBase -and $m.baseReads -gt 1) { 'c' * 40 } else { $m.base }) } }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/actions/workflows?per_page=100") {
        $result = @{ total_count = $m.workflowCount; workflows = $m.workflows }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/git/ref/heads/openarm-repair-101") {
        if ($m.branch) { $result = @{ object = @{ sha = 'c' * 40 } } } else { $status = 404; $result = @{} }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/git/commits/$('a' * 40)") {
        $result = @{ sha = 'a' * 40; tree = @{ sha = 'd' * 40 } }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/contents/main.cpp?ref=$('a' * 40)") {
        $result = @{ type = 'file'; path = 'main.cpp'; encoding = 'base64'; size = 10
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($(if ($m.badOriginal) { 'wrong source' } else { 'old source' }))) }
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/git/trees") {
        $status = 201; $result = @{ sha = 'e' * 40 }
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/git/commits") {
        $status = 201; $result = @{ sha = 'f' * 40 }
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/git/refs") {
        $m.branch = $true; $status = 201; $result = @{}
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/pulls") {
        if ($m.lostResponse) { throw 'Lost response offline-publisher-value' }
        $status = 201; $result = @{ number = 7; draft = $true
            head = @{ ref = 'openarm-repair-101'; sha = 'f' * 40; repo = @{ id = 20 } }
            base = @{ ref = 'main'; repo = @{ id = $(if ($m.wrongPr) { 10 } else { 20 }) } } }
    } else { throw "Unexpected offline API request: $Method $route" }
    Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    [pscustomobject]$result
}
function Run-Publisher([string] $Name) {
    $output = Join-Path $root $Name
    $errorText = ''
    try { & "$root\scripts\Publish-GitHubRepair.ps1" -TaskId fixture -InputPath "$root\input" -Output $output }
    catch { $errorText = $_.Exception.Message }
    @{ error = $errorText; report = Read-Json "$output\result.json" }
}
try {
    $env:GITHUB_STEP_SUMMARY = ''; $env:GITHUB_OUTPUT = ''
    $env:GITHUB_TOKEN = 'offline-actions-value'
    $env:COPILOT_GITHUB_TOKEN = 'offline-legacy-value'
    $env:OPENARM_GITHUB_TOKEN = 'offline-publisher-value'
    $env:GITHUB_RUN_ID = '101'; $env:GITHUB_SHA = 'b' * 40
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:GITHUB_REPOSITORY = 'tester/OpenArm'
    $env:OPENARM_PUBLISH_DRAFT = 'true'
    $pwsh = (Get-Process -Id $PID).Path
    $probe = 'Write-Output (@($env:GITHUB_TOKEN, $env:COPILOT_GITHUB_TOKEN, $env:OPENARM_GITHUB_TOKEN) -join "|")'
    foreach ($case in @(
        @{ switches = @{}; expected = '||' },
        @{ switches = @{ Agent = $true }; expected = '|offline-legacy-value|' },
        @{ switches = @{ Agent = $true; ActionsCopilot = $true }; expected = 'offline-actions-value||' }
    )) {
        $switches = $case.switches
        $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-Command', $probe) $root "$root\process.log" @switches
        Assert ($code -eq 0 -and (Get-Content "$root\process.log" -Raw).Trim() -ceq $case.expected) 'Only the selected agent credential reaches a subprocess; publisher token never does'
    }
    Assert-Throws { Invoke-LoggedProcess $pwsh @() $root "$root\invalid.log" -ActionsCopilot } '*only available to agent*'
    Assert ((Read-RepairTask hermes-browser-77488).mode -eq 'diagnose') 'Hermes external package issue cannot trigger edits'
    Assert ((Read-RepairTask cmake-smoke).repository -eq 'self') 'Native self-test is not an invented external repair'
    Assert-Throws { Read-RepairTask '..\smoke' } '*tracked, reviewed*'
    $null = New-Item -ItemType Directory -Path "$root\workspace"
    [IO.File]::WriteAllText("$root\workspace\main.cpp", 'source')
    Assert-RepairWorkspace "$root\workspace" $task
    [IO.File]::WriteAllText("$root\workspace\extra.cpp", 'unauthorized')
    Assert-Throws { Assert-RepairWorkspace "$root\workspace" $task } '*added or deleted*'
    $candidate = New-Candidate
    Assert-RepairBundle $candidate $task '101' ('b' * 40)
    foreach ($bad in '../main.cpp', 'MAIN.cpp', '.github/workflows/pwn.yml', 'tests/main.cpp') {
        $candidate = New-Candidate; $candidate.files[0].path = $bad
        Assert-Throws { Assert-RepairBundle $candidate $task '101' ('b' * 40) } '*forbidden*'
    }
    $candidate = New-Candidate; $candidate.files += $candidate.files[0]
    Assert-Throws { Assert-RepairBundle $candidate $task '101' ('b' * 40) } '*duplicate*'
    $candidate = New-Candidate; $candidate.files[0].content = 'x' * 65537
    Assert-Throws { Assert-RepairBundle $candidate $task '101' ('b' * 40) } '*oversized*'
    $candidate = New-Candidate; $candidate.files[0].content = 'old source'
    Assert-Throws { Assert-RepairBundle $candidate $task '101' ('b' * 40) } '*unchanged*'
    Assert-Throws { Assert-RepairBundle (New-Candidate) $task '102' ('b' * 40) } '*workflow run*'
    Assert-Throws { Assert-RepairBundle (New-Candidate) $task '101' ('c' * 40) } '*workflow run*'
    Write-Json "$root\targets\github\fixture.json" $task
    Save-Candidate (New-Candidate)
    Reset-Mock
    $run = Run-Publisher success
    Assert (-not $run.error -and $run.report.status -eq 'draft_created') "Public publisher creates guarded draft: $($run.error)"
    $writes = @($global:RepairMock.calls | Where-Object method -ne 'GET')
    Assert (($writes.route -join ',') -eq '/repos/tester/widget/git/trees,/repos/tester/widget/git/commits,/repos/tester/widget/git/refs,/repos/tester/widget/pulls') 'Exactly four writes, all inside the reviewed fork'
    Assert ($writes[0].body.tree.Count -eq 1 -and $writes[0].body.tree[0].content -ceq 'new source') 'Exact validated source content is published, not a trial document'
    Assert ($writes[1].body.parents[0] -ceq ('a' * 40) -and $writes[2].body.sha -ceq ('f' * 40)) 'New branch is based only on the pinned commit'
    Assert ($writes[3].body.draft -and $writes[3].body.base -eq 'main' -and $run.report.pullRequestUrl -eq 'https://github.com/tester/widget/pull/7') 'Draft stays in the fork'
    $again = Run-Publisher existing
    Assert ($again.error -like '*already exists*') 'Same run never overwrites a branch or duplicates a PR'
    foreach ($scenario in @(
        @{ name = 'wrong-network'; key = 'network'; value = 11; error = '*source network*' },
        @{ name = 'no-write'; key = 'writable'; value = $false; error = '*writable fork*' },
        @{ name = 'base-moved'; key = 'base'; value = 'c' * 40; error = '*differs from the pinned*' },
        @{ name = 'incomplete-workflows'; key = 'workflowCount'; value = 101; error = '*inactive workflows*' },
        @{ name = 'active-workflow'; key = 'workflows'; value = @(@{ state = 'active' }); error = '*inactive workflows*' },
        @{ name = 'wrong-content'; key = 'badOriginal'; value = $true; error = '*baseline differs*' },
        @{ name = 'http-error'; key = 'failStatus'; value = 403; error = '*HTTP 403*' }
    )) {
        Reset-Mock
        $global:RepairMock[$scenario.key] = $scenario.value
        $run = Run-Publisher $scenario.name
        Assert ($run.error -like $scenario.error) "$($scenario.name) rejects visibly: $($run.error)"
        Assert (@($global:RepairMock.calls | Where-Object method -ne 'GET').Count -eq 0) "$($scenario.name) makes no writes"
    }
    Reset-Mock; $global:RepairMock.moveBase = $true
    $run = Run-Publisher midflight-base
    Assert ($run.error -like '*moved while preparing*' -and -not $global:RepairMock.branch) 'Mid-publication base movement cannot produce a stale PR'
    Reset-Mock; $global:RepairMock.lostResponse = $true
    $run = Run-Publisher ambiguous
    Assert ($run.error -like '*no request was automatically retried*' -and $run.error -notlike '*offline-publisher-value*') 'Ambiguous failures are explicit and do not expose credentials'
    Assert (@($run.report.requests | Where-Object route -like '*/pulls').Count -eq 1) 'Lost response retains one durable mutation intent, no retry'
    Reset-Mock; $global:RepairMock.wrongPr = $true
    $run = Run-Publisher wrong-pr
    Assert ($run.error -like '*outside the requested*') 'Unexpected upstream PR response is a failure'
    foreach ($scenario in 'tampered', 'empty', 'no-opt-in', 'nonmanual', 'non-native') {
        Save-Candidate (New-Candidate); Reset-Mock
        if ($scenario -eq 'tampered') { Add-Content "$root\input\candidate.json" ' ' }
        if ($scenario -eq 'empty') { $bundle = New-Candidate; $bundle.files = @(); Save-Candidate $bundle }
        if ($scenario -eq 'no-opt-in') { $env:OPENARM_PUBLISH_DRAFT = 'false' }
        if ($scenario -eq 'nonmanual') { $env:GITHUB_EVENT_NAME = 'pull_request' }
        if ($scenario -eq 'non-native') {
            $validation = Read-Json "$root\input\report.json"; $validation.native.host.osArchitecture = 'X64'
            Write-Json "$root\input\report.json" $validation
        }
        $run = Run-Publisher $scenario
        Assert ($run.error.Length -gt 0 -and $global:RepairMock.calls.Count -eq 0) "$scenario rejected before all API access"
        $env:OPENARM_PUBLISH_DRAFT = 'true'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    }

    function Invoke-LoggedProcess {
        param($File, $Arguments, $WorkingDirectory, $Log, $TimeoutSeconds, [switch] $Agent, [switch] $ActionsCopilot)
        Assert ($File -eq 'copilot' -and $Agent -and $ActionsCopilot -and $TimeoutSeconds -eq 600) 'Copilot command uses explicit agent authentication and fixed timeout'
        Assert ($Arguments -contains '--no-custom-instructions' -and $Arguments -contains '--disable-builtin-mcps' -and
            $Arguments -contains '--disallow-temp-dir' -and $Arguments -contains '--deny-tool=shell') 'Copilot uses bounded noninteractive permissions'
        Assert (@($Arguments | Where-Object { $_ -match 'yolo|allow-all|autopilot' }).Count -eq 0) 'No unbounded permission or retry mode'
        $script:lastArguments = $Arguments
        return 0
    }
    Invoke-RepairCopilot 'diagnose' $root "$root\mock-agent.log"
    Assert ($lastArguments -contains '--deny-tool=*' -and $lastArguments -notcontains '--allow-tool=write') 'Diagnosis and auth allow no tools'
    Invoke-RepairCopilot 'repair' $root "$root\mock-agent.log" -Edit
    Assert ($lastArguments -contains '--allow-tool=read' -and $lastArguments -contains '--allow-tool=write') 'Editing attempt grants only source read/write categories'
    $env:GITHUB_TOKEN = ''
    Assert-Throws { Invoke-RepairCopilot 'missing auth' $root "$root\missing.log" } '*GITHUB_TOKEN*'
    Write-Host "Passed $checks Copilot repair checks."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    Remove-Variable RepairMock -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
