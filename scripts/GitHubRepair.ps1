. "$PSScriptRoot\Common.ps1"

function Read-RepairTask([string] $TaskId) {
    if ($TaskId -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Select a tracked, reviewed repair task id.' }
    $task = Read-Json (Join-Path $PSScriptRoot "..\targets\github\$TaskId.json")
    if ($task.id -cne $TaskId -or $task.mode -notin @('diagnose', 'cmake')) { throw 'Invalid repair task identity or mode.' }
    if ($task.repository -ne 'self' -and ($task.repository -cnotmatch '^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' -or
        $task.commit -cnotmatch '^[a-f0-9]{40}$')) { throw 'External repair tasks require a public GitHub repository and immutable commit.' }
    if ($task.context -isnot [string] -or $task.context.Length -gt 8000) { throw 'Task context must be bounded text.' }
    if ($task.mode -eq 'cmake') {
        Assert-Target $task
        if ($task.repository -ne 'self' -and ($task.fork -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' -or
            "https://github.com/$($task.fork)" -ieq $task.repository)) { throw 'External repairs require a distinct reviewed destination fork.' }
    } elseif ($task.repository -eq 'self' -or @($task.allowedFiles).Count) {
        throw 'Diagnostic tasks cannot edit source.'
    }
    if ($task.allowedFiles -isnot [array] -or $task.allowedFiles.Count -gt 5) { throw 'Allow at most five existing source files.' }
    $seen = @{}
    foreach ($path in $task.allowedFiles) {
        if ($path -isnot [string] -or $path -cnotmatch '^(?:[A-Za-z0-9_-]+/)*(?:[A-Za-z0-9_-]+\.(?:c|cc|cpp|h|hpp)|CMakeLists\.txt)$' -or
            $path -match '(?i)(^|/)(tests?|testdata|fixtures?)(/|[_.-])|(^|/)(test[_.-]|.*[_.-]test[_.])' -or $seen.ContainsKey($path)) {
            throw 'Editable paths must be unique C/C++ source or CMakeLists.txt, not tests, workflows or arbitrary scripts.'
        }
        $seen[$path] = $true
    }
    $task
}

function Get-RepairHash([string] $Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Read-RepairText([string] $Root, [string] $Path) {
    $file = Resolve-OutputPath (Resolve-ChildPath $Root $Path) $Root
    $item = Get-Item -LiteralPath $file
    if ($item.PSIsContainer -or $item.Length -gt 65536 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Not a bounded regular source file: $Path"
    }
    $text = [IO.File]::ReadAllText($file, [Text.UTF8Encoding]::new($false, $true))
    if ($text.Contains([char]0)) { throw "Binary source is not supported: $Path" }
    $text
}

function Assert-RepairWorkspace([string] $Root, $Task) {
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'The edited workspace contains a symlink or junction.'
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -ne $Task.allowedFiles.Count) { throw 'Copilot added or deleted a file outside the allowed edit scope.' }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        if ($Task.allowedFiles -cnotcontains $relative) { throw 'Copilot changed the allowed workspace file set.' }
    }
}

function Assert-RepairBundle($Bundle, $Task, [string] $RunId, [string] $WorkflowCommit) {
    if ($RunId -cnotmatch '^[1-9][0-9]*$' -or $WorkflowCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $Bundle.schemaVersion -ne 1 -or $Bundle.taskId -cne $Task.id -or $Bundle.runId -cne $RunId -or
        $Bundle.workflowCommit -cne $WorkflowCommit -or $Bundle.sourceCommit -cne $Task.commit -or
        $Bundle.files -isnot [array] -or $Bundle.files.Count -gt 5 -or $Task.mode -ne 'cmake') {
        throw 'Candidate does not match this trusted task, revision and workflow run.'
    }
    $seen = @{}; $bytes = 0
    foreach ($file in $Bundle.files) {
        if ($file.path -isnot [string] -or $Task.allowedFiles -cnotcontains $file.path -or $seen.ContainsKey($file.path) -or
            $file.baseSha256 -cnotmatch '^[a-f0-9]{64}$' -or $file.content -isnot [string] -or
            $file.content.Contains([char]0) -or [Text.Encoding]::UTF8.GetByteCount($file.content) -gt 65536) {
            throw 'Candidate contains a duplicate, forbidden or oversized source change.'
        }
        if ((Get-RepairHash $file.content) -eq $file.baseSha256) { throw 'Candidate includes an unchanged file.' }
        $bytes += [Text.Encoding]::UTF8.GetByteCount($file.content)
        $seen[$file.path] = $true
    }
    if ($bytes -gt 131072) { throw 'Candidate exceeds the 128 KiB total change limit.' }
}

function Initialize-RepairInput($Task, [string] $Output) {
    $null = New-Item -ItemType Directory -Path $Output
    $source = Join-Path $Output 'source'
    if ($Task.repository -eq 'self') {
        Copy-Source (Resolve-ChildPath (Split-Path $PSScriptRoot -Parent) $Task.sourceSubdirectory -AllowRoot) $source
    } else {
        Get-PinnedSource $Task $Task.commit $source (Join-Path $Output 'checkout')
    }
    Copy-Source $source (Join-Path $Output 'baseline')
    Write-Json (Join-Path $Output 'config.json') $Task
    Write-Json (Join-Path $Output 'context.json') @{
        repository = $Task.repository; commit = $Task.commit; originalCommit = $Task.commit
        target = $Task.id; resumedFrom = $null; previousAttempts = @()
    }
}

function Invoke-RepairValidation([string] $InputPath, [string] $Output) {
    $names = @('OPENARM_INPUT', 'OPENARM_OUTPUT', 'OPENARM_BUILD', 'OPENARM_MAX_ATTEMPTS', 'OPENARM_ENABLE_AGENT',
        'OPENARM_REQUIRE_RESUME_APPROVAL')
    $previous = @{}
    foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:OPENARM_INPUT = $InputPath
        $env:OPENARM_OUTPUT = $Output
        $env:OPENARM_BUILD = "$Output-build"
        $env:OPENARM_MAX_ATTEMPTS = '0'
        $env:OPENARM_ENABLE_AGENT = 'false'
        $env:OPENARM_REQUIRE_RESUME_APPROVAL = 'false'
        & "$PSScriptRoot\Invoke-NativeLoop.ps1"
        Read-Json (Join-Path $Output 'result.json')
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }
}

function Invoke-RepairCopilot([string] $Prompt, [string] $WorkingDirectory, [string] $Log, [string[]] $EditableFiles = @()) {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'Copilot requires the Actions GITHUB_TOKEN and copilot-requests: write.' }
    $arguments = @('-p', $Prompt, '-s', '--no-ask-user', '--no-custom-instructions', '--disable-builtin-mcps',
        '--disallow-temp-dir', '--deny-tool=shell', '--deny-tool=url', '--secret-env-vars=GITHUB_TOKEN')
    if ($EditableFiles.Count) {
        $arguments += '--available-tools=view,edit,create,glob,grep,rg,apply_patch'
        foreach ($path in $EditableFiles) {
            $arguments += "--allow-tool=write($(Resolve-ChildPath $WorkingDirectory $path))"
        }
    } else {
        # An explicit empty availability list hides all tools; "*" is not a permission kind.
        $arguments += '--available-tools'
    }
    $code = Invoke-LoggedProcess copilot $arguments $WorkingDirectory $Log 600 -Agent -ActionsCopilot
    if ($code -ne 0) { throw "Copilot request failed (exit $code); see $Log. No automatic request retry." }
}
