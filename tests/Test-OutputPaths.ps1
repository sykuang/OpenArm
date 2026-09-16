Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts\Common.ps1"
$root = Join-Path $repo ".local\output-checks-$([guid]::NewGuid())"
$candidate = Join-Path $root 'candidate'
$processCwd = Join-Path $root 'process-cwd'
$null = New-Item -ItemType Directory -Path $candidate, $processCwd
$checks = 0
$failures = [Collections.Generic.List[string]]::new()
function Assert([bool] $Condition, [string] $Message) {
    $script:checks++
    if (-not $Condition) { $failures.Add($Message); Write-Host "FAIL: $Message" }
}
function Quote([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
function Run([string] $Name, [string] $Script, [string] $Output, [string] $OutputRoot = '') {
    $command = "Set-Location $(Quote $candidate); & $(Quote "$repo\scripts\$Script") -Output $(Quote $Output) -CMake 'openarm-missing-cmake-test.exe'"
    if ($Script -eq 'Test-LocalCandidate.ps1') {
        $boundary = if ($OutputRoot) { $OutputRoot } else { $candidate }
        $command += " -CandidateRoot $(Quote $boundary)"
    } elseif ($OutputRoot) { $command += " -OutputRoot $(Quote $OutputRoot)" }
    $log = Join-Path $root "$Name.log"
    $code = Invoke-LoggedProcess (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) $processCwd $log
    @{ code = $code; log = Get-Content -LiteralPath $log -Raw }
}
try {
    $result = Run 'relative' 'Test-NativeWorker.ps1' 'relative-output'
    Assert ($result.code -ne 0 -and $result.log -like '*Worker prerequisites blocked*') 'Relative worker command reaches its real prerequisite failure'
    Assert (Test-Path "$candidate\relative-output\worker.json") 'Relative output uses PowerShell location, not native process cwd'
    Assert (-not (Test-Path "$processCwd\relative-output")) 'Relative output never creates the process-cwd sibling'

    $null = New-Item -ItemType Directory -Path "$candidate\project-existing"
    $result = Run 'project-relative-existing' 'Test-Project.ps1' 'project-existing'
    Assert ($result.code -ne 0 -and $result.log -like '*output already exists*' -and
        -not (Test-Path "$processCwd\project-existing")) 'Repository validation resolves relative output before its overwrite guard'

    $external = Join-Path $root 'external-allowed'
    $result = Run 'absolute' 'Test-NativeWorker.ps1' $external
    Assert ($result.code -ne 0 -and (Test-Path "$external\worker.json")) 'Absolute external output remains supported without OutputRoot'

    $result = Run 'contained' 'Test-NativeWorker.ps1' 'nested\contained' '.'
    Assert ($result.code -ne 0 -and $result.log -like '*Worker prerequisites blocked*' -and
        (Test-Path "$candidate\nested\contained\worker.json")) 'Relative OutputRoot and nested output resolve against the same caller location'
    if (Test-Path "$candidate\nested\contained\worker.json") {
        $worker = Read-Json "$candidate\nested\contained\worker.json"
        Assert (-not $worker.inventoryReady) 'Confinement never converts a native blocker to readiness'
        $before = (Get-FileHash "$candidate\nested\contained\worker.json").Hash
        $result = Run 'overwrite' 'Test-NativeWorker.ps1' 'nested\contained' $candidate
        Assert ($result.code -ne 0 -and $result.log -like '*output already exists*' -and
            (Get-FileHash "$candidate\nested\contained\worker.json").Hash -eq $before) 'Contained output still refuses evidence overwrite'
    }

    foreach ($script in 'Test-NativeWorker.ps1', 'Test-Project.ps1', 'Test-LocalCandidate.ps1') {
        foreach ($case in @(
            @{ name = 'traversal'; output = '..\escaped'; root = $candidate; forbidden = "$root\escaped" },
            @{ name = 'sibling-prefix'; output = "$candidate-other\output"; root = $candidate; forbidden = "$candidate-other" },
            @{ name = 'absolute-outside'; output = "$root\outside"; root = $candidate; forbidden = "$root\outside" },
            @{ name = 'equal-root'; output = $candidate; root = $candidate; forbidden = "$candidate\worker.json" }
        )) {
            $result = Run "$script-$($case.name)" $script $case.output $case.root
            Assert ($result.code -ne 0 -and $result.log -like '*strictly inside OutputRoot*') "$script rejects $($case.name) explicitly"
            Assert (-not (Test-Path -LiteralPath $case.forbidden)) "$script rejects $($case.name) before creating artifacts"
        }
        $result = Run "$script-provider" $script 'Env:\OPENARM_TEST_OUTPUT'
        Assert ($result.code -ne 0 -and $result.log -like '*filesystem path*') "$script rejects non-filesystem output before creation"
        $result = Run "$script-missing-root" $script "$candidate\missing-root\output" "$candidate\missing-root"
        Assert ($result.code -ne 0 -and $result.log -like '*OutputRoot must be an existing directory*' -and
            -not (Test-Path "$candidate\missing-root")) "$script rejects a missing root before creation"
        if ($IsWindows) {
            $result = Run "$script-ambiguous" $script "$candidate\.. \alias-escape" $candidate
            Assert ($result.code -ne 0 -and $result.log -like '*ambiguous or invalid component*' -and
                -not (Test-Path "$root\alias-escape")) "$script rejects ambiguous Windows traversal components"
        }
    }

    if ($IsWindows) {
        $outside = Join-Path $root 'junction-target'
        $null = New-Item -ItemType Directory -Path $outside
        $link = Join-Path $candidate 'linked'
        $rootLink = Join-Path $root 'candidate-link'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        $null = New-Item -ItemType Junction -Path $rootLink -Target $candidate
        foreach ($script in 'Test-NativeWorker.ps1', 'Test-Project.ps1', 'Test-LocalCandidate.ps1') {
            $result = Run "$script-junction" $script "$link\escaped" $candidate
            Assert ($result.code -ne 0 -and $result.log -like '*symlinks or junctions*') "$script rejects an existing ancestor junction"
            Assert (-not (Test-Path "$outside\escaped")) "$script cannot create through the rejected junction"
            $result = Run "$script-root-junction" $script "$rootLink\escaped" $rootLink
            Assert ($result.code -ne 0 -and $result.log -like '*symlinks or junctions*') "$script rejects a linked OutputRoot"
            Assert (-not (Test-Path "$candidate\escaped")) "$script cannot create through a linked root"
        }
    }
    if ($failures.Count) { throw "$($failures.Count) of $checks output-path checks failed." }
    Write-Host "OpenArm: $checks output-path checks passed."
} finally {
    foreach ($name in @("$candidate\linked", "$root\candidate-link")) {
        if (Test-Path -LiteralPath $name) { Remove-Item -LiteralPath $name -Force }
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
