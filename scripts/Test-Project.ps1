param(
    [string] $Output = (Join-Path $PSScriptRoot "..\out\ci-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"),
    [string] $CMake = 'cmake',
    [string] $Generator = 'Visual Studio 17 2022',
    [string] $Python = 'python',
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"

$root = Split-Path $PSScriptRoot -Parent
$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Validation output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$logs = Join-Path $Output 'logs'
$null = New-Item -ItemType Directory -Path $logs
$report = @{
    schemaVersion = 1; purpose = 'Repository CI, not native Arm64 or agent-task evidence'
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); completedAt = $null
    passed = $false; error = $null; checks = @(); sourceFiles = @()
    checkoutCommit = $env:BUILD_SOURCEVERSION
    host = @{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
    generator = $Generator; buildArchitecture = 'x64'
}

function Invoke-Check([string] $Name, [string] $File, [string[]] $Arguments, [string] $WorkingDirectory = $root) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $logs "$Name.log"
    $exitCode = $null
    try {
        $exitCode = Invoke-LoggedProcess $File $Arguments $WorkingDirectory $log
        if ($exitCode -ne 0) { throw "$Name failed (exit $exitCode). See $log." }
    } finally {
        $clock.Stop()
        $report.checks += @{ step = $Name; exitCode = $exitCode
            elapsedMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 3)
            log = "logs\$Name.log" }
    }
}

$oldPythonPath = $env:PYTHONPATH
try {
    if (-not $IsWindows) { throw 'Repository CI requires Windows with a Visual Studio C++ toolchain.' }
    $files = @(
        Get-ChildItem -LiteralPath $PSScriptRoot, (Join-Path $root 'tests'), (Join-Path $root 'samples\arm64-smoke') -Recurse -File |
            Where-Object Extension -in '.ps1', '.py', '.cpp', '.txt'
        Get-Item -LiteralPath (Join-Path $root 'azure-pipelines.yml'), (Join-Path $root 'azure-pipelines-ci.yml'),
            (Join-Path $root 'native-stage.yml'), (Join-Path $root 'requirements-dev.txt'), (Join-Path $root 'targets\smoke.json')
    )
    $report.sourceFiles = @($files | Sort-Object FullName -Unique | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($root, $_.FullName)
           sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    Invoke-Check 'powershell' (Get-Process -Id $PID).Path @('-NoProfile', '-File', (Join-Path $root 'tests\Test-OpenArm.ps1'))
    Invoke-Check 'output-paths' (Get-Process -Id $PID).Path @('-NoProfile', '-File', (Join-Path $root 'tests\Test-OutputPaths.ps1'))

    $localPython = Join-Path $root '.local\python'
    $env:PYTHONPATH = $localPython
    if ($oldPythonPath) { $env:PYTHONPATH += [IO.Path]::PathSeparator + $oldPythonPath }
    $probe = Invoke-LoggedProcess $Python @('-c', 'import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("yaml") else 3)') $root (Join-Path $logs 'python-dependency-probe.log')
    if ($probe -eq 3) {
        Invoke-Check 'python-dependencies' $Python @('-m', 'pip', 'install', '--disable-pip-version-check',
            '--target', $localPython, '-r', (Join-Path $root 'requirements-dev.txt'))
    } elseif ($probe -ne 0) {
        throw "Python dependency probe failed (exit $probe). See logs\python-dependency-probe.log."
    }
    Invoke-Check 'python-version' $Python @('-c', 'import yaml; print("PyYAML " + yaml.__version__); assert yaml.__version__ == "6.0.3", "Use the pinned requirements-dev.txt version"')
    Invoke-Check 'pipeline-yaml' $Python @((Join-Path $root 'tests\test_pipeline.py'))

    $cmakePath = (Get-Command $CMake -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $ctest = Join-Path (Split-Path $cmakePath -Parent) 'ctest.exe'
    Invoke-Check 'cmake-version' $cmakePath @('--version')
    $source = Join-Path $Output 'source'
    $build = Join-Path $Output 'build'
    $package = Join-Path $Output 'package'
    Copy-Source (Join-Path $root 'samples\arm64-smoke') $source
    Invoke-Check 'configure' $cmakePath @('-S', $source, '-B', $build, '-G', $Generator, '-A', 'x64')
    Invoke-Check 'build' $cmakePath @('--build', $build, '--config', 'Release', '--parallel', '2')
    Invoke-Check 'test' $ctest @('--test-dir', $build, '-C', 'Release', '--output-on-failure', '--no-tests=error')
    Invoke-Check 'install' $cmakePath @('--install', $build, '--config', 'Release', '--prefix', $package)
    $exe = Join-Path $package 'bin\openarm-smoke.exe'
    $machine = Get-PeMachine $exe
    $report.checks += @{ step = 'architecture'; machine = ('0x{0:X4}' -f $machine)
        sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() }
    if ($machine -ne 0x8664) { throw 'CI sample must be an x64 PE binary; native Arm64 validation is a separate workflow.' }
    Invoke-Check 'launch' $exe @('--smoke-test') $package
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
    Set-Content -LiteralPath (Join-Path $logs 'failure.log') -Value $_.ToString()
    throw
} finally {
    $env:PYTHONPATH = $oldPythonPath
    $report.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-Json (Join-Path $Output 'result.json') $report
    Write-Host "Repository validation evidence: $Output"
}
