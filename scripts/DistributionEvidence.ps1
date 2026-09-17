function Read-DistributionChannels {
    $path = Join-Path $PSScriptRoot '..\targets\discovery\distribution-channels.json'
    $config = Read-Json $path
    if ($config.schemaVersion -ne 1 -or $config.repositories -isnot [array] -or $config.repositories.Count -gt 50) {
        throw 'The reviewed distribution-channel catalog must contain at most fifty repositories.'
    }
    $repositories = @{}
    foreach ($entry in $config.repositories) {
        if ($entry.fullName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
            $repositories.ContainsKey($entry.fullName) -or $entry.channels -isnot [array] -or
            $entry.channels.Count -lt 1 -or $entry.channels.Count -gt 3) {
            throw 'Invalid repository or channel count in the distribution-channel catalog.'
        }
        $seen = @{}
        foreach ($channel in $entry.channels) {
            if ($channel.provider -cnotin @('github', 'pypi', 'npm') -or $seen.ContainsKey($channel.provider)) {
                throw 'Distribution providers must be reviewed, unique GitHub, PyPI or npm channels.'
            }
            if (($channel.provider -eq 'pypi' -and ($channel.package -isnot [string] -or
                    $channel.package -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$')) -or
                ($channel.provider -eq 'npm' -and ($channel.package -isnot [string] -or $channel.package.Length -gt 214 -or
                    $channel.package -cnotmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$'))) {
                throw 'Invalid reviewed package name in the distribution-channel catalog.'
            }
            $seen[$channel.provider] = $true
        }
        $repositories[$entry.fullName] = $entry.channels
    }
    @{ repositories = $repositories; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Receive-DistributionMetadata([uri] $Uri, [hashtable] $Request, [Net.Http.HttpClient] $Client) {
    if ($Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Query -or $Uri.Fragment -or
        -not (($Uri.Host -ceq 'pypi.org' -and $Uri.AbsolutePath -cmatch '^/pypi/[A-Za-z0-9][A-Za-z0-9._-]{0,99}/json$') -or
            ($Uri.Host -ceq 'registry.npmjs.org' -and $Uri.AbsolutePath -cmatch '^/[^/]+/latest$'))) {
        throw 'Package metadata must use a fixed public PyPI or npm endpoint.'
    }
    $ownedClient = $null -eq $Client
    if ($ownedClient) {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.UseDefaultCredentials = $false
        $Client = [Net.Http.HttpClient]::new($handler)
    }
    if ($Client.DefaultRequestHeaders.Contains('Authorization') -or $Client.DefaultRequestHeaders.Contains('Cookie') -or
        $Client.DefaultRequestHeaders.Contains('Proxy-Authorization')) {
        throw 'Package metadata clients must not carry credentials or cookies.'
    }
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    $message.Headers.Accept.ParseAdd('application/json')
    $message.Headers.UserAgent.ParseAdd('OpenArm-Distribution-Discovery')
    $response = $null; $stream = $null
    $body = [IO.MemoryStream]::new()
    try {
        $response = $Client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        $Request.httpStatus = [int]$response.StatusCode
        if ($Request.httpStatus -eq 404) { return $null }
        if ($Request.httpStatus -ne 200) { throw "Package metadata request failed (HTTP $($Request.httpStatus)); no retry was attempted." }
        if ($response.Content.Headers.ContentType.MediaType -ne 'application/json' -or
            $response.Content.Headers.ContentLength -gt 16MB -or $response.Content.Headers.ContentEncoding.Count) {
            throw 'Package metadata must be unencoded JSON within 16 MiB.'
        }
        $stream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($body.Length + $count -gt 16MB) { throw 'Package metadata exceeds 16 MiB.' }
            $body.Write($buffer, 0, $count)
        }
        $Request.bytes = $body.Length
        $Request.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body.ToArray())).ToLowerInvariant()
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($body.ToArray())
        try { $metadata = $text | ConvertFrom-Json -AsHashtable -Depth 64 -NoEnumerate }
        catch { throw 'Package metadata is not valid bounded JSON.' }
        if ($metadata -isnot [hashtable]) { throw 'Package metadata must be a JSON object.' }
        $metadata
    } catch [Net.Http.HttpRequestException] {
        throw 'Package metadata transport failed; no request was retried.'
    } catch [OperationCanceledException] {
        throw 'Package metadata exceeded its 30-second deadline; no request was retried.'
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $message.Dispose(); $body.Dispose(); $deadline.Dispose()
        if ($ownedClient) { $Client.Dispose() }
    }
}

function Get-RegistryDistributionEvidence([hashtable] $Channel, $Metadata) {
    $result = @{ provider = $Channel.provider; package = $Channel.package; status = 'unverified'; version = $null; examples = @() }
    if ($null -eq $Metadata) { $result.reason = 'package_not_found'; return $result }
    if ($Channel.provider -eq 'pypi') {
        if ($Metadata.info.name -isnot [string] -or
            ($Metadata.info.name.ToLowerInvariant() -replace '[-_.]+', '-') -cne ($Channel.package.ToLowerInvariant() -replace '[-_.]+', '-') -or
            $Metadata.info.version -isnot [string] -or $Metadata.info.version -cnotmatch '^[0-9][0-9A-Za-z!+._-]{0,127}$' -or
            $Metadata.urls -isnot [array]) {
            throw 'PyPI returned invalid or mismatched package metadata.'
        }
        $result.version = $Metadata.info.version
        if ($Metadata.urls.Count -gt 500) { $result.reason = 'file_inventory_limit'; return $result }
        $wheels = @(); $native = @(); $portable = $false
        foreach ($file in $Metadata.urls) {
            if ($file.filename -isnot [string] -or $file.filename.Length -gt 512 -or $file.packagetype -isnot [string] -or
                $file.yanked -isnot [bool] -or ($file.size -isnot [int] -and $file.size -isnot [long]) -or $file.size -lt 0) {
                throw 'PyPI returned invalid distribution file metadata.'
            }
            if (-not $file.yanked -and $file.size -gt 0 -and $file.packagetype -eq 'bdist_wheel') {
                if ($file.filename -cnotmatch '^[A-Za-z0-9_.]+-[0-9A-Za-z!+._]+(?:-[0-9][0-9A-Za-z_.]*)?-[A-Za-z0-9_.]+-[A-Za-z0-9_.]+-[A-Za-z0-9_.]+\.whl$') {
                    throw 'PyPI returned an invalid wheel filename.'
                }
                $wheels += $file.filename
                $platforms = $file.filename.Substring(0, $file.filename.Length - 4).Split('-')[-1].Split('.')
                if ($platforms -contains 'win_arm64') { $native += $file.filename }
                if ($platforms -contains 'any') { $portable = $true }
            }
        }
        if ($native.Count) { $result.status = 'native_advertised'; $result.examples = @($native | Select-Object -First 5) }
        elseif ($portable) { $result.status = 'portable_distribution' }
        elseif ($wheels.Count) { $result.status = 'missing_in_channel'; $result.reason = 'no_windows_arm64_wheel_in_current_release' }
        else { $result.reason = 'no_current_wheel_inventory' }
    } else {
        if ($Metadata.name -cne $Channel.package -or $Metadata.version -isnot [string] -or
            $Metadata.version -cnotmatch '^[0-9][0-9A-Za-z!+._-]{0,127}$') {
            throw 'npm returned invalid or mismatched package metadata.'
        }
        $result.version = $Metadata.version
        $optional = if ($Metadata.ContainsKey('optionalDependencies')) { $Metadata.optionalDependencies } else { @{} }
        if ($optional -isnot [hashtable] -or $optional.Count -gt 100) { $result.reason = 'unverified_optional_dependencies'; return $result }
        if (@($optional.Keys | Where-Object { $_.Length -gt 214 -or $_ -cnotmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$' }).Count) {
            throw 'npm returned invalid optional package names.'
        }
        $native = @($optional.Keys | Where-Object { $_ -cmatch '(?:win32|windows)[-_]arm64(?:$|[-_])|arm64[-_](?:win32|windows)(?:$|[-_])' })
        $os = @(); $cpu = @()
        if ($Metadata.ContainsKey('os')) { $os = $Metadata.os }
        if ($Metadata.ContainsKey('cpu')) { $cpu = $Metadata.cpu }
        if ($os -isnot [array] -or $cpu -isnot [array]) { throw 'npm returned invalid platform metadata.' }
        if ($native.Count -or ($os -contains 'win32' -and $cpu -contains 'arm64')) {
            $result.status = 'native_advertised'; $result.examples = @($native | Select-Object -First 5)
        } elseif ($os -contains 'win32' -and $cpu.Count -gt 0 -and
            -not @($cpu | Where-Object { $_ -cnotin @('x64', 'ia32', 'arm') }).Count) {
            $result.status = 'missing_in_channel'; $result.reason = 'no_arm64_in_declared_windows_packages'
        } else { $result.reason = 'unverified_npm_platform_coverage' }
    }
    $result
}

function Get-GitHubDistributionEvidence([hashtable] $Release) {
    $result = @{ provider = 'github'; status = 'unverified'; url = $Release.url; version = $Release.tag; examples = @() }
    if ($Release.windowsArm64 -in @('pe_header_found', 'advertised_unverified')) {
        $result.status = 'native_advertised'
        return $result
    }
    if ($Release.status -ne 'assessed' -or $Release.metadataTruncated -or $Release.returnedAssetCount -ge 100 -or $Release.artifactProblem) {
        $result.reason = 'incomplete_or_invalid_release_evidence'
        return $result
    }
    $assets = @($Release.assets | Where-Object {
        $_.platformHint -ne 'other' -and
        $_.name -notmatch '(?i)(?:\.(?:sha256|sha512|sig|asc|txt)$|^(?:sha(?:256|512)?sums|checksums)(?:\.[^.]+)?$)'
    })
    $windows = @($assets | Where-Object platformHint -eq 'windows')
    if ($windows.Count -and -not @($assets | Where-Object {
        $_.inspection -notin @('pe_header', 'pe_headers') -or $_.architectureHint -notin @('x64', 'x86') -or -not $_.binaries.Count -or
        @($_.binaries | Where-Object { $_.status -ne 'pe_header' -or $_.architecture -notin @('x64', 'x86') }).Count
    }).Count) {
        $result.status = 'missing_in_channel'; $result.reason = 'reviewed_windows_release_artifacts_have_no_arm64'
    } else { $result.reason = 'unverified_release_artifacts' }
    $result
}
