function Test-ReleaseDownloadUri([uri] $Uri, [string] $Repository = '') {
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or
        $Uri.UserInfo -or $Uri.Fragment) { return $false }
    if ($Repository) {
        return $Uri.Host -ceq 'github.com' -and -not $Uri.Query -and
            $Uri.AbsolutePath.StartsWith("/$Repository/releases/download/", [StringComparison]::Ordinal) -and
            $Uri.AbsolutePath.Substring("/$Repository/releases/download/".Length) -match '^[^/]+/[^/]+$'
    }
    $Uri.Host -cin @('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')
}

function Receive-ReleaseBytes {
    param([uri] $Uri, [long] $ExpectedSize, [bool] $PrefixOnly, [hashtable] $Budget,
        [Net.Http.HttpClient] $Client)
    $ownedClient = $null -eq $Client
    if ($ownedClient) {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.UseDefaultCredentials = $false
        $Client = [Net.Http.HttpClient]::new($handler)
    }
    $timeout = [Threading.CancellationTokenSource]::new()
    $buffer = [byte[]]::new(8192)
    $content = [IO.MemoryStream]::new()
    try {
        $seconds = [Math]::Min(30, 180 - $Budget.clock.Elapsed.TotalSeconds)
        if ($seconds -le 0) { throw 'Release inspection time budget exhausted.' }
        $timeout.CancelAfter([TimeSpan]::FromSeconds($seconds))
        $limit = if ($PrefixOnly) { [Math]::Min(65536, $ExpectedSize) } else { $ExpectedSize }
        if ($limit -lt 1 -or $limit -gt 16MB -or $limit + 1 -gt $Budget.remainingBytes) {
            throw 'Release inspection byte budget exceeded.'
        }
        for ($redirect = 0; $redirect -le 3; $redirect++) {
            if (-not (Test-ReleaseDownloadUri $Uri)) { throw 'Release download destination is not allowed.' }
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
            $request.Headers.UserAgent.ParseAdd('OpenArm-Release-Inspection')
            $request.Headers.AcceptEncoding.ParseAdd('identity')
            if ($PrefixOnly) { $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(0, $limit - 1) }
            $response = $null
            try {
                $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $timeout.Token).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -in 301, 302, 303, 307, 308) {
                    if ($redirect -eq 3 -or $null -eq $response.Headers.Location) { throw 'Release redirect limit or invalid redirect.' }
                    $Uri = [uri]::new($Uri, $response.Headers.Location)
                    continue
                }
                if ($status -ne 200 -and -not ($PrefixOnly -and $status -eq 206)) {
                    throw "Release download failed (HTTP $status)."
                }
                if ($status -eq 206 -and ($null -eq $response.Content.Headers.ContentRange -or
                    $response.Content.Headers.ContentRange.From -ne 0)) { throw 'Release download returned an invalid range.' }
                if ($response.Content.Headers.ContentEncoding.Count) { throw 'Encoded release downloads are not inspected.' }
                if (-not $PrefixOnly -and $null -ne $response.Content.Headers.ContentLength -and
                    $response.Content.Headers.ContentLength -ne $ExpectedSize) { throw 'Release download size differs from metadata.' }
                $stream = $response.Content.ReadAsStreamAsync($timeout.Token).GetAwaiter().GetResult()
                try {
                    $readLimit = if ($PrefixOnly) { $limit } else { $limit + 1 }
                    while ($content.Length -lt $readLimit) {
                        $count = [int][Math]::Min($buffer.Length, $readLimit - $content.Length)
                        $read = $stream.ReadAsync($buffer, 0, $count, $timeout.Token).GetAwaiter().GetResult()
                        if ($read -eq 0) { break }
                        $Budget.remainingBytes -= $read
                        $content.Write($buffer, 0, $read)
                    }
                } finally { $stream.Dispose() }
                if ($content.Length -ne $limit) { throw 'Release download size differs from metadata.' }
                return ,$content.ToArray()
            } finally {
                if ($response) { $response.Dispose() }
                $request.Dispose()
            }
        }
    } catch {
        # Never retain transport exceptions: they can contain signed redirect URLs.
        $message = $_.Exception.Message
        if ($message -notmatch '^Release (download failed \(HTTP \d+\)\.|download size differs from metadata\.|download destination is not allowed\.|redirect limit or invalid redirect\.|download returned an invalid range\.|inspection (?:time budget exhausted|byte budget exceeded)\.)$' -and
            $message -ne 'Encoded release downloads are not inspected.') {
            $message = 'Release download transport failed or timed out; no retry was attempted.'
        }
        throw $message
    } finally {
        $content.Dispose()
        $timeout.Dispose()
        if ($ownedClient) { $Client.Dispose() }
    }
}

function Get-ReleasePeEvidence([byte[]] $Bytes, [long] $Size, [string] $Name) {
    $result = @{ name = $Name; size = $Size; status = 'invalid_pe'; machine = $null; architecture = $null }
    if ($Size -eq 0) { $result.status = 'empty'; return $result }
    if ($Bytes.Length -ge 64 -and [BitConverter]::ToUInt16($Bytes, 0) -eq 0x5A4D) {
        $offset = [BitConverter]::ToInt32($Bytes, 0x3C)
        if ($offset -ge 64 -and $offset -le $Size - 6 -and $offset -gt $Bytes.Length - 6) {
            $result.status = 'header_outside_limit'
            return $result
        }
    }
    try { $machine = Get-PeMachine -Bytes $Bytes }
    catch { return $result }
    $result.machine = '0x{0:X4}' -f $machine
    $result.architecture = switch ($machine) {
        0xAA64 { 'arm64' }; 0xA641 { 'arm64ec' }; 0xA64E { 'arm64x' }
        0x8664 { 'x64' }; 0x014C { 'x86' }; 0x01C4 { 'arm32' }; default { 'unknown' }
    }
    $result.status = 'pe_header'
    $result
}

function Get-ReleaseAssetEvidence([hashtable] $Asset, [hashtable] $Budget) {
    $isPe = $Asset.name -match '(?i)\.(exe|dll)$'
    $isZip = $Asset.name -match '(?i)\.zip$'
    if ($Asset.size -eq 0) { $Asset.inspection = 'empty'; return }
    if ($Asset.state -ne 'uploaded') { $Asset.inspection = 'not_uploaded'; return }
    if ((-not $isPe -and -not $isZip) -or $Asset.platformHint -eq 'other') { return }
    if ($isZip -and $Asset.size -gt 16MB) { $Asset.inspection = 'size_limit'; return }
    $bytesNeeded = if ($isPe) { [Math]::Min(65536, $Asset.size) } else { $Asset.size }
    if ($Budget.assetCount -ge 3 -or $bytesNeeded + 1 -gt $Budget.remainingBytes -or $Budget.clock.Elapsed.TotalSeconds -ge 180) {
        $Asset.inspection = 'budget_limit'
        return
    }
    $Budget.assetCount++
    $Asset.inspection = 'downloading'
    try { [byte[]]$bytes = Receive-ReleaseBytes -Uri $Asset.url -ExpectedSize $Asset.size -PrefixOnly $isPe -Budget $Budget }
    catch { $Asset.inspection = 'download_error'; $Asset.error = $_.Exception.Message; throw }
    $Asset.sampleBytes = $bytes.Length
    $Asset.sampleSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($isPe) {
        $Asset.binaries = @(Get-ReleasePeEvidence $bytes $Asset.size $Asset.name)
        $Asset.inspection = $Asset.binaries[0].status
    } else {
        $stream = [IO.MemoryStream]::new($bytes, $false)
        $archive = $null
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
            $Asset.archiveEntryCount = $archive.Entries.Count
            if ($archive.Entries.Count -gt 512) { $Asset.inspection = 'archive_entry_limit'; return }
            $entries = @($archive.Entries | Where-Object FullName -match '(?i)\.(exe|dll)$')
            $Asset.archivePeCount = $entries.Count
            $Asset.inspection = if ($entries.Count -gt 16) { 'archive_binary_limit' } elseif ($entries.Count) { 'pe_headers' } else { 'no_pe_found' }
            foreach ($entry in ($entries | Select-Object -First 16)) {
                $entryStream = $entry.Open()
                try {
                    $header = [byte[]]::new([int][Math]::Min(65536, $entry.Length))
                    $read = 0
                    while ($read -lt $header.Length) {
                        $count = $entryStream.Read($header, $read, $header.Length - $read)
                        if ($count -eq 0) { throw [IO.InvalidDataException]::new('Truncated ZIP entry.') }
                        $read += $count
                    }
                    $Asset.binaries += Get-ReleasePeEvidence $header $entry.Length $entry.FullName
                } finally { $entryStream.Dispose() }
            }
        } catch {
            $Asset.inspection = 'invalid_archive'
            $Asset.error = 'ZIP structure or entry data could not be read; no files were extracted.'
        } finally {
            if ($archive) { $archive.Dispose() }
            $stream.Dispose()
        }
    }
    $Asset.architectures = @($Asset.binaries | Where-Object status -eq 'pe_header' | ForEach-Object architecture | Sort-Object -Unique)
    $Asset.architectureMismatch = $Asset.architectureHint -ne 'unknown' -and $Asset.architectures.Count -gt 0 -and
        @($Asset.architectures | Where-Object { $_ -eq $Asset.architectureHint -or ($Asset.architectureHint -eq 'arm64' -and $_ -in 'arm64ec', 'arm64x') }).Count -eq 0
}

function Get-ReleaseEvidence {
    param($Release, [string] $Repository, [hashtable] $Budget, [hashtable] $Result = @{})
    $fields = @{
        status = 'no_published_release'; tag = $null; publishedAt = $null; url = $null
        inventory = 'latest_release_response_only'; returnedAssetCount = 0; metadataTruncated = $false
        assets = @(); windowsArm64 = 'unknown'; inspectedArchitectures = @(); artifactProblem = $false
    }
    foreach ($key in $fields.Keys) { $Result[$key] = $fields[$key] }
    if ($null -eq $Release) { return $result }
    $date = $Release.published_at
    if ($date -is [DateTime] -or $date -is [DateTimeOffset]) { $date = $date.ToUniversalTime().ToString('o') }
    $published = [DateTimeOffset]::MinValue
    if ($Release.tag_name -isnot [string] -or -not $Release.tag_name -or
        $date -isnot [string] -or -not [DateTimeOffset]::TryParse($date, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$published) -or
        $Release.draft -isnot [bool] -or $Release.draft -or
        $Release.prerelease -isnot [bool] -or $Release.prerelease -or $Release.assets -isnot [array]) {
        throw 'GitHub returned invalid latest-release metadata.'
    }
    $result.status = 'assessed'
    $result.tag = $Release.tag_name
    $result.publishedAt = $published.ToUniversalTime().ToString('o')
    $result.url = "https://github.com/$Repository/releases/tag/$([uri]::EscapeDataString($Release.tag_name))"
    $result.returnedAssetCount = $Release.assets.Count
    $result.metadataTruncated = $Release.assets.Count -gt 100
    $seen = @{}
    foreach ($asset in ($Release.assets | Select-Object -First 100)) {
        $uri = $null
        if ($asset.name -isnot [string] -or -not $asset.name -or $asset.name.Length -gt 1024 -or
            $seen.ContainsKey($asset.name) -or ($asset.size -isnot [int] -and $asset.size -isnot [long]) -or $asset.size -lt 0 -or
            $asset.state -isnot [string] -or $asset.browser_download_url -isnot [string] -or
            -not [uri]::TryCreate($asset.browser_download_url, [UriKind]::Absolute, [ref]$uri) -or
            -not (Test-ReleaseDownloadUri $uri $Repository)) { throw 'GitHub returned invalid or out-of-scope release asset metadata.' }
        $seen[$asset.name] = $true
        $platform = if ($asset.name -match '(?i)(?:^|[-_.])(?:win(?:dows|32|64)?|msvc)(?:[-_.]|$)|\.(exe|dll|msi|msix)$') { 'windows' }
            elseif ($asset.name -match '(?i)(?:^|[-_.])(?:linux|darwin|macos|osx|android)(?:[-_.]|$)') { 'other' } else { 'unknown' }
        $arch = if ($asset.name -match '(?i)(?:^|[-_.])(?:arm64|aarch64)(?:[-_.]|$)') { 'arm64' }
            elseif ($asset.name -match '(?i)(?:^|[-_.])(?:x64|amd64|x86_64|win64)(?:[-_.]|$)') { 'x64' }
            elseif ($asset.name -match '(?i)(?:^|[-_.])(?:x86|i686)(?:[-_.]|$)') { 'x86' } else { 'unknown' }
        $result.assets += @{
            name = $asset.name; url = $uri.AbsoluteUri.Replace('(', '%28').Replace(')', '%29'); size = $asset.size; state = $asset.state
            platformHint = $platform; architectureHint = $arch; inspection = 'uninspected_format'
            sampleBytes = 0; sampleSha256 = $null; archiveEntryCount = $null; archivePeCount = $null
            binaries = @(); architectures = @(); architectureMismatch = $false; error = $null
        }
    }
    $Budget.assetCount = 0
    # Prefer advertised Windows Arm64 artifacts, then other Windows assets; retain API order in reports.
    $ordered = $result.assets | Sort-Object @{ Expression = {
        if ($_.platformHint -eq 'windows' -and $_.architectureHint -eq 'arm64') { 0 }
        elseif ($_.platformHint -eq 'windows') { 1 } else { 2 }
    } }, name
    foreach ($asset in $ordered) { Get-ReleaseAssetEvidence $asset $Budget }
    $result.inspectedArchitectures = @($result.assets | ForEach-Object architectures | Sort-Object -Unique)
    $advertised = @($result.assets | Where-Object { $_.platformHint -eq 'windows' -and $_.architectureHint -eq 'arm64' })
    $result.artifactProblem = @($result.assets | Where-Object {
        ($_.platformHint -eq 'windows' -or $_.binaries.Count) -and
        ($_.inspection -in 'empty', 'invalid_pe', 'invalid_archive' -or $_.architectureMismatch -or
        @($_.binaries | Where-Object status -in 'empty', 'invalid_pe').Count)
    }).Count -gt 0
    $result.windowsArm64 = if (@($result.inspectedArchitectures | Where-Object { $_ -in 'arm64', 'arm64ec', 'arm64x' }).Count) { 'pe_header_found' }
        elseif ($advertised.Count) { 'advertised_unverified' }
        elseif ($result.inspectedArchitectures -contains 'x64') { 'x64_observed_arm64_not_found_in_sample' }
        else { 'unknown' }
    $result
}
