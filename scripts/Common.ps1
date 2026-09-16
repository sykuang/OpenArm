Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Json([string] $Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-Json([string] $Path, $Value) {
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Test-Enabled([string] $Value) { $Value -eq 'true' }

function Resolve-OutputPath {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path, [string] $Root = '')
    $provider = $null
    $drive = $null
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Output must be a filesystem path.' }
    $path = [IO.Path]::GetFullPath($path)
    if ($IsWindows) {
        $relative = $path.Substring([IO.Path]::GetPathRoot($path).Length)
        foreach ($part in $relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($part -match '[. ]$' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw 'Output path contains an ambiguous or invalid component.'
            }
        }
    }
    if ($Root) {
        $base = Resolve-OutputPath -Path $Root
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw 'OutputRoot must be an existing directory.' }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $prefix = $base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $path.TrimEnd('\', '/').StartsWith($prefix, $comparison)) {
            throw 'Output must be strictly inside OutputRoot.'
        }
        # Reject existing reparse ancestors, including the root; this is not a race-proof sandbox.
        $current = $path
        while ($current) {
            $item = $null
            try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] { }
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Output paths must not traverse symlinks or junctions: $current"
            }
            $current = [IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
        }
    }
    $path
}

function Resolve-ChildPath([string] $Root, [string] $Relative, [switch] $AllowRoot) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw 'Expected a nonempty relative path.'
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    $isRoot = $AllowRoot -and $path.TrimEnd('\', '/').Equals($base.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)
    if (-not $isRoot -and -not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its source root: $Relative"
    }
    $path
}

function Assert-Target($Config) {
    foreach ($key in 'id', 'repository', 'commit', 'sourceSubdirectory', 'generator', 'executable', 'smokeArguments', 'performanceSamples') {
        if (-not $Config.ContainsKey($key)) { throw "Missing target field: $key" }
    }
    if ($Config.id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid target id.' }
    if ($Config.repository -ne 'self' -and
        $Config.repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
        throw 'Only self or a public HTTPS github.com repository is supported.'
    }
    if ($Config.repository -ne 'self' -and $Config.commit -notmatch '^[a-fA-F0-9]{40}$') {
        throw 'External targets must be pinned to a full 40-character commit SHA.'
    }
    if ($Config.repository -eq 'self' -and $Config.commit -ne 'self') { throw 'Self targets use the pipeline checkout commit.' }
    if ($Config.generator -notmatch '^Visual Studio \d+ \d{4}$') { throw 'A Visual Studio CMake generator is required.' }
    if ($Config.smokeArguments -isnot [array] -or @($Config.smokeArguments | Where-Object { $_ -isnot [string] }).Count) {
        throw 'smokeArguments must be an array of strings.'
    }
    if ($Config.performanceSamples -isnot [long] -and $Config.performanceSamples -isnot [int]) { throw 'performanceSamples must be an integer.' }
    if ($Config.performanceSamples -lt 3 -or $Config.performanceSamples -gt 30) { throw 'Use 3 to 30 performance samples.' }
    $null = Resolve-ChildPath $PWD.Path $Config.sourceSubdirectory -AllowRoot
    $null = Resolve-ChildPath $PWD.Path $Config.executable
}

function Invoke-LoggedProcess {
    param(
        [string] $File, [string[]] $Arguments = @(), [string] $WorkingDirectory,
        [string] $Log, [int] $TimeoutSeconds = 900, [switch] $Agent, [switch] $ActionsCopilot
    )
    if ($ActionsCopilot -and -not $Agent) { throw 'Actions Copilot authentication is only available to agent processes.' }
    $command = Get-Command $File -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($command.Source -match '\.(cmd|bat)$') { throw "Use a native executable, not a command shim: $File" }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command.Source
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -match '(?i)(TOKEN|SECRET|PASSWORD|ACCESSTOKEN|BRIDGE_URL)' -and
            -not ($Agent -and (($key -eq 'COPILOT_GITHUB_TOKEN' -and -not $ActionsCopilot) -or
                ($key -eq 'GITHUB_TOKEN' -and $ActionsCopilot)))) {
            $null = $start.Environment.Remove($key)
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
        $text = $stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()
        # Build output is an artifact, never interpreted as Azure logging commands.
        Set-Content -LiteralPath $Log -Value $text -Encoding utf8
        if ($timedOut) { Add-Content -LiteralPath $Log -Value "`nOpenArm: timed out."; return 124 }
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Copy-Source([string] $From, [string] $To) {
    $null = New-Item -ItemType Directory -Path $To -Force
    $links = @(Get-ChildItem -LiteralPath $From -Recurse -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw 'Source snapshots containing symlinks/junctions are not supported.' }
    Get-ChildItem -LiteralPath $From -Force | Where-Object Name -ne '.git' |
        Copy-Item -Destination $To -Recurse -Force
}

function Get-PinnedSource($Config, [string] $Commit, [string] $Destination, [string] $Scratch) {
    if ($Commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'A full immutable commit SHA is required.' }
    $null = New-Item -ItemType Directory -Path $Scratch
    foreach ($arguments in @(
        @('init', '--quiet'),
        @('-c', 'credential.helper=', 'fetch', '--quiet', '--depth=1', $Config.repository, $Commit),
        @('-c', 'core.hooksPath=NUL', 'checkout', '--quiet', '--detach', 'FETCH_HEAD')
    )) {
        $exitCode = Invoke-LoggedProcess git $arguments $Scratch (Join-Path $Scratch 'checkout.log')
        if ($exitCode -ne 0) { throw "Pinned source checkout failed (exit $exitCode). See checkout.log." }
    }
    $source = Resolve-ChildPath $Scratch $Config.sourceSubdirectory -AllowRoot
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Configured source directory is missing.' }
    Copy-Source $source $Destination
}

function Get-PeMachine {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')] [byte[]] $Bytes
    )
    $stream = if ($PSCmdlet.ParameterSetName -eq 'Bytes') { [IO.MemoryStream]::new($Bytes, $false) } else { [IO.File]::OpenRead($Path) }
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $Path" }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE header: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-Classification([string] $Step, [string] $Evidence) {
    $accessFailure = $Evidence -match '(?i)(access is denied|permission denied|authentication failed|not authorized|license.{0,30}(missing|expired))'
    if (-not $accessFailure -and $Step -in @('configure', 'build') -and
        $Evidence -match '(?i)(LNK1112|error C[0-9]{4}|unsupported.{0,40}(arm64|aarch64)|machine type.{0,80}conflicts)') {
        return @{ route = 'ai_actionable'; reason = 'Compiler/architecture diagnostic matched a bounded source-remediation rule.' }
    }
    @{ route = 'needs_human'; reason = "No safe automated rule for the $Step failure; expert diagnosis or access is required." }
}

function Invoke-BoundedRemediation {
    param([scriptblock] $Validate, [scriptblock] $Remediate, [int] $MaxAttempts,
        [bool] $EnableAgent, [hashtable] $Result, [Collections.Generic.List[object]] $Attempts, [string] $Phase)
    if ($MaxAttempts -lt 0 -or $MaxAttempts -gt 3) { throw 'Attempt budget must be 0 to 3.' }
    $round = 0
    while (-not (& $Validate $round)) {
        $Attempts.Add(@{ round = $round; phase = $Phase; route = $Result.route
            step = $Result.blockedStep; reason = $Result.reason; checks = $Result.checks
            at = [DateTimeOffset]::UtcNow.ToString('o') })
        if ($Result.route -ne 'ai_actionable') { break }
        if (-not $EnableAgent -or $round -ge $MaxAttempts) {
            $Result.route = 'needs_human'
            $Result.reason += " Agent remediation disabled or budget exhausted ($round/$MaxAttempts)."
            break
        }
        $round++
        & $Remediate $round
    }
}

function Get-BlockerKey([string] $Repository, [string] $Target, [string] $Step) {
    # ponytail: target/checkpoint is a blocker slot; add root-cause fingerprints if independent failures need separate threads.
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($Repository.ToLowerInvariant().TrimEnd('/'))|$Target|$Step")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 24).ToLowerInvariant()
}

function Get-ResumeFiles([string] $Root) {
    $items = @((Get-Item -LiteralPath $Root), (Get-ChildItem -LiteralPath $Root -Recurse -Force)) |
        ForEach-Object { $_ }
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'Resume bundles must not contain symlinks or junctions.'
    }
    @($items | Where-Object { -not $_.PSIsContainer -and $_.FullName -ne (Join-Path $Root 'approval.json') } |
        Sort-Object FullName | ForEach-Object {
            @{ path = [IO.Path]::GetRelativePath($Root, $_.FullName)
               sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
}

function Assert-ResumeBundle([string] $Root, [string] $ExpectedDigest, [string] $BuildId) {
    if ($ExpectedDigest -notmatch '^[a-fA-F0-9]{64}$' -or $BuildId -notmatch '^[1-9][0-9]*$') {
        throw 'Resume requires an approved bundle digest and the current pipeline build ID.'
    }
    $manifestPath = Join-Path $Root 'approval.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $ExpectedDigest) {
        throw 'Resume manifest does not match the approved digest.'
    }
    $manifest = Read-Json $manifestPath
    if ($manifest.schemaVersion -ne 1 -or [string]$manifest.buildId -ne $BuildId) {
        throw 'Resume approval belongs to a different pipeline run or unsupported manifest version.'
    }
    $actual = @(Get-ResumeFiles $Root)
    if ($manifest.files -isnot [array] -or $manifest.files.Count -ne $actual.Count -or -not $actual.Count) {
        throw 'Resume bundle file set changed after review.'
    }
    $expected = @{}
    foreach ($entry in $manifest.files) {
        $path = Resolve-ChildPath $Root $entry.path
        if ([IO.Path]::GetRelativePath($Root, $path) -cne $entry.path -or
            $entry.path -eq 'approval.json' -or $expected.ContainsKey($entry.path) -or
            $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Resume manifest contains an invalid or duplicate file entry.'
        }
        $expected[$entry.path] = $entry.sha256
    }
    foreach ($entry in $actual) {
        if (-not $expected.ContainsKey($entry.path) -or $expected[$entry.path] -ne $entry.sha256) {
            throw "Resume bundle content changed after review: $($entry.path)"
        }
    }
    $manifest
}

function Get-BoardsBase {
    if ($env:SYSTEM_COLLECTIONURI -notmatch '^https://dev\.azure\.com/[^/]+/$') {
        throw 'This prototype requires an Azure DevOps Services dev.azure.com collection URL.'
    }
    if ([string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) { throw 'System.AccessToken is required.' }
    "$($env:SYSTEM_COLLECTIONURI)$([uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT))/_apis/wit"
}

function Invoke-Boards([string] $Method, [string] $Uri, $Body = $null, [switch] $Patch) {
    $parameters = @{
        Method = $Method; Uri = $Uri; TimeoutSec = 60
        Headers = @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
    }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
        $parameters.ContentType = if ($Patch) { 'application/json-patch+json' } else { 'application/json' }
    }
    Invoke-RestMethod @parameters
}

function Get-WorkItemComments([string] $Base, [int] $Id) {
    $response = Invoke-Boards GET "$Base/workItems/$Id/comments?`$top=200&order=desc&api-version=7.1-preview.4"
    if ($response.PSObject.Properties.Name -contains 'continuationToken' -and $response.continuationToken) {
        throw 'Work item has over 200 comments. Archive/reconcile coordination markers before continuing; no messages were resent.'
    }
    @($response.comments)
}

function Add-WorkItemComment([string] $Base, [int] $Id, [string] $Text) {
    $null = Invoke-Boards POST "$Base/workItems/$Id/comments?api-version=7.1-preview.4" @{ text = $Text }
}
