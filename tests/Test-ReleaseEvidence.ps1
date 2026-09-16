Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Common.ps1"
. "$PSScriptRoot\..\scripts\ReleaseEvidence.ps1"
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function New-Budget { @{ remainingBytes = 128MB; assetCount = 0; clock = [Diagnostics.Stopwatch]::StartNew() } }
function New-Pe([int] $Machine, [int] $Length = 256, [int] $Offset = 128) {
    $bytes = [byte[]]::new($Length)
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
    [BitConverter]::GetBytes($Offset).CopyTo($bytes, 0x3C)
    if ($Offset -le $Length - 6) {
        [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, $Offset)
        [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, $Offset + 4)
    }
    return ,$bytes
}
function New-Zip([hashtable] $Entries) {
    $stream = [IO.MemoryStream]::new()
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $archive.CreateEntry($name).Open()
            try { $entry.Write($Entries[$name], 0, $Entries[$name].Length) } finally { $entry.Dispose() }
        }
    } finally { $archive.Dispose() }
    try { return ,$stream.ToArray() } finally { $stream.Dispose() }
}
function New-Asset([string] $Name, [long] $Size) {
    @{ name = $Name; size = $Size; state = 'uploaded'
        browser_download_url = "https://github.com/owner/repo/releases/download/v1/$([uri]::EscapeDataString($Name))" }
}
function Inspect-Assets([array] $Assets, [hashtable] $Budget = (New-Budget)) {
    $metadata = @{ tag_name = 'v1'; published_at = '2026-09-16T00:00:00Z'; draft = $false; prerelease = $false; assets = $Assets } |
        ConvertTo-Json -Depth 8 | ConvertFrom-Json
    Get-ReleaseEvidence $metadata 'owner/repo' $Budget
}
$script:payloads = @{}
$script:downloads = [Collections.Generic.List[string]]::new()
function Mock-ReleaseBytes {
    param($Uri, $ExpectedSize, $PrefixOnly, $Budget)
    $name = [uri]::UnescapeDataString(([uri]$Uri).Segments[-1])
    $script:downloads.Add($name)
    if (-not $script:payloads.ContainsKey($name)) { throw 'Unexpected test download.' }
    $Budget.remainingBytes -= $script:payloads[$name].Length
    return ,$script:payloads[$name]
}
Set-Alias Receive-ReleaseBytes Mock-ReleaseBytes
try {
    foreach ($machine in 0xAA64, 0xA641, 0xA64E, 0x8664, 0x014C, 0x01C4, 0x1234) {
        $p = Get-ReleasePeEvidence (New-Pe $machine) 256 'app.exe'
        Assert ($p.status -eq 'pe_header' -and $p.machine -eq ('0x{0:X4}' -f $machine)) "Actual PE machine $machine, not a filename guess"
    }
    Assert ((Get-ReleasePeEvidence (New-Pe 0xAA64 65536 100000) 200000 'app.exe').status -eq 'header_outside_limit') 'Large valid DOS offsets stay unverified, not corrupt'
    Assert ((Get-ReleasePeEvidence ([byte[]](1, 2)) 2 'app.exe').status -eq 'invalid_pe') 'Truncated non-PE bytes cannot verify architecture'
    Assert ((Get-ReleasePeEvidence ([byte[]]::new(0)) 0 'app.exe').status -eq 'empty') 'Empty PE files are explicit'
    $script:payloads['app.exe'] = New-Pe 0xAA64
    $r = Inspect-Assets @((New-Asset 'app.exe' 256))
    Assert ($r.windowsArm64 -eq 'pe_header_found' -and $r.assets[0].architectures[0] -eq 'arm64') 'Unlabeled direct executable is inspected'
    Assert ($r.assets[0].sampleBytes -eq 256 -and $r.assets[0].sampleSha256 -match '^[a-f0-9]{64}$') 'Inspected prefix size and digest retain provenance'

    $script:payloads['app-windows-arm64.exe'] = New-Pe 0x8664
    $r = Inspect-Assets @((New-Asset 'app-windows-arm64.exe' 256))
    Assert ($r.artifactProblem -and $r.assets[0].architectureMismatch -and $r.assets[0].architectures[0] -eq 'x64') 'Mislabelled Arm64 executable reports the actual x64 machine and mismatch'
    Assert ($r.windowsArm64 -ne 'pe_header_found') 'An Arm64 filename cannot override x64 bytes'
    $r = Inspect-Assets @((New-Asset 'app-win-arm64.exe' 0), (New-Asset 'app-win-arm64.msi' 400), (New-Asset 'app-win-arm64.zip' (16MB + 1)))
    Assert ($r.artifactProblem -and $r.assets[0].inspection -eq 'empty') 'Zero-byte release assets are flagged without downloading'
    Assert ($r.assets[1].inspection -eq 'uninspected_format' -and $r.assets[2].inspection -eq 'size_limit' -and
        $r.windowsArm64 -eq 'advertised_unverified') 'Installers and oversized ZIPs are advertised, never PE-verified'
    $script:payloads['app.zip'] = New-Zip @{ '../escape.exe' = (New-Pe 0xAA64); 'bin\x64.dll' = (New-Pe 0x8664); 'bad.exe' = [byte[]](1, 2); 'empty.exe' = [byte[]]::new(0) }
    $r = Inspect-Assets @((New-Asset 'app.zip' $script:payloads['app.zip'].Length))
    Assert ($r.windowsArm64 -eq 'pe_header_found' -and $r.assets[0].architectures.Count -eq 2 -and
        $r.assets[0].binaries.Count -eq 4 -and $r.artifactProblem) 'ZIP PE evidence includes mixed machines and empty/invalid binaries without extracting paths'
    $script:payloads['app.zip'] = New-Zip @{ 'readme.txt' = [byte[]](1) }
    $r = Inspect-Assets @((New-Asset 'app.zip' $script:payloads['app.zip'].Length))
    Assert ($r.assets[0].inspection -eq 'no_pe_found' -and $r.windowsArm64 -eq 'unknown') 'Source-only archive is not an x64-only distribution'
    $script:payloads['app.zip'] = [byte[]](1, 2, 3)
    $r = Inspect-Assets @((New-Asset 'app.zip' 3))
    Assert ($r.assets[0].inspection -eq 'invalid_archive' -and $r.assets[0].error) 'Invalid ZIP is an explicit inspection failure'
    $entries = @{}
    1..513 | ForEach-Object { $entries["$_.exe"] = [byte[]](1) }
    $script:payloads['app.zip'] = New-Zip $entries
    $r = Inspect-Assets @((New-Asset 'app.zip' $script:payloads['app.zip'].Length))
    Assert ($r.assets[0].inspection -eq 'archive_entry_limit' -and $r.assets[0].binaries.Count -eq 0) 'ZIP entry count is bounded before reading payloads'
    $entries = @{}
    1..17 | ForEach-Object { $entries["$_.exe"] = New-Pe 0x8664 }
    $script:payloads['app.zip'] = New-Zip $entries
    $r = Inspect-Assets @((New-Asset 'app.zip' $script:payloads['app.zip'].Length))
    Assert ($r.assets[0].inspection -eq 'archive_binary_limit' -and $r.assets[0].binaries.Count -eq 16) 'Only sixteen ZIP PE headers are inspected'
    $script:payloads['app.zip'] = New-Zip @{ 'huge.exe' = (New-Pe 0xAA64 2MB) }
    $r = Inspect-Assets @((New-Asset 'app.zip' $script:payloads['app.zip'].Length))
    Assert ($r.windowsArm64 -eq 'pe_header_found') 'Large compressed entry only needs a bounded header, not full decompression'

    $script:downloads.Clear()
    $assets = @(1..4 | ForEach-Object {
        $script:payloads["app$_.exe"] = New-Pe 0x8664
        New-Asset "app$_.exe" 256
    })
    $r = Inspect-Assets $assets
    Assert ($script:downloads.Count -eq 3 -and $r.assets[3].inspection -eq 'budget_limit') 'Per-repository asset limit is exact'
    $b = New-Budget; $b.remainingBytes = 256
    $r = Inspect-Assets @((New-Asset 'app.exe' 256)) $b
    Assert ($r.assets[0].inspection -eq 'budget_limit') 'Byte budget requires room for overflow detection'
    $b = New-Budget; $b.clock = [pscustomobject]@{ Elapsed = [TimeSpan]::FromSeconds(180) }
    $r = Inspect-Assets @((New-Asset 'app.exe' 256)) $b
    Assert ($r.assets[0].inspection -eq 'budget_limit') 'Release-phase deadline prevents new downloads'
    $r = Inspect-Assets @(1..101 | ForEach-Object { New-Asset "asset$_.msi" 10 })
    Assert ($r.metadataTruncated -and $r.returnedAssetCount -eq 101 -and $r.assets.Count -eq 100) 'Metadata inventory has a visible hundred-asset limit'
    $r = Inspect-Assets @((New-Asset 'app-linux-arm64.zip' 100), (New-Asset 'app-macos-arm64.tar.gz' 100))
    Assert ($r.windowsArm64 -eq 'unknown' -and $r.assets[0].platformHint -eq 'other') 'Non-Windows Arm64 names cannot prove Windows support'

    foreach ($url in 'http://github.com/owner/repo/releases/download/v1/a.exe',
        'https://github.com.evil.invalid/owner/repo/releases/download/v1/a.exe',
        'https://secret@github.com/owner/repo/releases/download/v1/a.exe',
        'https://github.com:444/owner/repo/releases/download/v1/a.exe',
        'https://github.com/other/repo/releases/download/v1/a.exe',
        'https://github.com/owner/repo/releases/download/v1/a.exe?secret=1') {
        $a = New-Asset 'a.exe' 256; $a.browser_download_url = $url
        $failed = $false
        try { $null = Inspect-Assets @($a) } catch { $failed = $true }
        Assert $failed 'Out-of-scope or credential-bearing asset URL cannot drive a request'
    }
} finally { Remove-Item Alias:\Receive-ReleaseBytes }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class ReleaseTestHandler : HttpMessageHandler {
    public Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
    public List<string> Urls = new List<string>();
    public List<string> Ranges = new List<string>();
    public bool CredentialsSeen;
    public bool ThrowTransport;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Urls.Add(request.RequestUri.AbsoluteUri);
        Ranges.Add(request.Headers.Range == null ? "" : request.Headers.Range.ToString());
        CredentialsSeen |= request.Headers.Authorization != null || request.Headers.Contains("Cookie");
        if (ThrowTransport) throw new HttpRequestException("private signed URL ?secret=do-not-retain");
        return Task.FromResult(Responses.Dequeue());
    }
}
'@
function New-Response([int] $Status, [byte[]] $Bytes = [byte[]]::new(0), [string] $Location = '') {
    $response = [Net.Http.HttpResponseMessage]::new($Status)
    $response.Content = [Net.Http.ByteArrayContent]::new($Bytes)
    if ($Location) { $response.Headers.Location = [uri]$Location }
    $response
}
foreach ($case in 'prefix', 'range', 'zip', 'redirect', 'evil-redirect', 'downgrade', 'redirect-limit',
    'wrong-range', 'http', 'transport', 'oversize', 'truncated', 'encoded') {
    $handler = [ReleaseTestHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $prefix = $case -notin 'zip', 'oversize', 'truncated'
    $size = if ($prefix) { 100000 } else { 256 }
    $response = New-Response 200 (New-Pe 0xAA64 $(if ($prefix) { 100000 } else { 256 }))
    switch ($case) {
        'range' { $response.StatusCode = 206; $response.Content.Headers.ContentRange = [Net.Http.Headers.ContentRangeHeaderValue]::new(0, 99999, 100000) }
        'redirect' { $handler.Responses.Enqueue((New-Response 302 -Location 'https://release-assets.githubusercontent.com/test?signature=do-not-retain')) }
        'evil-redirect' { $handler.Responses.Enqueue((New-Response 302 -Location 'https://evil.invalid/test')) }
        'downgrade' { $handler.Responses.Enqueue((New-Response 302 -Location 'http://release-assets.githubusercontent.com/test')) }
        'redirect-limit' { 1..4 | ForEach-Object { $handler.Responses.Enqueue((New-Response 302 -Location 'https://release-assets.githubusercontent.com/test')) } }
        'wrong-range' { $response.StatusCode = 206; $response.Content.Headers.ContentRange = [Net.Http.Headers.ContentRangeHeaderValue]::new(1, 100000, 100001) }
        'http' { $response.StatusCode = 403 }
        'transport' { $handler.ThrowTransport = $true }
        'oversize' { $response.Dispose(); $response = New-Response 200 (New-Pe 0xAA64 257); $response.Content.Headers.ContentLength = 256 }
        'truncated' { $response.Dispose(); $response = New-Response 200 (New-Pe 0xAA64 255); $response.Content.Headers.ContentLength = 256 }
        'encoded' { $response.Content.Headers.ContentEncoding.Add('gzip') }
    }
    $handler.Responses.Enqueue($response)
    $errorText = ''; $bytes = $null; $budget = New-Budget
    try {
        try { $bytes = Receive-ReleaseBytes -Uri 'https://github.com/owner/repo/releases/download/v1/app.exe' -ExpectedSize $size -PrefixOnly $prefix -Budget $budget -Client $client }
        catch { $errorText = $_.Exception.Message }
        if ($case -in 'prefix', 'range', 'zip', 'redirect') {
            $expected = if ($prefix) { 65536 } else { 256 }
            Assert (-not $errorText -and $bytes.Length -eq $expected -and $budget.remainingBytes -eq 128MB - $expected) "Bounded real stream read: $case ($errorText)"
            Assert ($handler.Ranges[0] -eq $(if ($prefix) { 'bytes=0-65535' } else { '' })) "PE range/ZIP full request: $case"
        } else {
            Assert ($errorText -and $errorText -notmatch 'do-not-retain|secret=|evil.invalid') "Explicit sanitized transport failure: $case"
        }
        Assert (-not $handler.CredentialsSeen) "No authorization or cookies on asset/CDN requests: $case"
        if ($case -in 'evil-redirect', 'downgrade') { Assert ($handler.Urls.Count -eq 1) 'Redirect host validated before connecting' }
        if ($case -eq 'redirect-limit') { Assert ($handler.Urls.Count -eq 4) 'Initial request plus at most three redirects' }
    } finally {
        while ($handler.Responses.Count) { $handler.Responses.Dequeue().Dispose() }
        $client.Dispose()
    }
}
Write-Host "$checks release binary inspection checks passed."
