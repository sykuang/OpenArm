Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Common.ps1"
. "$PSScriptRoot\..\scripts\DistributionEvidence.ps1"
$checks = 0
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function Must-Fail([scriptblock] $Action, [string] $Message) {
    $failed = $false
    try { $null = & $Action } catch { $failed = $true }
    Assert $failed $Message
}
function PyPi([array] $Files) {
    @{ info = @{ name = 'numpy'; version = '2.5.3' }; urls = $Files }
}
function Wheel([string] $Tag, [bool] $Yanked = $false) {
    @{ filename = "numpy-2.5.3-$Tag.whl"; packagetype = 'bdist_wheel'; size = 100; yanked = $Yanked }
}
$pypi = @{ provider = 'pypi'; package = 'numpy' }
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(Wheel 'cp312-cp312-win_arm64'))).status -eq 'native_advertised') 'Windows Arm64 wheels exclude a porting candidate'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(Wheel 'cp312-cp312-win_amd64.win_arm64'))).status -eq 'native_advertised') 'Compressed wheel platform tags cannot hide existing Arm64 support'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(Wheel 'py3-none-any'))).status -eq 'portable_distribution') 'Portable wheels are not assumed to require a native port'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(Wheel 'cp312-cp312-win_amd64'))).status -eq 'missing_in_channel') 'Complete current wheel inventory can corroborate an explicit missing-platform report'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(Wheel 'cp312-cp312-win_arm64' $true))).status -eq 'unverified') 'Only yanked wheels cannot establish available support or a confirmed gap'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @())).status -eq 'unverified') 'Empty distribution inventory is unknown, not an Arm64-specific gap'
Assert ((Get-RegistryDistributionEvidence $pypi (PyPi @(1..501 | ForEach-Object { Wheel 'cp312-cp312-win_amd64' }))).status -eq 'unverified') 'File inventory limits do not establish absence'
Must-Fail { Get-RegistryDistributionEvidence $pypi @{ info = @{ name = 'other'; version = '2.5.3' }; urls = @() } } 'Package identity mismatches fail'
Must-Fail { Get-RegistryDistributionEvidence $pypi (PyPi @(@{ filename = 'not-a-wheel.whl'; packagetype = 'bdist_wheel'; size = 1; yanked = $false })) } 'Malformed wheel records cannot establish a missing-platform gap'
$npm = @{ provider = 'npm'; package = '@owner/app' }
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0'; os = @('win32'); cpu = @('arm64') }).status -eq 'native_advertised') 'npm native platform declarations exclude a porting candidate'
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0'; optionalDependencies = @{ '@owner/app-win32-arm64' = '1.0.0' } }).status -eq 'native_advertised') 'npm native platform packages are recognized'
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0'; os = @('win32'); cpu = @('x64') }).status -eq 'missing_in_channel') 'Explicit npm CPU restrictions can corroborate missing support'
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0'; optionalDependencies = @{ '@owner/app-win32-x64' = '1.0.0' } }).status -eq 'unverified') 'An optional x64 package alone cannot rule out bundled or downloaded Arm64 support'
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0' }).status -eq 'unverified') 'Generic JavaScript metadata is not missing-native-support proof'
Assert ((Get-RegistryDistributionEvidence $npm @{ name = '@owner/app'; version = '1.0.0'; os = @('win32'); cpu = @('!ia32') }).status -eq 'unverified') 'A negative npm CPU selector does not exclude Arm64'

Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class DistributionTestContent : HttpContent {
    private readonly byte[] bytes;
    public DistributionTestContent(string text, string contentType) {
        bytes = System.Text.Encoding.UTF8.GetBytes(text);
        Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
    }
    protected override bool TryComputeLength(out long length) { length = 0; return false; }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext context) {
        return stream.WriteAsync(bytes, 0, bytes.Length);
    }
}
public sealed class DistributionTestHandler : HttpMessageHandler {
    public int Calls;
    public int Status = 200;
    public string Body = "{}";
    public string ContentType = "application/json";
    public string Method, Uri, Authorization, Cookie;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Calls++;
        Method = request.Method.Method;
        Uri = request.RequestUri.AbsoluteUri;
        Authorization = request.Headers.Authorization == null ? "" : request.Headers.Authorization.ToString();
        Cookie = request.Headers.Contains("Cookie") ? "present" : "";
        var response = new HttpResponseMessage((HttpStatusCode)Status);
        response.Content = new DistributionTestContent(Body, ContentType);
        if (Status == 302) response.Headers.Location = new Uri("https://evil.invalid/");
        return Task.FromResult(response);
    }
}
'@
foreach ($uri in 'https://pypi.org/pypi/numpy/json', 'https://registry.npmjs.org/%40owner%2Fapp/latest') {
    $handler = [DistributionTestHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $handler.Body = '{"name":"sample"}'
        $request = @{}
        $data = Receive-DistributionMetadata -Uri $uri -Request $request -Client $client
        Assert ($data.name -eq 'sample' -and $handler.Method -eq 'GET' -and $handler.Calls -eq 1 -and
            -not $handler.Authorization -and -not $handler.Cookie) 'Public registry requests use credential-free GET'
        Assert ($request.httpStatus -eq 200 -and $request.bytes -gt 0 -and $request.sha256 -match '^[a-f0-9]{64}$') 'Registry metadata retains bounded response provenance'
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', 'test-not-a-secret')
        Must-Fail { Receive-DistributionMetadata -Uri $uri -Request @{} -Client $client } 'An injected authenticated client cannot leak credentials to a registry'
        Assert ($handler.Calls -eq 1) 'Credential rejection occurs before another request'
    } finally { $client.Dispose() }
}
foreach ($case in 'redirect', 'rate-limit', 'wrong-type', 'malformed', 'array', 'stream-limit', 'not-found') {
    $handler = [DistributionTestHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        switch ($case) {
            'redirect' { $handler.Status = 302 }
            'rate-limit' { $handler.Status = 429 }
            'wrong-type' { $handler.ContentType = 'text/html' }
            'malformed' { $handler.Body = '{' }
            'array' { $handler.Body = '[]' }
            'stream-limit' { $handler.Body = ' ' * (16MB + 1) }
            'not-found' { $handler.Status = 404 }
        }
        $request = @{}
        if ($case -eq 'not-found') {
            Assert ($null -eq (Receive-DistributionMetadata 'https://pypi.org/pypi/numpy/json' $request $client) -and
                $request.httpStatus -eq 404) 'A missing package is explicit unknown evidence, not a confirmed gap'
        } else {
            Must-Fail { Receive-DistributionMetadata 'https://pypi.org/pypi/numpy/json' $request $client } "Unsafe/incomplete registry response fails: $case"
        }
        Assert ($handler.Calls -eq 1) 'Registry requests never retry or follow redirects'
    } finally { $client.Dispose() }
}
foreach ($uri in 'http://pypi.org/pypi/numpy/json', 'https://pypi.org.evil.invalid/pypi/numpy/json',
    'https://pypi.org:444/pypi/numpy/json', 'https://user@pypi.org/pypi/numpy/json',
    'https://pypi.org/pypi/numpy/json?token=1', 'https://registry.npmjs.org/app/other') {
    Must-Fail { Receive-DistributionMetadata $uri @{} } 'Unreviewed registry destinations are rejected before networking'
}
Write-Host "$checks distribution evidence checks passed."
