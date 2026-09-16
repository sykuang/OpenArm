Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\github-trial-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $root
$savedEnvironment = @{}
foreach ($name in 'OPENARM_GITHUB_TOKEN', 'OPENARM_GITHUB_SOURCE', 'OPENARM_GITHUB_FORK_OWNER',
    'OPENARM_GITHUB_TRIAL_ID', 'OPENARM_GITHUB_TRIAL_CREATE') {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:OPENARM_GITHUB_TOKEN = 'local-test-placeholder'
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function Reset-Mock {
    $global:GitHubTrialMock = @{
        api = 'api.github.com'; owner = 'tester'; sourceOwner = 'upstream'; forkExists = $false
        collision = $false; delay = 0; polls = 0; neverReady = $false
        branchExists = $false; writable = $true; workflows = @(); totalWorkflows = 0
        failStatus = 0; failRoute = ''; lostResponse = $false; wrongPr = $false
        calls = [Collections.Generic.List[object]]::new(); sleeps = 0
    }
}
function global:Start-Sleep { param($Seconds) $global:GitHubTrialMock.sleeps++ }
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec,
        $MaximumRedirection, $SkipHttpErrorCheck, $StatusCodeVariable, $ErrorAction)
    $m = $global:GitHubTrialMock
    $uriValue = [uri]$Uri
    if ($uriValue.Host -ne $m.api -or $uriValue.Scheme -ne 'https' -or $MaximumRedirection -ne 0) {
        throw 'Unexpected host or redirect policy; no real HTTP is permitted.'
    }
    if ($Headers.Authorization -ne 'Bearer local-test-placeholder') { throw 'Missing test authorization.' }
    $route = [uri]::UnescapeDataString($uriValue.PathAndQuery)
    $payload = if ($Body) { ConvertFrom-Json $Body } else { $null }
    $m.calls.Add(@{ method = $Method; route = $route; body = $payload })
    $status = 200
    $response = $null
    $source = "/repos/$($m.sourceOwner)/widget"
    $fork = "/repos/$($m.owner)/widget"
    if ($m.failStatus -and $route -eq $m.failRoute) {
        $status = $m.failStatus; $response = @{ message = 'simulated API denial' }
    } elseif ($Method -eq 'GET' -and $route -eq '/user') {
        $response = @{ login = 'tester' }
    } elseif ($Method -eq 'GET' -and $route -eq '/users/trial-org') {
        $response = @{ login = 'trial-org'; type = 'Organization' }
    } elseif ($Method -eq 'GET' -and $route -eq $source) {
        $response = @{ id = 10; name = 'widget'; full_name = "$($m.sourceOwner)/widget"
            owner = @{ login = $m.sourceOwner }; fork = $false; default_branch = 'main' }
    } elseif ($Method -eq 'GET' -and $route -eq "$source/git/ref/heads/main") {
        $response = @{ object = @{ sha = 'a' * 40 } }
    } elseif ($Method -eq 'GET' -and $route -eq $fork) {
        $m.polls++
        if (-not $m.forkExists -or $m.polls -le $m.delay -or $m.neverReady) {
            $status = 404; $response = @{ message = 'Not Found' }
        } else {
            $response = @{ id = 20; name = 'widget'; full_name = "$($m.owner)/widget"
                owner = @{ login = $m.owner }; fork = -not $m.collision; source = @{ id = 10 }
                default_branch = 'main'; archived = $false; disabled = $false
                permissions = @{ push = $m.writable } }
        }
    } elseif ($Method -eq 'POST' -and $route -eq "$source/forks") {
        $m.forkExists = $true; $status = 202; $response = @{ id = 20 }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/git/ref/heads/main") {
        $response = @{ object = @{ sha = 'b' * 40 } }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/actions/workflows?per_page=100") {
        $response = @{ total_count = $m.totalWorkflows; workflows = $m.workflows }
    } elseif ($Method -eq 'GET' -and $route -eq "$fork/git/ref/heads/openarm-trial-101") {
        if ($m.branchExists) { $response = @{ object = @{ sha = 'c' * 40 } } }
        else { $status = 404; $response = @{ message = 'Not Found' } }
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/git/refs") {
        $m.branchExists = $true; $status = 201; $response = @{ object = @{ sha = 'b' * 40 } }
    } elseif ($Method -eq 'PUT' -and $route -eq "$fork/contents/openarm-trials/101.md") {
        $status = 201; $response = @{ commit = @{ sha = 'c' * 40 } }
    } elseif ($Method -eq 'POST' -and $route -eq "$fork/pulls") {
        if ($m.lostResponse) { throw 'simulated ambiguous response local-test-placeholder' }
        $status = 201
        $response = @{ number = 7; draft = $true
            head = @{ ref = 'openarm-trial-101'; repo = @{ id = 20 } }
            base = @{ ref = 'main'; repo = @{ id = $(if ($m.wrongPr) { 10 } else { 20 }) } } }
    } else { throw "Unexpected offline request: $Method $route" }
    Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    [pscustomobject]$response
}
function Run-Trial([string] $Name, [bool] $Write = $false, [string] $Url = 'https://github.com/upstream/widget', [string] $Id = '101') {
    $output = Join-Path $root $Name
    $arguments = @{ SourceRepositoryUrl = $Url; Output = $output; TrialId = $Id; CreatePullRequest = $Write }
    if ($global:GitHubTrialMock.owner -eq 'trial-org') { $arguments.ForkOwner = 'trial-org' }
    $errorText = ''
    try { & "$repo\scripts\Invoke-GitHubTrial.ps1" @arguments } catch { $errorText = $_.Exception.Message }
    $reportPath = Join-Path $output 'result.json'
    @{ error = $errorText; output = $output
        report = $(if (Test-Path $reportPath) { Read-Json $reportPath } else { $null }) }
}
try {
    Reset-Mock
    $run = Run-Trial 'readonly'
    Assert (-not $run.error -and $run.report.status -eq 'checked') 'Read-only public command checks a repository'
    Assert (@($global:GitHubTrialMock.calls | Where-Object method -ne 'GET').Count -eq 0) 'Default mode performs no external writes'

    foreach ($mode in 'False', 'True', 'false', 'true') {
        Reset-Mock
        $env:OPENARM_GITHUB_SOURCE = 'https://github.com/upstream/widget'
        $env:OPENARM_GITHUB_FORK_OWNER = ''
        $env:OPENARM_GITHUB_TRIAL_ID = '101'
        $env:OPENARM_GITHUB_TRIAL_CREATE = $mode
        $output = Join-Path $root "environment-$mode-$([guid]::NewGuid())"
        & "$repo\scripts\Invoke-GitHubTrial.ps1" -Output $output
        $result = Read-Json (Join-Path $output 'result.json')
        $expected = if ($mode -eq 'True') { 'draft_created' } else { 'checked' }
        Assert ($result.status -eq $expected) "Azure/Actions environment binding honors $mode"
    }

    Reset-Mock
    $global:GitHubTrialMock.delay = 2
    $run = Run-Trial 'create' $true
    Assert (-not $run.error -and $run.report.status -eq 'draft_created') 'Confirmed command creates a draft PR'
    Assert ($global:GitHubTrialMock.sleeps -gt 0) 'Asynchronous fork readiness is polled'
    $writes = @($global:GitHubTrialMock.calls | Where-Object method -ne 'GET')
    Assert (($writes.method -join ',') -eq 'POST,POST,PUT,POST') 'Exactly one fork, branch, file commit and PR are created'
    Assert ($writes[0].route -eq '/repos/upstream/widget/forks') 'Only fork creation targets upstream'
    Assert (@($writes | Select-Object -Skip 1 | Where-Object { -not $_.route.StartsWith('/repos/tester/widget/') }).Count -eq 0) 'All branch, file and PR writes target the fork'
    Assert ($writes[1].body.ref -eq 'refs/heads/openarm-trial-101' -and $writes[1].body.sha -eq ('b' * 40)) 'New branch starts at the fork base, without resetting it'
    $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($writes[2].body.content))
    Assert ($content -like '*documentation-only*' -and $content -like '*not*Arm64*validation*') 'The change states its limited purpose'
    Assert ($writes[2].body.branch -eq 'openarm-trial-101' -and -not $writes[2].body.PSObject.Properties['sha']) 'Contents API creates a new file only on the trial branch'
    Assert ($writes[3].body.draft -and $writes[3].body.head -eq 'openarm-trial-101' -and $writes[3].body.base -eq 'main') 'PR is draft and both branches are in the fork'
    Assert ($run.report.pullRequestUrl -eq 'https://github.com/tester/widget/pull/7') 'Durable evidence links the fork PR'
    $run = Run-Trial 'repeated' $true
    Assert ($run.error -like '*already exists*') 'Rerunning the same trial refuses existing branch writes'
    Assert (@($global:GitHubTrialMock.calls | Where-Object { $_.method -eq 'POST' -and $_.route -like '*/pulls' }).Count -eq 1) 'A repeated trial cannot create another PR'

    Reset-Mock
    $global:GitHubTrialMock.forkExists = $true
    $run = Run-Trial 'reuse' $true
    Assert (-not $run.error -and @($global:GitHubTrialMock.calls | Where-Object { $_.method -eq 'POST' -and $_.route -like '*/forks' }).Count -eq 0) 'Existing matching fork is reused without syncing its default branch'

    Reset-Mock
    $global:GitHubTrialMock.api = 'api.msft.ghe.com'
    $global:GitHubTrialMock.owner = 'trial-org'
    $run = Run-Trial 'enterprise-org' $true 'https://msft.ghe.com/upstream/widget.git'
    $forkCall = @($global:GitHubTrialMock.calls | Where-Object { $_.method -eq 'POST' -and $_.route -like '*/forks' })
    Assert (-not $run.error -and $forkCall[0].body.organization -eq 'trial-org') 'Data-resident enterprise API and explicit organization fork are supported'
    Assert ($run.report.pullRequestUrl -eq 'https://msft.ghe.com/trial-org/widget/pull/7') 'Enterprise PR stays on the selected host'

    Reset-Mock
    $global:GitHubTrialMock.sourceOwner = 'tester'
    $run = Run-Trial 'own-source' $true 'https://github.com/tester/widget'
    Assert ($run.error -like '*different repositories*' -and @($global:GitHubTrialMock.calls | Where-Object method -ne 'GET').Count -eq 0) 'Source cannot be mistaken for the writable fork'
    Reset-Mock
    $global:GitHubTrialMock.forkExists = $true
    $global:GitHubTrialMock.workflows = @(@{ state = 'disabled_fork' })
    $global:GitHubTrialMock.totalWorkflows = 1
    $run = Run-Trial 'disabled-workflows' $true
    Assert (-not $run.error -and $run.report.status -eq 'draft_created') 'Disabled fork workflows do not prevent the trial'

    foreach ($case in @(
        @{ name = 'collision'; field = 'collision'; value = $true; pattern = '*not a matching fork*' },
        @{ name = 'no-write'; field = 'writable'; value = $false; pattern = '*write access*' },
        @{ name = 'active-workflow'; field = 'workflows'; value = @(@{ state = 'active' }); pattern = '*active GitHub Actions*' },
        @{ name = 'incomplete-workflows'; field = 'totalWorkflows'; value = 101; pattern = '*workflow inventory*' }
    )) {
        Reset-Mock
        $global:GitHubTrialMock.forkExists = $true
        $global:GitHubTrialMock[$case.field] = $case.value
        if ($case.name -eq 'active-workflow') { $global:GitHubTrialMock.totalWorkflows = 1 }
        $run = Run-Trial $case.name $true
        Assert ($run.error -like $case.pattern -and $run.report.status -eq 'failed') "$($case.name) is an explicit durable failure"
        Assert (@($global:GitHubTrialMock.calls | Where-Object method -ne 'GET').Count -eq 0) "$($case.name) is rejected before mutation"
    }
    foreach ($status in 401, 403, 429, 500) {
        Reset-Mock
        $global:GitHubTrialMock.failRoute = '/repos/upstream/widget'
        $global:GitHubTrialMock.failStatus = $status
        $run = Run-Trial "http-$status" $true
        Assert ($run.error -like "*HTTP $status*" -and $run.report.status -eq 'failed') "HTTP $status is surfaced, not treated as a missing fork"
        Assert (@($global:GitHubTrialMock.calls | Where-Object method -ne 'GET').Count -eq 0) "HTTP $status cannot trigger writes"
    }
    Reset-Mock
    $global:GitHubTrialMock.neverReady = $true
    $run = Run-Trial 'timeout' $true
    Assert ($run.error -like '*not ready*' -and $global:GitHubTrialMock.sleeps -le 30) 'Fork readiness has a finite retry budget'
    Assert (@($global:GitHubTrialMock.calls | Where-Object method -ne 'GET').Count -eq 1) 'Readiness timeout never repeats fork creation'

    foreach ($kind in 'lostResponse', 'wrongPr') {
        Reset-Mock
        $global:GitHubTrialMock[$kind] = $true
        $run = Run-Trial $kind $true
        Assert ($run.error -and $run.report.status -eq 'failed') "$kind cannot be reported as PR success"
        Assert (@($global:GitHubTrialMock.calls | Where-Object { $_.method -eq 'POST' -and $_.route -like '*/pulls' }).Count -eq 1) "$kind does not retry a possibly completed PR creation"
    }
    foreach ($url in 'http://github.com/upstream/widget', 'https://evil.invalid/upstream/widget',
        'https://github.com.evil.invalid/upstream/widget', 'https://user:pass@github.com/upstream/widget',
        'https://github.com/upstream/widget?other=1', 'https://github.com/upstream/widget/tree/main',
        'https://github.com/local-test-placeholder/widget') {
        Reset-Mock
        $run = Run-Trial ([guid]::NewGuid().ToString()) $true $url
        Assert ($run.error -and $global:GitHubTrialMock.calls.Count -eq 0) 'Unsupported source URLs are rejected before sending the token'
    }
    foreach ($id in '../escape', 'refs/heads/main', '$(unexpanded)', 'local-test-placeholder') {
        Reset-Mock
        $run = Run-Trial ([guid]::NewGuid().ToString()) $true 'https://github.com/upstream/widget' $id
        Assert ($run.error -and $global:GitHubTrialMock.calls.Count -eq 0) 'Unsafe or token-bearing trial identifiers fail before HTTP and are not retained'
    }
    foreach ($missingToken in '', '$(OpenArm.GitHubToken)') {
        Reset-Mock
        $env:OPENARM_GITHUB_TOKEN = $missingToken
        $run = Run-Trial "missing-token-$([guid]::NewGuid())" $true
        Assert ($run.error -like '*secret*OPENARM_GITHUB_TOKEN*' -and $global:GitHubTrialMock.calls.Count -eq 0) 'Missing Actions secret or unresolved legacy variable is rejected before HTTP'
    }
    $env:OPENARM_GITHUB_TOKEN = 'local-test-placeholder'
    $before = (Get-FileHash "$root\readonly\result.json").Hash
    $run = Run-Trial 'readonly'
    Assert ($run.error -like '*already exists*' -and (Get-FileHash "$root\readonly\result.json").Hash -eq $before) 'Existing evidence cannot be overwritten'
    $artifacts = (Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    Assert (-not $artifacts.Contains('local-test-placeholder')) 'Token is absent from all JSON and failure artifacts'
    Write-Host "OpenArm: $checks GitHub trial checks passed."
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Item Function:\Invoke-RestMethod, Function:\Start-Sleep
    Remove-Variable -Name GitHubTrialMock -Scope Global
    Remove-Item -LiteralPath $root -Recurse -Force
}
