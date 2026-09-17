function Get-GitHubTrendingUri([string] $Language = '') {
    if ($Language -cnotin @('', 'c', 'c++', 'rust', 'go', 'python', 'javascript', 'typescript', 'c#')) {
        throw 'Only the reviewed weekly Trending languages are allowed.'
    }
    if (-not $Language) { return 'https://github.com/trending?since=weekly' }
    "https://github.com/trending/$([uri]::EscapeDataString($Language))?since=weekly"
}

function Receive-GitHubTrending([string] $Language = '') {
    $uri = Get-GitHubTrendingUri $Language
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenArm-Repository-Discovery')
    $client.DefaultRequestHeaders.AcceptLanguage.ParseAdd('en-US')
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    $response = $null; $stream = $null
    $body = [IO.MemoryStream]::new()
    try {
        $response = $client.GetAsync($uri,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) { throw "GitHub Trending returned HTTP $([int]$response.StatusCode); no retry or alternate ranking was used." }
        if ($response.Content.Headers.ContentType.MediaType -ne 'text/html' -or
            $response.Content.Headers.ContentLength -gt 2MB) { throw 'GitHub Trending response must be HTML within 2 MiB.' }
        $stream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($body.Length + $count -gt 2MB) { throw 'GitHub Trending response exceeds 2 MiB.' }
            $body.Write($buffer, 0, $count)
        }
        [Text.UTF8Encoding]::new($false, $true).GetString($body.ToArray())
    } catch [Net.Http.HttpRequestException] {
        throw 'GitHub Trending transport failed; no request was retried.'
    } catch [OperationCanceledException] {
        throw 'GitHub Trending exceeded its 30-second deadline; no request was retried.'
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $body.Dispose(); $deadline.Dispose(); $client.Dispose()
    }
}

function ConvertFrom-GitHubTrending([string] $Html) {
    if ([Text.Encoding]::UTF8.GetByteCount($Html) -gt 2MB) { throw 'GitHub Trending HTML exceeds 2 MiB.' }
    $pattern = [regex]::new('<article\b[^>]*class="[^"]*\bBox-row\b[^"]*"[^>]*>(.*?)</article>',
        [Text.RegularExpressions.RegexOptions]::Singleline, [TimeSpan]::FromSeconds(2))
    $articles = $pattern.Matches($Html)
    if ($articles.Count -lt 1 -or $articles.Count -gt 100) { throw 'GitHub Trending markup is missing or outside the reviewed page scope.' }
    $items = @(); $seen = @{}
    foreach ($article in $articles) {
        $link = [regex]::Match($article.Value, '(?s)<h2\b[^>]*>.*?<a\b[^>]*href="/([^"?#]+)"')
        $growth = [regex]::Match($article.Value, '(?<![\d,])(\d{1,3}(?:,\d{3})+|\d+)\s+stars this week\b')
        $name = $link.Groups[1].Value
        $stars = 0L
        if (-not $link.Success -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
            $seen.ContainsKey($name) -or -not $growth.Success -or
            -not [long]::TryParse($growth.Groups[1].Value.Replace(',', ''), [ref] $stars)) {
            throw 'GitHub Trending repository or weekly-star evidence is missing, duplicated or malformed.'
        }
        $seen[$name] = $true
        $items += @{ fullName = $name; rank = $items.Count + 1; weeklyStars = $stars }
    }
    @{
        availableCount = $articles.Count; items = $items
        snapshotSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Html))).ToLowerInvariant()
    }
}

function Read-FoundationalRepositories {
    $path = Join-Path $PSScriptRoot '..\targets\discovery\foundational.json'
    $config = Read-Json $path
    if ($config.schemaVersion -ne 1 -or $config.repositories -isnot [array] -or
        $config.repositories.Count -lt 1 -or $config.repositories.Count -gt 100) {
        throw 'The reviewed foundational catalog must contain one to one hundred repositories.'
    }
    $seen = @{}; $items = @()
    foreach ($entry in $config.repositories) {
        if ($entry.fullName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
            $seen.ContainsKey($entry.fullName) -or $entry.category -notin @('runtime', 'toolchain', 'library') -or
            $entry.reason -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.reason) -or $entry.reason.Length -gt 1000) {
            throw 'Foundational catalog contains a duplicate, invalid repository or missing review rationale.'
        }
        $seen[$entry.fullName] = $true
        $items += @{ fullName = $entry.fullName; rank = $items.Count + 1; category = $entry.category; reason = $entry.reason }
    }
    @{ items = $items; catalogSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
