param(
    [Parameter(Mandatory)][string] $CandidateRoot,
    [Parameter(Mandatory)][string] $Output,
    [string] $CMake = 'cmake',
    [string] $Generator = 'Visual Studio 17 2022',
    [string] $Python = 'python'
)
. "$PSScriptRoot\Common.ps1"

$candidate = Resolve-OutputPath -Path $CandidateRoot
$Output = Resolve-OutputPath -Path $Output -Root $candidate
$scriptFile = Join-Path $candidate 'scripts\Test-Project.ps1'
if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { throw 'Candidate validation script is missing.' }
if (Test-Path -LiteralPath $Output) { throw 'Candidate output already exists; choose a new directory.' }
$validation = Join-Path $Output 'validation'
$arguments = @('-NoProfile', '-File', $scriptFile, '-Output', $validation, '-OutputRoot', $candidate,
    '-CMake', $CMake, '-Generator', $Generator, '-Python', $Python)
$record = @{
    protocol = 'openarm-local-validation/v2'; candidateRoot = $candidate
    workingDirectory = $candidate; output = $validation; outputRoot = $candidate
    arguments = $arguments; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    exitCode = $null; sandboxed = $false
}
$null = New-Item -ItemType Directory -Path $Output
try {
    $record.exitCode = Invoke-LoggedProcess (Get-Process -Id $PID).Path $arguments $candidate (Join-Path $Output 'validation.log')
} finally {
    $record.completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-Json (Join-Path $Output 'invocation.json') $record
    Write-Host "Local candidate evidence: $Output"
}
if ($record.exitCode -ne 0) { throw "Candidate validation failed (exit $($record.exitCode)). See $Output\validation.log." }
