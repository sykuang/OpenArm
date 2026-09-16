param([ValidateSet('Blocked', 'Result')][string] $Mode)
. "$PSScriptRoot\Common.ps1"

$base = Get-BoardsBase
$result = Read-Json (Join-Path $env:OPENARM_EVIDENCE 'result.json')
$null = New-Item -ItemType Directory -Path $env:OPENARM_OUTPUT -Force
$buildUrl = "$($env:SYSTEM_COLLECTIONURI)$([uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT))/_build/results?buildId=$env:BUILD_BUILDID"
$evidenceUrl = "$buildUrl&view=artifacts"
$encode = { param($value) [Net.WebUtility]::HtmlEncode([string] $value) }
$key = if ($Mode -eq 'Result') {
    (Read-Json $env:OPENARM_HANDOFF_STATE).key
} else {
    Get-BlockerKey $result.repository $result.target $result.blockedStep
}
$tag = "OpenArm-Key-$key"

if ($Mode -eq 'Result') {
    $id = [int](Read-Json $env:OPENARM_HANDOFF_STATE).id
} else {
    $query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$tag'"
    $matches = Invoke-Boards POST "$base/wiql?api-version=7.1" @{ query = $query }
    if (@($matches.workItems).Count -gt 1) { throw 'Duplicate blocker work items found. Reconcile them before sending any notifications.' }
    if (@($matches.workItems).Count -eq 1) {
        $id = [int]$matches.workItems[0].id
    } else {
        $type = if ([string]::IsNullOrWhiteSpace($env:OPENARM_WORK_ITEM_TYPE)) { 'Issue' } else { $env:OPENARM_WORK_ITEM_TYPE }
        $created = Invoke-Boards POST "$base/workitems/`$$([uri]::EscapeDataString($type))?api-version=7.1" @(
            @{ op = 'add'; path = '/fields/System.Title'; value = "OpenArm: $($result.target) / $($result.blockedStep)" },
            @{ op = 'add'; path = '/fields/System.Tags'; value = "OpenArm; $tag; OpenArm-NeedsHuman" }
        ) -Patch
        $id = [int]$created.id
    }
}
$item = Invoke-Boards GET "$base/workitems/$id`?api-version=7.1"
$statusTag = if ($result.nativeVerified -and $result.route -eq 'validated') { 'OpenArm-Validated' } else { 'OpenArm-NeedsHuman' }
$existingTags = if ($item.fields.PSObject.Properties.Name -contains 'System.Tags') { [string]$item.fields.'System.Tags' } else { '' }
$tags = @($existingTags -split ';' | ForEach-Object Trim | Where-Object { $_ -and $_ -notin @('OpenArm-Validated', 'OpenArm-NeedsHuman') })
$tags = @($tags + @('OpenArm', $tag, $statusTag) | Sort-Object -Unique)
$expertise = if ($result.blockedStep -in @('host', 'agent')) { 'Native worker / CI access administration' } else { 'Windows Arm64 / CMake / dependency maintainers' }
$description = @"
<h2>OpenArm: $(& $encode $result.route)</h2>
<p>Repository: $(& $encode $result.repository)<br>Commit: $(& $encode $result.commit)</p>
<p>Checkpoint: $(& $encode $result.blockedStep)<br>Analysis: $(& $encode $result.reason)</p>
<p>Required expertise: $expertise</p>
<p>Help needed: claim this item, inspect the linked logs and prior attempts, and provide
guidance, agent-generated fixes, access coordination, or native testing. Add a new comment
starting OPENARM_GUIDANCE: authored and last edited by the claimed owner. Signal
readiness, then separately review and approve the frozen source/guidance digest.</p>
<p>Optional agent-generated fix: add OPENARM_COMMIT: followed by a full commit SHA in the same comment.</p>
<p>Assigned To and State remain owned by volunteers. OpenArm tags describe validation, not work-item closure.</p>
<p><a href="$(& $encode $evidenceUrl)">Build evidence and previous attempts</a></p>
<pre>$(& $encode (ConvertTo-Json -InputObject $result.attempts -Depth 12))</pre>
"@
$null = Invoke-Boards PATCH "$base/workitems/$id`?api-version=7.1" @(
    @{ op = 'test'; path = '/rev'; value = $item.rev },
    @{ op = 'add'; path = '/fields/System.Description'; value = $description },
    @{ op = 'add'; path = '/fields/System.Tags'; value = $tags -join '; ' }
) -Patch
$workItemUrl = "$($env:SYSTEM_COLLECTIONURI)$([uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT))/_workitems/edit/$id"
$state = @{ id = $id; key = $key; url = $workItemUrl; blockedAt = $result.completedAt }
Write-Json (Join-Path $env:OPENARM_OUTPUT 'work-item.json') $state
Set-Content -LiteralPath (Join-Path $env:OPENARM_OUTPUT 'handoff.md') -Value @"
# OpenArm volunteer work item
[$id - $($result.target)]($workItemUrl)

Status: **$($result.route)**. [Evidence]($evidenceUrl).

Claim with **Assigned To** and author a new **OPENARM_GUIDANCE:** comment.
Signal guidance readiness, then separately approve the exact frozen snapshot in **ResumeApproval**.
Ownership and closure remain in Azure Boards. This pipeline never auto-closes work items.
"@
Write-Host "##vso[task.uploadsummary]$(Join-Path $env:OPENARM_OUTPUT 'handoff.md')"

$comments = @(Get-WorkItemComments $base $id)
$messageKey = "$key`:$env:BUILD_BUILDID`:$Mode"
$confirmed = @()
$pending = @()
foreach ($comment in $comments) {
    if ($comment.text.StartsWith('OPENARM_TEAMS_SENT: ')) {
        $confirmed += $comment.text.Substring('OPENARM_TEAMS_SENT: '.Length) | ConvertFrom-Json -AsHashtable
    }
    if ($comment.text.StartsWith('OPENARM_TEAMS_PENDING: ')) {
        $pending += $comment.text.Substring('OPENARM_TEAMS_PENDING: '.Length)
    }
}
$thread = $confirmed | Select-Object -First 1
$request = @{
    messageKey = $messageKey; blockerKey = $key
    action = if ($thread) { 'reply' } else { 'create' }
    threadId = if ($thread) { $thread.threadId } else { $null }
    workItemUrl = $workItemUrl; evidenceUrl = $evidenceUrl
    title = "OpenArm: $($result.target) - $($result.route)"
    analysis = $result.reason; checkpoint = $result.blockedStep
    expertise = $expertise; priorAttempts = $result.attempts
    helpNeeded = if ($Mode -eq 'Blocked') { 'Claim the linked work item and provide guidance to unblock native validation.' } else { 'Review validation evidence and update the claimed work item.' }
}
Write-Json (Join-Path $env:OPENARM_OUTPUT 'teams-request.json') $request
if (-not (Test-Enabled $env:OPENARM_TEAMS)) {
    Write-Host 'Teams delivery disabled. Request artifact generated; no message sent.'
    return
}
if (@($confirmed | Where-Object messageKey -eq $messageKey).Count) {
    Write-Host 'This result was already delivered to the blocker thread; not reposting.'
    return
}
if (@($pending | Where-Object { $_ -notin @($confirmed | ForEach-Object { $_.messageKey }) }).Count) {
    throw 'An earlier Teams delivery is unconfirmed. Reconcile its pending marker with the bridge; refusing a possible duplicate.'
}
if ($env:OPENARM_TEAMS_BRIDGE_URL -notmatch '^https://') { throw 'Configure the secret OpenArm.TeamsBridgeUrl HTTPS endpoint.' }
# A durable pending marker makes ambiguous HTTP outcomes fail closed instead of reposting.
Add-WorkItemComment $base $id "OPENARM_TEAMS_PENDING: $messageKey"
try {
    $response = Invoke-RestMethod -Method POST -Uri $env:OPENARM_TEAMS_BRIDGE_URL -ContentType 'application/json' `
        -Body (ConvertTo-Json -InputObject $request -Depth 20) -TimeoutSec 60
} catch {
    throw 'Teams bridge delivery failed or timed out. Inspect the bridge and reconcile OPENARM_TEAMS_PENDING; do not blindly retry the send.'
}
if (-not $response.threadId -or $response.threadUrl -notmatch '^https://(teams\.microsoft\.com|teams\.cloud\.microsoft)/') {
    throw 'Teams bridge must return threadId and an HTTPS Teams threadUrl. Delivery is pending until reconciled.'
}
if ($thread -and $response.threadId -ne $thread.threadId) { throw 'Bridge replied in a different thread. Reconcile delivery before resuming.' }
Add-WorkItemComment $base $id ('OPENARM_TEAMS_SENT: ' + (ConvertTo-Json -Compress -InputObject @{
    messageKey = $messageKey; threadId = $response.threadId; threadUrl = $response.threadUrl
}))
