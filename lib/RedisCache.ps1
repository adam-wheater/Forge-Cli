$Global:RedisHost = ""
$Global:RedisPort = 6380
$Global:RedisPassword = ""
$Global:RedisCacheEnabled = $false

function Initialize-RedisCache {
    param (
        [Parameter(Mandatory)][string]$ConnectionString
    )

    # Parse Azure Redis connection string format:
    # "hostname:port,password=secret,ssl=True,abortConnect=False"
    # or "hostname:port,password=secret"
    $Global:RedisHost = ""
    $Global:RedisPort = 6380
    $Global:RedisPassword = ""
    $Global:RedisCacheEnabled = $false

    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        Write-Warning "Redis connection string is empty."
        return
    }

    try {
        $parts = $ConnectionString -split ","
        foreach ($part in $parts) {
            $trimmed = $part.Trim()
            if ($trimmed -match "^password=(.+)$") {
                $Global:RedisPassword = $Matches[1]
            } elseif ($trimmed -match "^(.+):(\d+)$" -and -not $trimmed.Contains("=")) {
                $Global:RedisHost = $Matches[1]
                $Global:RedisPort = [int]$Matches[2]
            } elseif (-not $trimmed.Contains("=") -and -not $Global:RedisHost) {
                # Bare hostname without port
                $Global:RedisHost = $trimmed
            }
        }

        if ($Global:RedisHost -and $Global:RedisPassword) {
            $Global:RedisCacheEnabled = $true
        } else {
            Write-Warning "Redis connection string missing host or password."
        }
    } catch {
        Write-Warning "Failed to parse Redis connection string: $($_.Exception.Message)"
    }
}

function Set-CacheValue {
    param (
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [int]$TtlSeconds = 3600
    )

    if (-not $Global:RedisCacheEnabled) { return }

    try {
        $encodedKey = [System.Uri]::EscapeDataString($Key)
        $uri = "https://$($Global:RedisHost):$($Global:RedisPort)/cache/$encodedKey"
        $headers = @{
            "Authorization" = "Bearer $($Global:RedisPassword)"
            "Content-Type"  = "application/json"
        }
        $body = @{
            value = $Value
            ttl   = $TtlSeconds
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    } catch {
        # Fall back silently if Redis unavailable
        Write-Warning "Redis SET failed for key '${Key}': $($_.Exception.Message)"
    }
}

function Get-CacheValue {
    param (
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Global:RedisCacheEnabled) { return $null }

    try {
        $encodedKey = [System.Uri]::EscapeDataString($Key)
        $uri = "https://$($Global:RedisHost):$($Global:RedisPort)/cache/$encodedKey"
        $headers = @{
            "Authorization" = "Bearer $($Global:RedisPassword)"
        }
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        return $response.value
    } catch {
        # Return null silently if Redis unavailable or key missing
        return $null
    }
}

function Remove-CacheValue {
    param (
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Global:RedisCacheEnabled) { return }

    try {
        $encodedKey = [System.Uri]::EscapeDataString($Key)
        $uri = "https://$($Global:RedisHost):$($Global:RedisPort)/cache/$encodedKey"
        $headers = @{
            "Authorization" = "Bearer $($Global:RedisPassword)"
        }
        Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Redis DELETE failed for key '${Key}': $($_.Exception.Message)"
    }
}

function Search-CacheKeys {
    param (
        [Parameter(Mandatory)][string]$Pattern
    )

    if (-not $Global:RedisCacheEnabled) { return @() }

    try {
        $encodedPattern = [System.Uri]::EscapeDataString($Pattern)
        $uri = "https://$($Global:RedisHost):$($Global:RedisPort)/cache?pattern=$encodedPattern"
        $headers = @{
            "Authorization" = "Bearer $($Global:RedisPassword)"
        }
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        return @($response.keys)
    } catch {
        return @()
    }
}

function Test-RedisConnection {
    if (-not $Global:RedisCacheEnabled) { return $false }

    try {
        $uri = "https://$($Global:RedisHost):$($Global:RedisPort)/cache/_ping"
        $headers = @{
            "Authorization" = "Bearer $($Global:RedisPassword)"
        }
        Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ============================================================
# CONFIGURABLE MEMORY BACKEND (F07)
# ============================================================

function Get-MemoryBackend {
    if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey("memoryBackend")) {
        return $Global:ForgeConfig.memoryBackend
    }
    return "local"
}

function Save-MemoryValue {
    param (
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [string]$MemoryRoot = (Join-Path $PSScriptRoot ".." "memory")
    )

    $backend = Get-MemoryBackend

    # RC-C1: Validate key contains only safe characters (prevent path traversal)
    if ($Key -notmatch '^[\w\-\.]+$') {
        Write-Warning "Save-MemoryValue: Invalid key '${Key}' — only alphanumeric, hyphens, underscores, and dots allowed"
        return
    }

    if ($backend -eq "redis") {
        Set-CacheValue -Key $Key -Value $Value
    } else {
        # Local file backend — write JSON file to MemoryRoot
        try {
            if (-not (Test-Path $MemoryRoot)) {
                New-Item -ItemType Directory -Path $MemoryRoot -Force | Out-Null
            }
            $filePath = Join-Path $MemoryRoot "$Key.json"
            $data = @{ key = $Key; value = $Value; updatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") }
            $data | ConvertTo-Json -Depth 10 | Out-File $filePath -Encoding utf8
        } catch {
            Write-Warning "Failed to save memory value for key '${Key}': $($_.Exception.Message)"
        }
    }
}

function Read-MemoryValue {
    param (
        [Parameter(Mandatory)][string]$Key,
        [string]$MemoryRoot = (Join-Path $PSScriptRoot ".." "memory")
    )

    $backend = Get-MemoryBackend

    # RC-C1: Validate key contains only safe characters (prevent path traversal)
    if ($Key -notmatch '^[\w\-\.]+$') {
        Write-Warning "Read-MemoryValue: Invalid key '${Key}' — only alphanumeric, hyphens, underscores, and dots allowed"
        return $null
    }

    if ($backend -eq "redis") {
        return Get-CacheValue -Key $Key
    } else {
        # Local file backend — read JSON file from MemoryRoot
        try {
            $filePath = Join-Path $MemoryRoot "$Key.json"
            if (Test-Path $filePath) {
                $data = Get-Content $filePath -Raw | ConvertFrom-Json
                return $data.value
            }
            return $null
        } catch {
            Write-Warning "Failed to read memory value for key '${Key}': $($_.Exception.Message)"
            return $null
        }
    }
}

# ============================================================
# F03 — CROSS-PROJECT KNOWLEDGE SHARING VIA REDIS
# ============================================================

function Save-GlobalPattern {
    param (
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Pattern,
        [double]$SuccessRate = 0.0
    )

    if (-not $Global:RedisCacheEnabled) {
        Write-Warning "Save-GlobalPattern: Redis not available, pattern not saved."
        return $null
    }

    try {
        $patternId = [guid]::NewGuid().ToString("N").Substring(0, 12)
        $redisKey = "forge:global:fixPatterns:${Category}"

        # Retrieve existing patterns list
        $existing = Get-CacheValue -Key $redisKey
        $patterns = @()
        if ($null -ne $existing -and $existing -ne "") {
            try { $patterns = @($existing | ConvertFrom-Json) } catch { $patterns = @() }
        }

        $entry = @{
            id          = $patternId
            pattern     = $Pattern
            successRate = $SuccessRate
            successCount = 0
            failureCount = 0
            createdAt   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            updatedAt   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }

        $patterns += $entry
        $json = ConvertTo-Json -InputObject @($patterns) -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 604800  # 7 days

        return $patternId
    } catch {
        Write-Warning "Save-GlobalPattern failed for category '${Category}': $($_.Exception.Message)"
        return $null
    }
}

function Get-GlobalPatterns {
    param (
        [Parameter(Mandatory)][string]$Category,
        [int]$TopK = 5
    )

    if (-not $Global:RedisCacheEnabled) { return @() }

    try {
        $redisKey = "forge:global:fixPatterns:${Category}"
        $cached = Get-CacheValue -Key $redisKey
        if ($null -eq $cached -or $cached -eq "") { return @() }

        $patterns = @($cached | ConvertFrom-Json)

        # Sort by success rate descending, then by recency (updatedAt descending)
        $sorted = $patterns | Sort-Object -Property @(
            @{ Expression = { [double]$_.successRate }; Descending = $true },
            @{ Expression = { $_.updatedAt }; Descending = $true }
        ) | Select-Object -First $TopK

        return @($sorted)
    } catch {
        Write-Warning "Get-GlobalPatterns failed for category '${Category}': $($_.Exception.Message)"
        return @()
    }
}

function Update-PatternScore {
    param (
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$PatternId,
        [Parameter(Mandatory)][bool]$Success
    )

    if (-not $Global:RedisCacheEnabled) {
        Write-Warning "Update-PatternScore: Redis not available."
        return
    }

    try {
        $redisKey = "forge:global:fixPatterns:${Category}"
        $cached = Get-CacheValue -Key $redisKey
        if ($null -eq $cached -or $cached -eq "") {
            Write-Warning "Update-PatternScore: No patterns found for category '${Category}'."
            return
        }

        $patterns = @($cached | ConvertFrom-Json)
        $updated = $false

        for ($i = 0; $i -lt $patterns.Count; $i++) {
            if ($patterns[$i].id -eq $PatternId) {
                $sc = [int]$patterns[$i].successCount
                $fc = [int]$patterns[$i].failureCount
                if ($Success) {
                    $sc++
                } else {
                    $fc++
                }
                $patterns[$i].successCount = $sc
                $patterns[$i].failureCount = $fc
                $total = $sc + $fc
                if ($total -gt 0) {
                    $patterns[$i].successRate = [Math]::Round($sc / $total, 4)
                }
                $patterns[$i].updatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            Write-Warning "Update-PatternScore: Pattern '${PatternId}' not found in category '${Category}'."
            return
        }

        $json = ConvertTo-Json -InputObject @($patterns) -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 604800
    } catch {
        Write-Warning "Update-PatternScore failed: $($_.Exception.Message)"
    }
}

# ============================================================
# F04 — SESSION MANAGEMENT IN REDIS
# ============================================================

function New-ForgeSession {
    param (
        [string]$RepoName = "",
        [string]$Branch = ""
    )

    $sessionId = [guid]::NewGuid().ToString()

    $state = @{
        sessionId    = $sessionId
        repoName     = $RepoName
        branch       = $Branch
        iteration    = 0
        patchesTried = @()
        agentContext  = @{}
        status       = "active"
        createdAt    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        updatedAt    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }

    if (-not $Global:RedisCacheEnabled) {
        Write-Warning "New-ForgeSession: Redis not available, session stored locally only."
        # Store in local memory as fallback
        $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
        try {
            if (-not (Test-Path $memoryRoot)) {
                New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null
            }
            $filePath = Join-Path $memoryRoot "session-${sessionId}.json"
            $state | ConvertTo-Json -Depth 10 | Out-File $filePath -Encoding utf8
        } catch {
            Write-Warning "Failed to save local session file: $($_.Exception.Message)"
        }
        return $sessionId
    }

    try {
        $redisKey = "forge:session:${sessionId}"
        $json = $state | ConvertTo-Json -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 86400  # 24 hours
    } catch {
        Write-Warning "New-ForgeSession Redis write failed: $($_.Exception.Message)"
    }

    return $sessionId
}

function Save-SessionState {
    param (
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$State
    )

    if (-not $Global:RedisCacheEnabled) {
        Write-Warning "Save-SessionState: Redis not available, saving locally."
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            if (-not (Test-Path $memoryRoot)) {
                New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null
            }
            $filePath = Join-Path $memoryRoot "session-${SessionId}.json"
            $State["updatedAt"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            $State | ConvertTo-Json -Depth 10 | Out-File $filePath -Encoding utf8
        } catch {
            Write-Warning "Failed to save local session state: $($_.Exception.Message)"
        }
        return
    }

    try {
        $redisKey = "forge:session:${SessionId}"

        # Merge with existing state to preserve fields not in the update
        $existing = Get-CacheValue -Key $redisKey
        $merged = @{}
        if ($null -ne $existing -and $existing -ne "") {
            try {
                $parsed = $existing | ConvertFrom-Json
                foreach ($prop in $parsed.PSObject.Properties) {
                    $merged[$prop.Name] = $prop.Value
                }
            } catch {
                # Start fresh if parse fails
            }
        }

        # Apply incoming state on top
        foreach ($key in $State.Keys) {
            $merged[$key] = $State[$key]
        }
        $merged["updatedAt"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")

        $json = $merged | ConvertTo-Json -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 86400
    } catch {
        Write-Warning "Save-SessionState failed for session '${SessionId}': $($_.Exception.Message)"
    }
}

function Get-SessionState {
    param (
        [Parameter(Mandatory)][string]$SessionId
    )

    if (-not $Global:RedisCacheEnabled) {
        # Try local fallback
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            $filePath = Join-Path $memoryRoot "session-${SessionId}.json"
            if (Test-Path $filePath) {
                return (Get-Content $filePath -Raw | ConvertFrom-Json)
            }
        } catch {
            Write-Warning "Failed to read local session state: $($_.Exception.Message)"
        }
        return $null
    }

    try {
        $redisKey = "forge:session:${SessionId}"
        $cached = Get-CacheValue -Key $redisKey
        if ($null -ne $cached -and $cached -ne "") {
            return ($cached | ConvertFrom-Json)
        }
        return $null
    } catch {
        Write-Warning "Get-SessionState failed for session '${SessionId}': $($_.Exception.Message)"
        return $null
    }
}

function Remove-ForgeSession {
    param (
        [Parameter(Mandatory)][string]$SessionId
    )

    if (-not $Global:RedisCacheEnabled) {
        # Clean up local fallback file
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            $filePath = Join-Path $memoryRoot "session-${SessionId}.json"
            if (Test-Path $filePath) {
                Remove-Item $filePath -Force
            }
            # Also clean up conversation history file
            $convPath = Join-Path $memoryRoot "conversation-${SessionId}.json"
            if (Test-Path $convPath) {
                Remove-Item $convPath -Force
            }
        } catch {
            Write-Warning "Failed to remove local session file: $($_.Exception.Message)"
        }
        return
    }

    try {
        # Remove session state
        Remove-CacheValue -Key "forge:session:${SessionId}"
        # Remove conversation history (F06)
        Remove-CacheValue -Key "forge:session:${SessionId}:conversation"
    } catch {
        Write-Warning "Remove-ForgeSession failed for session '${SessionId}': $($_.Exception.Message)"
    }
}

# ============================================================
# F05 — REPO FINGERPRINTING AND SIMILARITY
# ============================================================

function Get-RepoFingerprint {
    param (
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $fingerprint = @{
        frameworks   = @()
        testRunners  = @()
        filePatterns = @()
        nugetPackages = @()
    }

    try {
        # Detect frameworks from .csproj TargetFramework
        $csprojFiles = Get-ChildItem $RepoRoot -Filter "*.csproj" -Recurse -Depth 5 -ErrorAction SilentlyContinue
        foreach ($proj in $csprojFiles) {
            $content = Get-Content $proj.FullName -Raw -ErrorAction SilentlyContinue
            if ($content) {
                # Extract TargetFramework(s)
                $tfMatches = [regex]::Matches($content, '<TargetFramework[s]?>\s*([^<]+)\s*</TargetFramework[s]?>')
                foreach ($m in $tfMatches) {
                    $frameworks = $m.Groups[1].Value -split ";"
                    foreach ($fw in $frameworks) {
                        $fw = $fw.Trim()
                        if ($fw -and $fw -notin $fingerprint.frameworks) {
                            $fingerprint.frameworks += $fw
                        }
                    }
                }

                # Extract NuGet packages (PackageReference)
                $pkgMatches = [regex]::Matches($content, '<PackageReference\s+Include="([^"]+)"')
                foreach ($m in $pkgMatches) {
                    $pkg = $m.Groups[1].Value
                    if ($pkg -notin $fingerprint.nugetPackages) {
                        $fingerprint.nugetPackages += $pkg
                    }
                }
            }
        }

        # Detect test runners
        $testRunnerIndicators = @{
            "xunit"        = @("xunit", "xunit.runner.visualstudio", "Microsoft.NET.Test.Sdk")
            "nunit"        = @("NUnit", "NUnit3TestAdapter")
            "mstest"       = @("MSTest.TestFramework", "MSTest.TestAdapter")
            "pester"       = @()  # detected by .Tests.ps1 files
        }

        foreach ($runner in $testRunnerIndicators.Keys) {
            foreach ($indicator in $testRunnerIndicators[$runner]) {
                if ($fingerprint.nugetPackages -contains $indicator) {
                    if ($runner -notin $fingerprint.testRunners) {
                        $fingerprint.testRunners += $runner
                    }
                    break
                }
            }
        }

        # Check for Pester tests
        $pesterFiles = Get-ChildItem $RepoRoot -Filter "*.Tests.ps1" -Recurse -Depth 3 -ErrorAction SilentlyContinue
        if ($pesterFiles -and $pesterFiles.Count -gt 0) {
            if ("pester" -notin $fingerprint.testRunners) {
                $fingerprint.testRunners += "pester"
            }
        }

        # Detect file patterns (extensions present in repo)
        $extensionCounts = @{}
        $allFiles = Get-ChildItem $RepoRoot -File -Recurse -Depth 5 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|obj|bin|packages)[\\/]' }
        foreach ($f in $allFiles) {
            $ext = $f.Extension.ToLower()
            if ($ext -and $ext.Length -le 10) {
                if ($extensionCounts.ContainsKey($ext)) {
                    $extensionCounts[$ext]++
                } else {
                    $extensionCounts[$ext] = 1
                }
            }
        }
        # Keep file extensions with 2+ occurrences as features
        $fingerprint.filePatterns = @($extensionCounts.Keys | Where-Object { $extensionCounts[$_] -ge 2 } | Sort-Object)

    } catch {
        Write-Warning "Get-RepoFingerprint failed: $($_.Exception.Message)"
    }

    return $fingerprint
}

function Save-RepoFingerprint {
    param (
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][hashtable]$Fingerprint
    )

    if (-not $Global:RedisCacheEnabled) {
        Write-Warning "Save-RepoFingerprint: Redis not available, saving locally."
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            if (-not (Test-Path $memoryRoot)) {
                New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null
            }
            $filePath = Join-Path $memoryRoot "fingerprint-${RepoName}.json"
            $data = @{
                repoName    = $RepoName
                fingerprint = $Fingerprint
                savedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            }
            $data | ConvertTo-Json -Depth 10 | Out-File $filePath -Encoding utf8
        } catch {
            Write-Warning "Failed to save local fingerprint: $($_.Exception.Message)"
        }
        return
    }

    try {
        $redisKey = "forge:repo:${RepoName}:fingerprint"
        $data = @{
            repoName    = $RepoName
            fingerprint = $Fingerprint
            savedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
        $json = $data | ConvertTo-Json -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 604800  # 7 days

        # Also register this repo in the global fingerprint index
        $indexKey = "forge:global:fingerprintIndex"
        $existingIndex = Get-CacheValue -Key $indexKey
        $index = @()
        if ($null -ne $existingIndex -and $existingIndex -ne "") {
            try { $index = @($existingIndex | ConvertFrom-Json) } catch { $index = @() }
        }
        if ($RepoName -notin $index) {
            $index += $RepoName
        }
        $indexJson = ConvertTo-Json -InputObject @($index) -Depth 5
        Set-CacheValue -Key $indexKey -Value $indexJson -TtlSeconds 604800
    } catch {
        Write-Warning "Save-RepoFingerprint failed for '${RepoName}': $($_.Exception.Message)"
    }
}

function Find-SimilarRepos {
    param (
        [Parameter(Mandatory)][hashtable]$Fingerprint,
        [int]$TopK = 3
    )

    if (-not $Global:RedisCacheEnabled) { return @() }

    try {
        # Get the global index of repos with fingerprints
        $indexKey = "forge:global:fingerprintIndex"
        $existingIndex = Get-CacheValue -Key $indexKey
        if ($null -eq $existingIndex -or $existingIndex -eq "") { return @() }

        $repoNames = @($existingIndex | ConvertFrom-Json)
        if ($repoNames.Count -eq 0) { return @() }

        # Build feature set from the input fingerprint
        $inputFeatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($fw in $Fingerprint.frameworks)   { [void]$inputFeatures.Add("fw:$fw") }
        foreach ($tr in $Fingerprint.testRunners)   { [void]$inputFeatures.Add("tr:$tr") }
        foreach ($fp in $Fingerprint.filePatterns)  { [void]$inputFeatures.Add("fp:$fp") }
        foreach ($pkg in $Fingerprint.nugetPackages) { [void]$inputFeatures.Add("pkg:$pkg") }

        if ($inputFeatures.Count -eq 0) { return @() }

        $results = @()

        foreach ($repo in $repoNames) {
            $redisKey = "forge:repo:${repo}:fingerprint"
            $cached = Get-CacheValue -Key $redisKey
            if ($null -eq $cached -or $cached -eq "") { continue }

            try {
                $data = $cached | ConvertFrom-Json
                $fp = $data.fingerprint

                # Build feature set for stored repo
                $storedFeatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                if ($fp.frameworks)    { foreach ($fw in $fp.frameworks)    { [void]$storedFeatures.Add("fw:$fw") } }
                if ($fp.testRunners)   { foreach ($tr in $fp.testRunners)   { [void]$storedFeatures.Add("tr:$tr") } }
                if ($fp.filePatterns)  { foreach ($f in $fp.filePatterns)   { [void]$storedFeatures.Add("fp:$f") } }
                if ($fp.nugetPackages) { foreach ($pkg in $fp.nugetPackages) { [void]$storedFeatures.Add("pkg:$pkg") } }

                if ($storedFeatures.Count -eq 0) { continue }

                # Jaccard similarity: |A intersection B| / |A union B|
                $intersection = [System.Collections.Generic.HashSet[string]]::new($inputFeatures, [StringComparer]::OrdinalIgnoreCase)
                $intersection.IntersectWith($storedFeatures)

                $union = [System.Collections.Generic.HashSet[string]]::new($inputFeatures, [StringComparer]::OrdinalIgnoreCase)
                $union.UnionWith($storedFeatures)

                $similarity = 0.0
                if ($union.Count -gt 0) {
                    $similarity = [Math]::Round($intersection.Count / $union.Count, 4)
                }

                if ($similarity -gt 0) {
                    $results += @{
                        repoName   = $repo
                        similarity = $similarity
                    }
                }
            } catch {
                # Skip repos with unparseable fingerprints
                continue
            }
        }

        # Sort by similarity descending, return top K
        $sorted = $results | Sort-Object -Property @{ Expression = { $_.similarity }; Descending = $true } |
            Select-Object -First $TopK

        return @($sorted)
    } catch {
        Write-Warning "Find-SimilarRepos failed: $($_.Exception.Message)"
        return @()
    }
}

# ============================================================
# F06 — AGENT CONVERSATION MEMORY IN REDIS
# ============================================================

function Save-ConversationTurn {
    param (
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Content
    )

    $turn = @{
        role      = $Role
        content   = $Content
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }

    if (-not $Global:RedisCacheEnabled) {
        # Local file fallback: append to a conversation JSON file
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            if (-not (Test-Path $memoryRoot)) {
                New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null
            }
            $filePath = Join-Path $memoryRoot "conversation-${SessionId}.json"
            $history = @()
            if (Test-Path $filePath) {
                try {
                    $existing = Get-Content $filePath -Raw | ConvertFrom-Json
                    $history = @($existing)
                } catch {
                    $history = @()
                }
            }
            $history += $turn
            ConvertTo-Json -InputObject @($history) -Depth 10 | Out-File $filePath -Encoding utf8
        } catch {
            Write-Warning "Save-ConversationTurn local fallback failed: $($_.Exception.Message)"
        }
        return
    }

    try {
        $redisKey = "forge:session:${SessionId}:conversation"

        # Retrieve existing conversation list and append
        $cached = Get-CacheValue -Key $redisKey
        $history = @()
        if ($null -ne $cached -and $cached -ne "") {
            try { $history = @($cached | ConvertFrom-Json) } catch { $history = @() }
        }

        $history += $turn
        $json = ConvertTo-Json -InputObject @($history) -Depth 10
        Set-CacheValue -Key $redisKey -Value $json -TtlSeconds 86400  # 24 hours
    } catch {
        Write-Warning "Save-ConversationTurn failed for session '${SessionId}': $($_.Exception.Message)"
    }
}

function Get-ConversationHistory {
    param (
        [Parameter(Mandatory)][string]$SessionId,
        [int]$LastN = 10
    )

    if (-not $Global:RedisCacheEnabled) {
        # Local file fallback
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            $filePath = Join-Path $memoryRoot "conversation-${SessionId}.json"
            if (Test-Path $filePath) {
                $history = @(Get-Content $filePath -Raw | ConvertFrom-Json)
                if ($history.Count -gt $LastN) {
                    return @($history | Select-Object -Last $LastN)
                }
                return @($history)
            }
        } catch {
            Write-Warning "Get-ConversationHistory local fallback failed: $($_.Exception.Message)"
        }
        return @()
    }

    try {
        $redisKey = "forge:session:${SessionId}:conversation"
        $cached = Get-CacheValue -Key $redisKey
        if ($null -eq $cached -or $cached -eq "") { return @() }

        $history = @($cached | ConvertFrom-Json)
        if ($history.Count -gt $LastN) {
            return @($history | Select-Object -Last $LastN)
        }
        return @($history)
    } catch {
        Write-Warning "Get-ConversationHistory failed for session '${SessionId}': $($_.Exception.Message)"
        return @()
    }
}

function Clear-ConversationHistory {
    param (
        [Parameter(Mandatory)][string]$SessionId
    )

    if (-not $Global:RedisCacheEnabled) {
        # Local file fallback
        try {
            $memoryRoot = Join-Path $PSScriptRoot ".." "memory"
            $filePath = Join-Path $memoryRoot "conversation-${SessionId}.json"
            if (Test-Path $filePath) {
                Remove-Item $filePath -Force
            }
        } catch {
            Write-Warning "Clear-ConversationHistory local fallback failed: $($_.Exception.Message)"
        }
        return
    }

    try {
        Remove-CacheValue -Key "forge:session:${SessionId}:conversation"
    } catch {
        Write-Warning "Clear-ConversationHistory failed for session '${SessionId}': $($_.Exception.Message)"
    }
}
