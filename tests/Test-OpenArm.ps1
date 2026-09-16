Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\checks-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $root -Force
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -like $Pattern) "Expected '$Pattern'; received '$message'"
}
$environment = @{}
Get-ChildItem Env: | Where-Object Name -match '^(OPENARM_|BUILD_|SYSTEM_|AGENT_|COPILOT_GITHUB_TOKEN$)' |
    ForEach-Object { $environment[$_.Name] = $_.Value }

try {
    foreach ($file in Get-ChildItem "$repo\scripts" -Filter *.ps1) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
        Assert ($errors.Count -eq 0) "Parse $($file.Name)"
    }
    $config = Read-Json "$repo\targets\smoke.json"
    Assert-Target $config
    Assert-Throws { Resolve-ChildPath $root '..\escape' } '*escapes*'
    Assert-Throws { Resolve-ChildPath $root 'C:\escape' } '*relative path*'
    Assert ((Resolve-ChildPath $root '.' -AllowRoot) -eq $root) 'Allow repository-root CMake targets'
    $external = $config.Clone()
    $external.repository = 'https://github.com/example/example'
    $external.commit = 'main'
    Assert-Throws { Assert-Target $external } '*40-character*'
    $external.commit = 'a' * 40
    Assert-Target $external
    $external.repository = 'https://github.com.evil.invalid/example/example'
    Assert-Throws { Assert-Target $external } '*HTTPS github.com*'

    $pe = Join-Path $root 'native.exe'
    $bytes = [byte[]]::new(128)
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([int]64).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($bytes, 64)
    [BitConverter]::GetBytes([uint16]0xAA64).CopyTo($bytes, 68)
    [IO.File]::WriteAllBytes($pe, $bytes)
    Assert ((Get-PeMachine $pe) -eq 0xAA64) 'Read genuine ARM64 PE machine field'
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 68)
    [IO.File]::WriteAllBytes($pe, $bytes)
    Assert ((Get-PeMachine $pe) -ne 0xAA64) 'x64 PE does not count as ARM64'
    [BitConverter]::GetBytes([int]-1).CopyTo($bytes, 0x3C)
    [IO.File]::WriteAllBytes($pe, $bytes)
    Assert-Throws { Get-PeMachine $pe } '*Invalid PE header*'
    [IO.File]::WriteAllBytes($pe, [byte[]]::new(4))
    Assert-Throws { Get-PeMachine $pe } '*Not a PE file*'
    Assert ((Get-Classification build 'fatal error C1083: missing architecture header').route -eq 'ai_actionable') 'Compiler evidence routes to bounded remediation'
    Assert ((Get-Classification test 'Unexpected crash').route -eq 'needs_human') 'Unknown test failures require a human'
    Assert ((Get-Classification host 'error C1083').route -eq 'needs_human') 'Host failures are not compiler-fix candidates'
    Assert ((Get-Classification build 'error C1083: access is denied').route -eq 'needs_human') 'Access failures override compiler-remediation rules'
    Assert ((Get-BlockerKey 'https://github.com/A/B' app build) -eq (Get-BlockerKey 'https://github.com/a/b/' app build)) 'Stable blocker key across case/trailing slash'
    Assert ((Get-BlockerKey repo app build) -ne (Get-BlockerKey repo app test)) 'Different checkpoints have different blocker keys'

    foreach ($scenario in @(
        @{ budget = 0; enabled = $true; successAt = 9; human = $false; validations = 1; agents = 0; route = 'needs_human' },
        @{ budget = 2; enabled = $true; successAt = 9; human = $false; validations = 3; agents = 2; route = 'needs_human' },
        @{ budget = 3; enabled = $true; successAt = 1; human = $false; validations = 2; agents = 1; route = 'validated' },
        @{ budget = 3; enabled = $false; successAt = 9; human = $false; validations = 1; agents = 0; route = 'needs_human' },
        @{ budget = 3; enabled = $true; successAt = 9; human = $true; validations = 1; agents = 0; route = 'needs_human' }
    )) {
        $counter = @{ validations = 0; agents = 0 }
        $state = @{ route = 'ai_actionable'; reason = 'compiler evidence'; blockedStep = 'build'; checks = @() }
        $history = [Collections.Generic.List[object]]::new()
        Invoke-BoundedRemediation -MaxAttempts $scenario.budget -EnableAgent $scenario.enabled -Result $state -Attempts $history -Phase initial `
            -Validate {
                param($round)
                $counter.validations++
                if ($round -eq $scenario.successAt) { $state.route = 'validated'; return $true }
                $state.route = if ($scenario.human) { 'needs_human' } else { 'ai_actionable' }
                return $false
            } -Remediate { param($round) $counter.agents++ }
        Assert ($counter.validations -eq $scenario.validations) 'Exact validation count for attempt budget'
        Assert ($counter.agents -eq $scenario.agents) 'Exact agent-call ceiling / stop-on-success'
        Assert ($state.route -eq $scenario.route) 'Budget outcome is explicit, never false success'
    }

    $pwsh = (Get-Process -Id $PID).Path
    $env:OPENARM_TEST_SECRET = 'test-only-not-a-credential'
    $processLog = Join-Path $root 'process.log'
    $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-Command', 'if ($env:OPENARM_TEST_SECRET) { exit 9 }; Write-Output "##vso[task.setvariable variable=bad]inert"; exit 0') $root $processLog
    Assert ($code -eq 0) 'Secret-like variables removed from build subprocess'
    Assert ((Get-Content $processLog -Raw) -match '##vso') 'Untrusted logging commands remain inert in the artifact'
    $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') $root $processLog 1
    Assert ($code -eq 124) 'Process timeout terminates its process tree'

    $workerOutput = Join-Path $root 'worker'
    Assert-Throws { & "$repo\scripts\Test-NativeWorker.ps1" -Output $workerOutput -CMake 'openarm-missing-cmake-test.exe' } '*Worker prerequisites blocked*'
    $worker = Read-Json (Join-Path $workerOutput 'worker.json')
    Assert (-not $worker.inventoryReady -and @($worker.blockers | Where-Object { $_ -like '*Missing native executable for cmake*' }).Count -eq 1) 'Missing prerequisites produce durable failure, not readiness'
    Assert ($worker.host.osArchitecture -eq [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) 'Worker inventory records the actual host'

    $missingWorkerOutput = Join-Path $root 'worker-missing-cmake'
    $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-File', "$repo\scripts\Test-NativeWorker.ps1",
        '-Output', $missingWorkerOutput, '-CMake', 'openarm-missing-cmake-test.exe') $repo (Join-Path $root 'worker-missing-cmake.log')
    Assert ($code -ne 0) 'Missing CMake fails the public command'
    $missingWorker = Read-Json (Join-Path $missingWorkerOutput 'worker.json')
    Assert (-not $missingWorker.inventoryReady -and @($missingWorker.blockers | Where-Object {
        $_ -like '*Missing native executable for cmake*'
    }).Count -eq 1) 'Public missing-CMake command preserves its specific prerequisite blocker'
    Assert ((Get-Content (Join-Path $missingWorkerOutput 'failure.log') -Raw) -like '*Worker prerequisites blocked*') 'Public missing-CMake command preserves the failure diagnostic'
    Assert (-not $missingWorker.tools.ContainsKey('cmake') -and -not $missingWorker.tools.ContainsKey('ctest') -and
        -not (Test-Path (Join-Path $missingWorkerOutput 'cmake-capabilities.json'))) 'Missing CMake does not fabricate tool or dependent results'

    if ($IsWindows) {
        $unusableCMake = Join-Path $root 'unusable-cmake.exe'
        Set-Content -LiteralPath $unusableCMake -Value 'Not a Windows executable.'
        $brokenWorkerOutput = Join-Path $root 'worker-unusable-cmake'
        $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-File', "$repo\scripts\Test-NativeWorker.ps1",
            '-Output', $brokenWorkerOutput, '-CMake', $unusableCMake) $repo (Join-Path $root 'worker-unusable-cmake.log')
        Assert ($code -ne 0) 'Unusable configured CMake fails the public command'
        $brokenWorker = Read-Json (Join-Path $brokenWorkerOutput 'worker.json')
        Assert (-not $brokenWorker.inventoryReady) 'Unusable configured CMake never reports readiness'
        Assert (@($brokenWorker.blockers | Where-Object {
            $_ -like '*cmake*' -and $_.Contains($unusableCMake)
        }).Count -eq 1) 'Unusable configured CMake has a tool-specific blocker identifying its path'
        $cmakeTool = $brokenWorker.tools.cmake
        Assert ($cmakeTool.path -eq $unusableCMake -and $null -eq $cmakeTool.exitCode) 'Unstarted CMake has its real path and no fabricated exit code'
        $diagnostic = Get-Content -LiteralPath (Join-Path $brokenWorkerOutput $cmakeTool.versionLog) -Raw
        Assert (-not [string]::IsNullOrWhiteSpace($cmakeTool.error) -and $diagnostic.Contains($cmakeTool.error)) 'Reported CMake diagnostic preserves the actual launch exception'
        Assert ($diagnostic.Contains($unusableCMake) -and $diagnostic -match 'Start') 'Durable CMake diagnostic identifies the failed process launch'
        Assert (-not $brokenWorker.tools.ContainsKey('ctest') -and -not (Test-Path (Join-Path $brokenWorkerOutput 'cmake-capabilities.json'))) 'Unusable CMake does not run or fabricate dependent probes'
        Assert ((Get-Content (Join-Path $brokenWorkerOutput 'failure.log') -Raw) -like '*Worker prerequisites blocked*') 'Unusable CMake ends with the complete prerequisite failure summary'
        Assert ($brokenWorker.host.osArchitecture -eq $worker.host.osArchitecture) 'CMake launch failure preserves the actual host architecture'
        if ($worker.host.osArchitecture -ne 'Arm64') {
            Assert (@($brokenWorker.blockers | Where-Object { $_ -like '*actual Windows Arm64 OS*' }).Count -eq 1) 'CMake launch failure cannot hide the actual host blocker'
        }
        Assert ($brokenWorker.tools.git.path -eq $worker.tools.git.path -and $brokenWorker.tools.git.exitCode -eq $worker.tools.git.exitCode) 'CMake launch failure preserves independent Git findings'
        Assert ((Get-Content (Join-Path $brokenWorkerOutput $brokenWorker.tools.git.versionLog) -Raw) -eq
            (Get-Content (Join-Path $workerOutput $worker.tools.git.versionLog) -Raw)) 'CMake launch failure preserves the Git version diagnostic'
        foreach ($inventory in 'visualStudio', 'windowsSdk') {
            Assert ($brokenWorker[$inventory].Count -eq $worker[$inventory].Count) "CMake launch failure preserves $inventory inventory size"
            foreach ($entry in $worker[$inventory]) {
                Assert (@($brokenWorker[$inventory] | Where-Object {
                    $_.path -eq $entry.path -and $_.version -eq $entry.version
                }).Count -eq 1) "CMake launch failure preserves actual $inventory paths and versions"
            }
        }
        $independentBlockers = @($worker.blockers | Where-Object { $_ -match 'Visual Studio|toolchain|Windows SDK' })
        $brokenIndependentBlockers = @($brokenWorker.blockers | Where-Object { $_ -match 'Visual Studio|toolchain|Windows SDK' })
        Assert (($independentBlockers -join "`n") -eq ($brokenIndependentBlockers -join "`n")) 'CMake launch failure preserves Visual Studio and Windows SDK blockers'
        $vsInventory = Join-Path $workerOutput 'visual-studio.json'
        $brokenVsInventory = Join-Path $brokenWorkerOutput 'visual-studio.json'
        Assert ((Test-Path $brokenVsInventory) -eq (Test-Path $vsInventory)) 'CMake launch failure preserves raw Visual Studio inventory availability'
        if (Test-Path $vsInventory) {
            Assert ((Get-Content $brokenVsInventory -Raw) -eq (Get-Content $vsInventory -Raw)) 'CMake launch failure preserves the actual raw Visual Studio inventory'
        }
        foreach ($existingOutput in $missingWorkerOutput, $brokenWorkerOutput) {
            $before = @(Get-ChildItem -LiteralPath $existingOutput -File | Get-FileHash | Sort-Object Path |
                ForEach-Object { "$($_.Path):$($_.Hash)" })
            $overwriteLog = Join-Path $root 'worker-overwrite.log'
            $code = Invoke-LoggedProcess $pwsh @('-NoProfile', '-File', "$repo\scripts\Test-NativeWorker.ps1",
                '-Output', $existingOutput, '-CMake', $unusableCMake) $repo $overwriteLog
            Assert ($code -ne 0 -and (Get-Content $overwriteLog -Raw) -like '*output already exists*') 'Public worker command refuses to overwrite existing evidence'
            $after = @(Get-ChildItem -LiteralPath $existingOutput -File | Get-FileHash | Sort-Object Path |
                ForEach-Object { "$($_.Path):$($_.Hash)" })
            Assert (($before -join "`n") -eq ($after -join "`n")) 'Overwrite refusal leaves every existing JSON and log artifact unchanged'
        }
    }

    $env:BUILD_SOURCESDIRECTORY = $repo
    $env:BUILD_REPOSITORY_URI = 'https://github.com/openarm-test/fixture'
    $env:BUILD_SOURCEVERSION = 'a' * 40
    $env:OPENARM_CONFIG = 'targets\smoke.json'
    $env:OPENARM_OUTPUT = Join-Path $root 'input'
    $env:OPENARM_REQUIRE_APPROVERS = 'false'
    $env:OPENARM_HANDOFF = 'false'
    $env:OPENARM_TEAMS = 'false'
    & "$repo\scripts\Prepare-Target.ps1"
    Assert (Test-Path "$root\input\source\main.cpp") 'Prepare persists source snapshot'
    Assert (Test-Path "$root\input\baseline\main.cpp") 'Prepare preserves original baseline'
    $env:OPENARM_INPUT = "$root\input"
    $env:OPENARM_OUTPUT = "$root\native"
    $env:OPENARM_BUILD = "$root\build"
    $env:OPENARM_MAX_ATTEMPTS = '0'
    $env:OPENARM_ENABLE_AGENT = 'false'
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64' -or -not $IsWindows) {
        & "$repo\scripts\Invoke-NativeLoop.ps1"
        $native = Read-Json "$root\native\result.json"
        Assert (-not $native.nativeVerified -and $native.route -eq 'needs_human' -and $native.blockedStep -eq 'host') 'Actual x64 host is rejected, with durable blocker evidence'
    }
    $env:OPENARM_OUTPUT = "$root\bad-approvers"
    $env:OPENARM_REQUIRE_APPROVERS = 'true'
    $env:OPENARM_APPROVERS = ''
    Assert-Throws { & "$repo\scripts\Prepare-Target.ps1" } '*named approvers*'

    # Offline REST doubles: no request can leave this process.
    $global:OpenArmMock = @{
        item = $null; creates = 0; sends = [Collections.Generic.List[object]]::new()
        comments = [Collections.Generic.List[object]]::new(); deliveryFailure = $false; calls = 0
    }
    function global:Invoke-RestMethod {
        param($Method, $Uri, $Body, $Headers, $ContentType, $TimeoutSec)
        $mock = $global:OpenArmMock
        $mock.calls++
        $payload = if ($Body) { ConvertFrom-Json -InputObject $Body } else { $null }
        if ($Uri -eq 'https://openarm.invalid/bridge') {
            $mock.sends.Add($payload)
            if ($mock.deliveryFailure) { throw 'Mock ambiguous delivery' }
            return [pscustomobject]@{ threadId = 'root-1'; threadUrl = 'https://teams.microsoft.com/l/message/root-1' }
        }
        if (-not $Uri.StartsWith('https://dev.azure.com/openarm-tests/')) { throw "Unexpected mocked endpoint: $Uri" }
        if ($Uri -match '/wiql\?') {
            return [pscustomobject]@{ workItems = @($(if ($mock.item) { [pscustomobject]@{ id = 123 } })) }
        }
        if ($Uri -match '/comments\?') {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ comments = @($mock.comments | Sort-Object id -Descending) }
            }
            $comment = [pscustomobject]@{ id = $mock.comments.Count + 1; text = $payload.text; createdDate = [DateTimeOffset]::UtcNow.ToString('o') }
            $mock.comments.Add($comment)
            return $comment
        }
        if ($Method -eq 'POST' -and $Uri -match '/workitems/\$') {
            $mock.creates++
            $mock.item = [pscustomobject]@{ id = 123; rev = 1; fields = [pscustomobject]@{} }
        }
        if ($Method -in @('PATCH', 'POST')) {
            foreach ($operation in $payload) {
                if ($operation.op -eq 'test') {
                    if ($operation.value -ne $mock.item.rev) { throw 'Mock revision conflict' }
                } else {
                    $mock.item.fields | Add-Member -NotePropertyName ($operation.path -replace '^/fields/', '') -NotePropertyValue $operation.value -Force
                }
            }
            $mock.item.rev++
        }
        $mock.item
    }
    $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/openarm-tests/'
    $env:SYSTEM_TEAMPROJECT = 'Prototype'
    $env:SYSTEM_ACCESSTOKEN = 'offline-test-token'
    $env:BUILD_BUILDID = '1'
    $env:OPENARM_OUTPUT = "$root\handoff"
    $env:OPENARM_EVIDENCE = "$root\input"
    $env:OPENARM_TEAMS = 'true'
    $env:OPENARM_TEAMS_BRIDGE_URL = 'https://openarm.invalid/bridge'
    $result = @{
        repository = 'https://github.com/openarm-test/fixture'; target = 'openarm-smoke'
        commit = 'a' * 40; route = 'needs_human'; nativeVerified = $false
        reason = 'error C1083: architecture-specific include'; blockedStep = 'build'
        completedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'); attempts = @()
    }
    Write-Json "$root\input\result.json" $result
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked
    Assert ($global:OpenArmMock.creates -eq 1) 'Repeat blocker uses the same work item'
    Assert ($global:OpenArmMock.sends.Count -eq 1) 'Confirmed notification is not sent twice'
    Assert ($global:OpenArmMock.sends[0].action -eq 'create') 'First request creates one root thread'
    $env:BUILD_BUILDID = '2'
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked
    Assert ($global:OpenArmMock.sends.Count -eq 2 -and $global:OpenArmMock.sends[1].threadId -eq 'root-1' -and $global:OpenArmMock.sends[1].action -eq 'reply') 'Subsequent run replies in the same thread'
    $env:BUILD_BUILDID = '3'
    $global:OpenArmMock.deliveryFailure = $true
    Assert-Throws { & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked } '*delivery failed or timed out*'
    Assert-Throws { & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked } '*unconfirmed*'
    Assert ($global:OpenArmMock.sends.Count -eq 3) 'Ambiguous delivery does not cause a duplicate on retry'

    $env:OPENARM_HANDOFF_STATE = "$root\handoff\work-item.json"
    $env:OPENARM_OUTPUT = "$root\resume"
    Assert-Throws { & "$repo\scripts\Resume-Target.ps1" } '*must claim*'
    $owner = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Volunteer' }
    $other = [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'Other commenter' }
    $global:OpenArmMock.item.fields | Add-Member -NotePropertyName 'System.AssignedTo' -NotePropertyValue $owner
    Assert-Throws { & "$repo\scripts\Resume-Target.ps1" } '*new OPENARM_GUIDANCE*'
    $global:OpenArmMock.comments.Add([pscustomobject]@{
        id = 100; text = 'OPENARM_GUIDANCE: An old unrelated resolution.'
        createdDate = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
    })
    Assert-Throws { & "$repo\scripts\Resume-Target.ps1" } '*new OPENARM_GUIDANCE*'
    $freshGuidance = [pscustomobject]@{
        id = 101; commentId = 101; version = 1
        text = 'OPENARM_GUIDANCE: Native compiler component is installed; retry the blocked build.'
        createdDate = [DateTimeOffset]::UtcNow.ToString('o')
        createdBy = $other; modifiedBy = $other
    }
    $global:OpenArmMock.comments.Add($freshGuidance)
    Assert-Throws { & "$repo\scripts\Resume-Target.ps1" } '*authored and last modified*'
    $freshGuidance.createdBy = $owner
    Assert-Throws { & "$repo\scripts\Resume-Target.ps1" } '*authored and last modified*'
    $freshGuidance.modifiedBy = $owner
    Set-Content "$root\input\source\agent-fix.txt" 'Preserved agent edit'
    & "$repo\scripts\Resume-Target.ps1"
    Assert (Test-Path "$root\resume\source\agent-fix.txt") 'Resume keeps agent edits, not the original checkout'
    Assert ((Read-Json "$root\resume\context.json").resumedFrom -eq 'build') 'Resume retains exact blocked checkpoint'
    Assert ((Read-Json "$root\resume\context.json").workItemId -eq 123) 'Resume ownership remains linked to original work item'
    $digest = (Get-FileHash "$root\resume\approval.json" -Algorithm SHA256).Hash
    $approval = Assert-ResumeBundle "$root\resume" $digest '3'
    Assert ($approval.commentId -eq 101 -and $approval.commentVersion -eq 1) 'Snapshot binds the exact guidance ID and version'
    Assert ($approval.sourceCommit -eq ('a' * 40)) 'Snapshot binds the selected source commit'
    Assert-Throws { Assert-ResumeBundle "$root\resume" '' '3' } '*approved bundle digest*'
    Assert-Throws { Assert-ResumeBundle "$root\resume" ('0' * 64) '3' } '*approved digest*'
    Assert-Throws { Assert-ResumeBundle "$root\resume" $digest '999' } '*different pipeline run*'

    $frozenGuidance = [IO.File]::ReadAllBytes("$root\resume\guidance.txt")
    $frozenManifest = [IO.File]::ReadAllBytes("$root\resume\approval.json")
    $freshGuidance.text = "OPENARM_GUIDANCE: Changed after the snapshot.`nOPENARM_COMMIT: $('b' * 40)"
    $freshGuidance.version = 2
    $global:OpenArmMock.comments.Add([pscustomobject]@{
        id = 102; commentId = 102; version = 1
        text = "OPENARM_GUIDANCE: Substitute this later comment.`nOPENARM_COMMIT: $('c' * 40)"
        createdBy = $other; modifiedBy = $other; createdDate = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $callsBeforeVerification = $global:OpenArmMock.calls
    $null = Assert-ResumeBundle "$root\resume" $digest '3'
    Assert ($global:OpenArmMock.calls -eq $callsBeforeVerification) 'Post-approval verification never reads live work-item comments'
    Assert ((Get-Content "$root\resume\guidance.txt" -Raw) -notmatch 'OPENARM_COMMIT') 'Later comments cannot substitute approved guidance'
    Assert ((Read-Json "$root\resume\context.json").commit -eq ('a' * 40)) 'Later comments cannot substitute the approved commit'

    Set-Content "$root\resume\guidance.txt" 'Tampered artifact'
    Assert-Throws { Assert-ResumeBundle "$root\resume" $digest '3' } '*content changed after review*'
    [IO.File]::WriteAllBytes("$root\resume\guidance.txt", $frozenGuidance)
    Set-Content "$root\resume\unexpected.txt" 'Unapproved extra file'
    Assert-Throws { Assert-ResumeBundle "$root\resume" $digest '3' } '*file set changed*'
    Remove-Item -LiteralPath "$root\resume\unexpected.txt"
    $changedManifest = Read-Json "$root\resume\approval.json"
    $changedManifest.sourceCommit = 'b' * 40
    Write-Json "$root\resume\approval.json" $changedManifest
    Assert-Throws { Assert-ResumeBundle "$root\resume" $digest '3' } '*approved digest*'
    [IO.File]::WriteAllBytes("$root\resume\approval.json", $frozenManifest)

    $env:OPENARM_INPUT = "$root\resume"
    $env:OPENARM_OUTPUT = "$root\approved-native"
    $env:OPENARM_REQUIRE_RESUME_APPROVAL = 'true'
    $env:OPENARM_APPROVED_RESUME_DIGEST = ''
    Assert-Throws { & "$repo\scripts\Invoke-NativeLoop.ps1" } '*approved bundle digest*'
    Assert (-not (Test-Path "$root\approved-native")) 'Invalid approval is rejected before source is copied or used'
    $env:OPENARM_REQUIRE_RESUME_APPROVAL = 'false'
    Assert-Throws { & "$repo\scripts\Invoke-NativeLoop.ps1" } '*without its approved snapshot*'
    $env:OPENARM_REQUIRE_RESUME_APPROVAL = 'true'
    $env:OPENARM_APPROVED_RESUME_DIGEST = $digest
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64' -or -not $IsWindows) {
        & "$repo\scripts\Invoke-NativeLoop.ps1"
        $approvedResult = Read-Json "$root\approved-native\result.json"
        Assert ($approvedResult.resumeApproval.digest -eq $digest) 'Native evidence preserves the approved digest'
        Assert (-not $approvedResult.nativeVerified -and $approvedResult.blockedStep -eq 'host') 'Approval never bypasses native architecture validation'
        Assert ($global:OpenArmMock.calls -eq $callsBeforeVerification) 'Native consumption does not re-fetch guidance or source'
    }
    $env:OPENARM_REQUIRE_RESUME_APPROVAL = 'false'

    $env:OPENARM_OUTPUT = "$root\draft"
    Assert-Throws { & "$repo\scripts\New-ContributionDraft.ps1" } '*without native validation*'
    $env:OPENARM_OUTPUT = "$root\handoff-disabled"
    $env:OPENARM_TEAMS = 'false'
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Blocked
    Assert ($global:OpenArmMock.sends.Count -eq 3) 'Disabled Teams never sends even with pending messages'
    Assert (Test-Path "$root\handoff-disabled\teams-request.json") 'Offline handoff still produces actionable request'

    $pendingKey = ($global:OpenArmMock.comments | Where-Object { $_.text.StartsWith('OPENARM_TEAMS_PENDING: ') } | Select-Object -Last 1).text.Substring('OPENARM_TEAMS_PENDING: '.Length)
    $base = Get-BoardsBase
    Add-WorkItemComment $base 123 ('OPENARM_TEAMS_SENT: ' + (ConvertTo-Json -Compress -InputObject @{
        messageKey = $pendingKey; threadId = 'root-1'; threadUrl = 'https://teams.microsoft.com/l/message/root-1'
    }))
    $global:OpenArmMock.deliveryFailure = $false
    $result.route = 'validated'
    $result.nativeVerified = $true
    $result.blockedStep = $null
    $result.baselineCommit = 'a' * 40
    $result.host = @{ os = 'MOCK ONLY'; osArchitecture = 'Arm64' }
    $result.performance = @{ median = 10 }
    Write-Json "$root\input\result.json" $result
    $env:OPENARM_OUTPUT = "$root\report"
    $env:OPENARM_TEAMS = 'true'
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Result
    Assert ($global:OpenArmMock.sends.Count -eq 4 -and $global:OpenArmMock.sends[3].action -eq 'reply' -and $global:OpenArmMock.sends[3].threadId -eq 'root-1') 'Resumed validation result stays in the original thread'
    Assert ($global:OpenArmMock.item.fields.'System.Tags' -match 'OpenArm-Validated' -and $global:OpenArmMock.item.fields.'System.Tags' -notmatch 'OpenArm-NeedsHuman') 'Successful validation updates, not accumulates, status tags'
    Assert ($global:OpenArmMock.item.fields.'System.AssignedTo'.displayName -eq 'Volunteer') 'Reporting preserves the volunteer owner'
    & "$repo\scripts\Sync-WorkItem.ps1" -Mode Result
    Assert ($global:OpenArmMock.sends.Count -eq 4) 'Validation-result reply is idempotent'
    $env:OPENARM_OUTPUT = "$root\approved-draft"
    & "$repo\scripts\New-ContributionDraft.ps1"
    Assert (Test-Path "$root\approved-draft\pull-request-draft.md") 'Reviewed native evidence produces a draft artifact'
    $code = Invoke-LoggedProcess git @('apply', '--check', '-p2', "$root\approved-draft\changes.patch") "$root\input\baseline" "$root\patch-check.log"
    Assert ($code -eq 0) 'Exported patch applies cleanly to the original source baseline'

    Write-Host "OpenArm: $checks offline checks passed."
} finally {
    if (Test-Path Function:\Invoke-RestMethod) { Remove-Item Function:\Invoke-RestMethod }
    Remove-Variable -Name OpenArmMock -Scope Global -ErrorAction SilentlyContinue
    Get-ChildItem Env: | Where-Object Name -match '^(OPENARM_|BUILD_|SYSTEM_|AGENT_|COPILOT_GITHUB_TOKEN$)' |
        ForEach-Object { Remove-Item -LiteralPath "Env:\$($_.Name)" }
    foreach ($key in $environment.Keys) { Set-Item -LiteralPath "Env:\$key" -Value $environment[$key] }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
