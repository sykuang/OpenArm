param(
    [string] $Output = (Join-Path $PSScriptRoot "..\out\worker-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"),
    [string] $Generator = 'Visual Studio 17 2022',
    [string] $CMake = 'cmake',
    [switch] $RequireCopilot,
    [string] $OutputRoot = ''
)
. "$PSScriptRoot\Common.ps1"

$Output = Resolve-OutputPath -Path $Output -Root $OutputRoot
if (Test-Path -LiteralPath $Output) { throw 'Worker inventory output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $Output
$report = @{
    schemaVersion = 1; checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    purpose = 'Read-only prerequisite inventory; not a build, native validation, or isolation audit'
    inventoryReady = $false; blockers = @(); tools = @{}; visualStudio = @(); windowsSdk = @()
    generator = $Generator; requireCopilot = [bool] $RequireCopilot
    host = @{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powershellVersion = $PSVersionTable.PSVersion.ToString() }
}

function Get-WorkerTool([string] $Name, [string] $File) {
    $command = Get-Command $File -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command -or $command.Source -match '\.(cmd|bat)$') {
        $report.blockers += "Missing native executable for ${Name}: $File"
        return $null
    }
    $tool = @{ path = $command.Source; versionLog = "$Name-version.log"; exitCode = $null }
    $report.tools[$Name] = $tool
    try {
        $tool.exitCode = Invoke-LoggedProcess $command.Source @('--version') $PSScriptRoot (Join-Path $Output $tool.versionLog) 30
    } catch [System.ComponentModel.Win32Exception] {
        $tool.error = $_.Exception.Message
        Set-Content -LiteralPath (Join-Path $Output $tool.versionLog) -Value $_.ToString() -Encoding utf8
        $report.blockers += "$Name version probe could not start: $($command.Source). See $($tool.versionLog)."
        return $null
    }
    if ($tool.exitCode -ne 0) { $report.blockers += "$Name version probe failed (exit $($tool.exitCode))." }
    $command.Source
}

try {
    if (-not $IsWindows -or $report.host.osArchitecture -ne 'Arm64') {
        $report.blockers += 'An actual Windows Arm64 OS is required; x64 cross-builds cannot qualify.'
    }
    if ($PSVersionTable.PSVersion -lt [version]'7.2') { $report.blockers += 'PowerShell 7.2 or newer is required.' }
    if ($Generator -notmatch '^Visual Studio ([0-9]+) [0-9]{4}$') { throw 'Expected a Visual Studio CMake generator.' }
    $vsMajor = [int] $Matches[1]
    $null = Get-WorkerTool 'git' 'git'
    $cmakePath = Get-WorkerTool 'cmake' $CMake
    if ($cmakePath) {
        $null = Get-WorkerTool 'ctest' (Join-Path (Split-Path $cmakePath -Parent) 'ctest.exe')
        $exitCode = Invoke-LoggedProcess $cmakePath @('-E', 'capabilities') $PSScriptRoot (Join-Path $Output 'cmake-capabilities.json') 30
        if ($exitCode -ne 0) {
            $report.blockers += "CMake capabilities probe failed (exit $exitCode)."
        } else {
            $capabilities = Read-Json (Join-Path $Output 'cmake-capabilities.json')
            if ($Generator -notin $capabilities.generators.name) { $report.blockers += "CMake does not support $Generator." }
        }
    }
    if ($RequireCopilot) { $null = Get-WorkerTool 'copilot' 'copilot' }
    if ($IsWindows) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
            $report.blockers += 'Visual Studio Installer vswhere.exe is missing.'
        } else {
            $exitCode = Invoke-LoggedProcess $vswhere @('-products', '*', '-version', "[$vsMajor,$($vsMajor + 1))",
                '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64', '-format', 'json', '-utf8') `
                $PSScriptRoot (Join-Path $Output 'visual-studio.json') 30
            if ($exitCode -ne 0) {
                $report.blockers += "Visual Studio inventory failed (exit $exitCode)."
            } else {
                $instances = @(Get-Content -LiteralPath (Join-Path $Output 'visual-studio.json') -Raw | ConvertFrom-Json -AsHashtable)
                $report.visualStudio = @($instances | ForEach-Object {
                    @{ path = $_.installationPath; version = $_.installationVersion; arm64Component = $true }
                })
                if (-not $instances.Count) { $report.blockers += "$Generator has no complete registered ARM64 C++ toolchain." }
            }
        }
        $kits = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
        if ($kits -and $kits.PSObject.Properties['KitsRoot10']) {
            $libRoot = Join-Path $kits.KitsRoot10 'Lib'
            if (Test-Path -LiteralPath $libRoot -PathType Container) {
                $report.windowsSdk = @(Get-ChildItem -LiteralPath $libRoot -Directory | Where-Object {
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'um\arm64\kernel32.lib') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'ucrt\arm64\ucrt.lib') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $kits.KitsRoot10 "Include\$($_.Name)\um\Windows.h") -PathType Leaf)
                } | ForEach-Object { @{ version = $_.Name; path = $_.FullName } })
            }
        }
        if (-not $report.windowsSdk.Count) { $report.blockers += 'No Windows SDK with ARM64 UM/UCRT libraries and headers was found.' }
    }
    $report.inventoryReady = $report.blockers.Count -eq 0
    if (-not $report.inventoryReady) { throw "Worker prerequisites blocked: $($report.blockers -join ' ')" }
} catch {
    $report.inventoryReady = $false
    $report.error = $_.Exception.Message
    Set-Content -LiteralPath (Join-Path $Output 'failure.log') -Value $_.ToString()
    throw
} finally {
    Write-Json (Join-Path $Output 'worker.json') $report
    Write-Host "Worker inventory evidence: $Output"
}
