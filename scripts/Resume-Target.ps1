. "$PSScriptRoot\Common.ps1"

$base = Get-BoardsBase
$state = Read-Json $env:OPENARM_HANDOFF_STATE
$item = Invoke-Boards GET "$base/workitems/$($state.id)?api-version=7.1"
if ($item.fields.PSObject.Properties.Name -notcontains 'System.AssignedTo' -or -not $item.fields.'System.AssignedTo') {
    throw 'A volunteer must claim the linked work item before resuming.'
}
$comments = @(Get-WorkItemComments $base $state.id)
$guidance = $comments | Where-Object {
    $_.text.StartsWith('OPENARM_GUIDANCE:') -and
    [DateTimeOffset]::Parse($_.createdDate) -gt [DateTimeOffset]::Parse($state.blockedAt) -and
    $_.text.Substring('OPENARM_GUIDANCE:'.Length).Trim().Length -ge 12
} | Select-Object -First 1
if (-not $guidance) { throw 'Add a new OPENARM_GUIDANCE: comment after this blocked run, with actionable details.' }
$owner = $item.fields.'System.AssignedTo'
if ($owner.PSObject.Properties.Name -notcontains 'id' -or -not $owner.id -or
    $guidance.PSObject.Properties.Name -notcontains 'createdBy' -or
    $guidance.PSObject.Properties.Name -notcontains 'modifiedBy' -or
    $guidance.createdBy.PSObject.Properties.Name -notcontains 'id' -or
    $guidance.modifiedBy.PSObject.Properties.Name -notcontains 'id' -or
    $guidance.createdBy.id -ne $owner.id -or $guidance.modifiedBy.id -ne $owner.id) {
    throw 'Guidance must be authored and last modified by the claimed work-item owner.'
}
$commentId = if ($guidance.PSObject.Properties.Name -contains 'commentId') {
    $guidance.commentId
} elseif ($guidance.PSObject.Properties.Name -contains 'id') {
    $guidance.id
} else { $null }
if ([string]$commentId -notmatch '^[1-9][0-9]*$' -or
    $guidance.PSObject.Properties.Name -notcontains 'version' -or
    [string]$guidance.version -notmatch '^[1-9][0-9]*$' -or
    $env:BUILD_BUILDID -notmatch '^[1-9][0-9]*$') {
    throw 'Snapshot requires a comment ID/version and the current pipeline build ID.'
}
$previous = Read-Json (Join-Path $env:OPENARM_EVIDENCE 'result.json')
$config = Read-Json (Join-Path $env:OPENARM_EVIDENCE 'config.json')
$context = Read-Json (Join-Path $env:OPENARM_EVIDENCE 'context.json')
Assert-Target $config
$output = $env:OPENARM_OUTPUT
if (Test-Path -LiteralPath $output) { throw 'Resume output directory already exists; use a clean job workspace.' }
$null = New-Item -ItemType Directory -Path $output
$commitMatch = [regex]::Match($guidance.text, '(?m)^OPENARM_COMMIT:\s*([a-fA-F0-9]{40})\s*$')
if ($guidance.text.Contains('OPENARM_COMMIT:') -and -not $commitMatch.Success) { throw 'OPENARM_COMMIT must contain exactly a full 40-character SHA.' }
if ($commitMatch.Success) {
    if ($config.repository -eq 'self') { throw 'For self targets, queue a new pipeline at the agent-generated fix commit; in-run commit replacement requires an external GitHub target.' }
    $context.commit = $commitMatch.Groups[1].Value
    Get-PinnedSource $config $context.commit (Join-Path $output 'source') (Join-Path $env:AGENT_TEMPDIRECTORY "openarm-resume-$([guid]::NewGuid())")
} else {
    Copy-Source (Join-Path $env:OPENARM_EVIDENCE 'source') (Join-Path $output 'source')
}
Copy-Source (Join-Path $env:OPENARM_EVIDENCE 'baseline') (Join-Path $output 'baseline')
$context.resumedFrom = $previous.blockedStep
$context.previousAttempts = $previous.attempts
$context.workItemId = $state.id
$context.guidanceCommentId = [long]$commentId
$context.guidanceCommentVersion = [long]$guidance.version
Write-Json (Join-Path $output 'context.json') $context
Write-Json (Join-Path $output 'config.json') $config
Set-Content -LiteralPath (Join-Path $output 'guidance.txt') -Value $guidance.text
$manifest = @{
    schemaVersion = 1; buildId = $env:BUILD_BUILDID; workItemId = $state.id
    commentId = [long]$commentId; commentVersion = [long]$guidance.version
    ownerId = $owner.id; sourceCommit = $context.commit; resumedFrom = $context.resumedFrom
    capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
    files = @(Get-ResumeFiles $output)
}
$manifestPath = Join-Path $output 'approval.json'
Write-Json $manifestPath $manifest
$digest = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$summaryPath = "$output-review.md"
Set-Content -LiteralPath $summaryPath -Value @"
# Review the frozen OpenArm resume input

This snapshot is NOT authorized for execution until ResumeApproval succeeds.

- Build: $env:BUILD_BUILDID
- Work item: $($state.id)
- Guidance comment: $commentId, version $($guidance.version)
- Checkout commit: $($context.commit)
- Manifest SHA-256: $digest

Review guidance.txt, approval.json and source in the openarm-resume-input artifact.
The digest covers all source, baseline, configuration, context and guidance files.
Later work-item comments cannot change this snapshot. Changed input requires a
new snapshot and a new approval; reject this gate if this is not the desired input.
"@
Write-Host "##vso[task.uploadsummary]$summaryPath"
Write-Host "##vso[task.setvariable variable=bundleDigest;isOutput=true]$digest"
Write-Host "##vso[task.setvariable variable=sourceCommit;isOutput=true]$($context.commit)"
Write-Host "##vso[task.setvariable variable=workItemId;isOutput=true]$($state.id)"
Write-Host "##vso[task.setvariable variable=commentId;isOutput=true]$commentId"
Write-Host "##vso[task.setvariable variable=commentVersion;isOutput=true]$($guidance.version)"
