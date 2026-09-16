. "$PSScriptRoot\Common.ps1"

function Initialize-AgentBrowserInput($Task, [string] $Output) {
    $null = New-Item -ItemType Directory -Path "$Output\source\bin", "$Output\package"
    $wrapper = "$Output\source\bin\agent-browser.js"
    Invoke-WebRequest -Uri "$($Task.repository.Replace('github.com', 'raw.githubusercontent.com'))/$($Task.commit)/bin/agent-browser.js" `
        -OutFile $wrapper -TimeoutSec 60 -MaximumRedirection 0
    $sourceText = Read-RepairText "$Output\source" 'bin/agent-browser.js'
    $archive = "$Output\package.tgz"
    Invoke-WebRequest -Uri $Task.packageUrl -OutFile $archive -TimeoutSec 120 -MaximumRedirection 3
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Task.packageSha256) {
        throw 'Published agent-browser archive differs from the reviewed SHA256.'
    }
    $code = Invoke-LoggedProcess tar @('-xzf', $archive, '-C', "$Output\package", 'package/package.json',
        'package/bin/agent-browser.js', 'package/bin/agent-browser-win32-x64.exe') $Output "$Output\extract.log" 60
    if ($code -ne 0) { throw 'Cannot extract the three reviewed package members; see extract.log.' }
    $published = "$Output\package\package"
    $metadata = Read-Json "$published\package.json"
    if ($metadata.name -cne 'agent-browser' -or $metadata.version -cne $Task.packageVersion -or
        (Read-RepairText $published 'bin/agent-browser.js') -cne $sourceText) {
        throw 'Published package identity or wrapper differs from the pinned repository source.'
    }
    if ((Get-PeMachine "$published\bin\agent-browser-win32-x64.exe") -ne 0x8664) {
        throw 'Expected the published x64 PE executable, not an Arm64 binary.'
    }
    Write-Json "$Output\config.json" $Task
}

function Invoke-AgentBrowserValidation([string] $InputPath, [string] $Output) {
    $task = Read-Json "$InputPath\config.json"
    $null = New-Item -ItemType Directory -Path "$Output\logs", "$Output\fixture\bin"
    $fixture = "$Output\fixture"
    Copy-Item -LiteralPath "$InputPath\source\bin\agent-browser.js" -Destination "$fixture\bin"
    Copy-Item -LiteralPath "$InputPath\package\package\bin\agent-browser-win32-x64.exe" -Destination "$fixture\bin"
    Write-Json "$fixture\package.json" @{ type = 'module' }
    $resultPath = "$Output\result.json"
    $code = Invoke-LoggedProcess node @("$PSScriptRoot\..\tests\agent-browser-wrapper.cjs",
        "$fixture\bin\agent-browser.js", $resultPath, $fixture, $task.packageVersion) $fixture "$Output\logs\launcher.log" 180
    if ($code -ne 0) { throw "Launcher harness failed (exit $code); see logs\launcher.log." }
    $result = Read-Json $resultPath
    if ($result.host.nodeArchitecture -ne 'arm64' -or $result.host.platform -ne 'win32') {
        throw 'Launcher validation requires native Windows Arm64 Node.js.'
    }
    $result.host.osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $result.host.processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    $result.binary.machine = '0x{0:X4}' -f (Get-PeMachine "$fixture\bin\agent-browser-win32-x64.exe")
    if ($result.host.osArchitecture -ne 'Arm64' -or $result.host.processArchitecture -ne 'Arm64' -or
        $result.binary.machine -ne '0x8664') { throw 'Incorrect host or compatibility executable architecture.' }
    $result.packageSha256 = $task.packageSha256
    $result.sourceCommit = $task.commit
    Write-Json $resultPath $result
    $result
}
