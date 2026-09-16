. "$PSScriptRoot\Common.ps1"

if ((Test-Enabled $env:OPENARM_REQUIRE_APPROVERS) -and [string]::IsNullOrWhiteSpace($env:OPENARM_APPROVERS)) {
    throw 'Specify named approvers for human handoff or upstream review.'
}
if ((Test-Enabled $env:OPENARM_TEAMS) -and -not (Test-Enabled $env:OPENARM_HANDOFF)) {
    throw 'Teams requires the Azure Boards human handoff.'
}
$configPath = Resolve-ChildPath $env:BUILD_SOURCESDIRECTORY $env:OPENARM_CONFIG
$config = Read-Json $configPath
Assert-Target $config
$output = $env:OPENARM_OUTPUT
if (Test-Path -LiteralPath $output) { throw 'Input output directory already exists; use a clean job workspace.' }
$null = New-Item -ItemType Directory -Path $output
$source = Join-Path $output 'source'
if ($config.repository -eq 'self') {
    Copy-Source (Resolve-ChildPath $env:BUILD_SOURCESDIRECTORY $config.sourceSubdirectory -AllowRoot) $source
    $repository = $env:BUILD_REPOSITORY_URI
    $commit = $env:BUILD_SOURCEVERSION
} else {
    Get-PinnedSource $config $config.commit $source (Join-Path $env:AGENT_TEMPDIRECTORY "openarm-checkout-$([guid]::NewGuid())")
    $repository = $config.repository
    $commit = $config.commit
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'CMakeLists.txt'))) { throw 'This adapter requires CMakeLists.txt.' }
Copy-Source $source (Join-Path $output 'baseline')
Write-Json (Join-Path $output 'config.json') $config
Write-Json (Join-Path $output 'context.json') @{
    repository = $repository; commit = $commit; originalCommit = $commit; target = $config.id
    startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    resumedFrom = $null; previousAttempts = @()
}
