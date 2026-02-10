. "$PSScriptRoot/CSharpAnalyser.ps1"

$Global:EmbeddingCache = @{}  # In-memory cache: key -> vector

function Get-Embedding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Model
    )

    # Use config model if not explicitly provided
    if (-not $Model) {
        $Model = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('embeddingModel')) {
            $Global:ForgeConfig.embeddingModel
        } else {
            "text-embedding-3-small"
        }
    }

    # Use separate embedding endpoint/key if configured, else fall back to main Azure OpenAI
    $embeddingEndpoint = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('embeddingEndpoint') -and $Global:ForgeConfig.embeddingEndpoint) {
        $Global:ForgeConfig.embeddingEndpoint
    } else {
        $env:AZURE_OPENAI_ENDPOINT
    }
    $embeddingApiKey = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('embeddingApiKey') -and $Global:ForgeConfig.embeddingApiKey) {
        $Global:ForgeConfig.embeddingApiKey
    } else {
        $env:AZURE_OPENAI_API_KEY
    }

    $uri = "$embeddingEndpoint/openai/deployments/$Model/embeddings?api-version=$($env:AZURE_OPENAI_API_VERSION)"

    $body = @{
        input = $Text
    } | ConvertTo-Json -Depth 4

    # Auth header: JWT tokens (contain dots) use Bearer, API keys use api-key header
    $headers = @{ "Content-Type" = "application/json" }
    if ($embeddingApiKey -match '\.[A-Za-z0-9_-]+\.') {
        $headers["Authorization"] = "Bearer $embeddingApiKey"
    } else {
        $headers["api-key"] = $embeddingApiKey
    }

    $maxRetries = 3
    $response = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                Write-Warning "Embedding API call failed after $maxRetries attempts: $($_.Exception.Message)"
                return $null
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Embedding API attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $response.data -or $response.data.Count -eq 0) {
        Write-Warning "Embedding API returned no data"
        return $null
    }

    [float[]]$response.data[0].embedding
}

function Get-CosineSimilarity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][float[]]$VectorA,
        [Parameter(Mandatory)][float[]]$VectorB
    )

    if ($VectorA.Length -ne $VectorB.Length) {
        Write-Warning "Get-CosineSimilarity: Vector length mismatch ($($VectorA.Length) vs $($VectorB.Length))"
        return 0.0
    }

    $dot = 0.0
    $magA = 0.0
    $magB = 0.0

    for ($i = 0; $i -lt $VectorA.Length; $i++) {
        $dot += $VectorA[$i] * $VectorB[$i]
        $magA += $VectorA[$i] * $VectorA[$i]
        $magB += $VectorB[$i] * $VectorB[$i]
    }

    $magA = [Math]::Sqrt($magA)
    $magB = [Math]::Sqrt($magB)

    if ($magA -eq 0 -or $magB -eq 0) { return 0.0 }

    [float]($dot / ($magA * $magB))
}

function Search-Embeddings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][hashtable[]]$Chunks,
        [int]$TopK = 10
    )

    $queryEmbedding = Get-Embedding -Text $Query
    if (-not $queryEmbedding) {
        Write-Warning "Failed to get embedding for query"
        return @()
    }

    $results = @()
    foreach ($chunk in $Chunks) {
        if (-not $chunk.Embedding) { continue }
        $similarity = Get-CosineSimilarity -VectorA $queryEmbedding -VectorB $chunk.Embedding
        $results += @{
            Chunk      = $chunk
            Similarity = $similarity
            File       = $chunk.File
            StartLine  = $chunk.StartLine
            EndLine    = $chunk.EndLine
            Type       = $chunk.Type
        }
    }

    $results |
        Sort-Object { $_.Similarity } -Descending |
        Select-Object -First $TopK
}

function Split-CSharpFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { return @() }

    $lines = Get-Content $Path
    if (-not $lines -or $lines.Count -eq 0) { return @() }

    $chunks = @()
    $maxChunkChars = 2000

    # Collect using statements
    $usingLines = @()
    $usingStart = -1
    $usingEnd = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*using\s+') {
            if ($usingStart -eq -1) { $usingStart = $i + 1 }
            $usingEnd = $i + 1
            $usingLines += $lines[$i]
        }
    }
    if ($usingLines.Count -gt 0) {
        $chunks += @{
            Id        = "${Path}:using:block"
            Text      = ($usingLines -join "`n")
            File      = $Path
            StartLine = $usingStart
            EndLine   = $usingEnd
            Type      = "using"
        }
    }

    # Parse classes, constructors, methods, properties
    $braceDepth = 0
    $inClass = $false
    $inMethod = $false
    $inConstructor = $false
    $inProperty = $false
    $currentLines = @()
    $currentStart = 0
    $currentName = ""
    $currentType = ""
    $className = ""
    $methodBraceStart = 0
    $propertyLines = @()
    $propertyStart = -1
    $propertyEnd = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1

        # Detect class declaration
        if (-not $inMethod -and -not $inConstructor -and $line -match '^\s*(public|internal|private|protected|abstract|sealed|static|partial)\s+.*\bclass\s+(\w+)') {
            $className = $Matches[2]
            $classLine = $line.Trim()
            # Look ahead for base class / interfaces on same or next lines
            $classText = $classLine
            $classEnd = $lineNum
            if ($line -match '\{') {
                # class declaration and opening brace on same line
            } elseif (($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\s*\{') {
                # opening brace on next line
            }
            $chunks += @{
                Id        = "${Path}:class:${className}"
                Text      = $classText
                File      = $Path
                StartLine = $lineNum
                EndLine   = $classEnd
                Type      = "class"
            }
        }

        # Detect constructor (ClassName followed by opening paren, inside a class)
        if (-not $inMethod -and -not $inConstructor -and $className -and
            $line -match "^\s*(public|internal|private|protected)\s+${className}\s*\(") {
            $inConstructor = $true
            $currentLines = @($line)
            $currentStart = $lineNum
            $currentName = $className
            $currentType = "constructor"
            $methodBraceStart = $braceDepth
        }

        # Detect method (return type + name + parens, not constructor)
        if (-not $inMethod -and -not $inConstructor -and $className -and
            $line -match '^\s*(public|internal|private|protected|static|virtual|override|async|abstract)\s+.*\s+(\w+)\s*\(' -and
            $line -notmatch "^\s*(public|internal|private|protected)\s+${className}\s*\(") {
            $methodName = $Matches[2]
            # Skip if it looks like a class declaration
            if ($line -notmatch '\bclass\s+') {
                $inMethod = $true
                $currentLines = @($line)
                $currentStart = $lineNum
                $currentName = $methodName
                $currentType = "method"
                $methodBraceStart = $braceDepth
            }
        }

        # Detect property (type + name + { get; set; } pattern or similar)
        if (-not $inMethod -and -not $inConstructor -and $className -and
            $line -match '^\s*(public|internal|private|protected)\s+\w+.*\s+\w+\s*\{\s*(get|set)') {
            # Auto-property on single line
            if ($propertyStart -eq -1) { $propertyStart = $lineNum }
            $propertyEnd = $lineNum
            $propertyLines += $line
        }

        # Track brace depth
        $openBraces = ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
        $closeBraces = ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
        $braceDepth += $openBraces - $closeBraces

        # Accumulate method/constructor lines
        if ($inMethod -or $inConstructor) {
            if ($currentLines.Count -eq 0 -or $currentLines[-1] -ne $line) {
                $currentLines += $line
            }

            # Method/constructor ends when brace depth returns to the level before it started
            if ($braceDepth -le $methodBraceStart -and ($openBraces -gt 0 -or $closeBraces -gt 0)) {
                $text = ($currentLines -join "`n")
                # Split large chunks
                if ($text.Length -gt $maxChunkChars) {
                    $splitChunks = Split-LargeChunk -Text $text -Path $Path -Type $currentType -Name $currentName -StartLine $currentStart -MaxChars $maxChunkChars
                    $chunks += $splitChunks
                } else {
                    $chunks += @{
                        Id        = "${Path}:${currentType}:${currentName}"
                        Text      = $text
                        File      = $Path
                        StartLine = $currentStart
                        EndLine   = $lineNum
                        Type      = $currentType
                    }
                }
                $inMethod = $false
                $inConstructor = $false
                $currentLines = @()
            }
        }
    }

    # Flush accumulated properties
    if ($propertyLines.Count -gt 0) {
        $chunks += @{
            Id        = "${Path}:property:block"
            Text      = ($propertyLines -join "`n")
            File      = $Path
            StartLine = $propertyStart
            EndLine   = $propertyEnd
            Type      = "property"
        }
    }

    $chunks
}

function Split-LargeChunk {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$StartLine,
        [int]$MaxChars = 2000
    )

    $textLines = $Text -split "`n"
    $parts = @()
    $current = @()
    $currentLen = 0
    $partIndex = 0
    $partStart = $StartLine

    foreach ($tl in $textLines) {
        if (($currentLen + $tl.Length + 1) -gt $MaxChars -and $current.Count -gt 0) {
            $parts += @{
                Id        = "${Path}:${Type}:${Name}:part${partIndex}"
                Text      = ($current -join "`n")
                File      = $Path
                StartLine = $partStart
                EndLine   = $partStart + $current.Count - 1
                Type      = $Type
            }
            $partStart = $partStart + $current.Count
            $partIndex++
            $current = @()
            $currentLen = 0
        }
        $current += $tl
        $currentLen += $tl.Length + 1
    }

    if ($current.Count -gt 0) {
        $parts += @{
            Id        = "${Path}:${Type}:${Name}:part${partIndex}"
            Text      = ($current -join "`n")
            File      = $Path
            StartLine = $partStart
            EndLine   = $partStart + $current.Count - 1
            Type      = $Type
        }
    }

    $parts
}

function Build-EmbeddingIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$CachePath
    )

    $maxFileSize = 50KB

    # Find all .cs files via git ls-files, excluding bin/, obj/, .git/
    $savedLocation = Get-Location
    try {
        Set-Location $RepoRoot
        $csFiles = git ls-files '*.cs' |
            Where-Object { $_ -notmatch '(^|/)bin/' -and $_ -notmatch '(^|/)obj/' -and $_ -notmatch '(^|/)\.git/' }
    } finally {
        Set-Location $savedLocation
    }

    if (-not $csFiles) { return 0 }

    $totalChunks = 0

    foreach ($file in $csFiles) {
        $fullPath = Join-Path $RepoRoot $file

        # Skip files over 50KB
        $fileInfo = Get-Item $fullPath -ErrorAction SilentlyContinue
        if (-not $fileInfo -or $fileInfo.Length -gt $maxFileSize) { continue }

        $chunks = Split-CSharpFile -Path $fullPath
        foreach ($chunk in $chunks) {
            $embedding = Get-Embedding -Text $chunk.Text
            if ($embedding) {
                $chunk.Embedding = $embedding
                $Global:EmbeddingCache[$chunk.Id] = $chunk
                $totalChunks++
            }
            # Rate limit: 100ms delay between API calls
            Start-Sleep -Milliseconds 100
        }
    }

    # Save cache to disk if CachePath provided
    if ($CachePath) {
        $cacheData = @{}
        foreach ($key in $Global:EmbeddingCache.Keys) {
            $entry = $Global:EmbeddingCache[$key]
            $cacheData[$key] = @{
                Id        = $entry.Id
                Text      = $entry.Text
                File      = $entry.File
                StartLine = $entry.StartLine
                EndLine   = $entry.EndLine
                Type      = $entry.Type
                Embedding = @($entry.Embedding)
            }
        }
        $cacheData | ConvertTo-Json -Depth 10 | Set-Content -Path $CachePath -Encoding utf8
    }

    $totalChunks
}

function Load-EmbeddingIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CachePath
    )

    if (-not (Test-Path $CachePath)) {
        Write-Warning "Embedding cache file not found: $CachePath"
        return 0
    }

    $json = Get-Content $CachePath -Raw | ConvertFrom-Json
    $count = 0

    foreach ($prop in $json.PSObject.Properties) {
        $entry = $prop.Value
        $Global:EmbeddingCache[$prop.Name] = @{
            Id        = $entry.Id
            Text      = $entry.Text
            File      = $entry.File
            StartLine = $entry.StartLine
            EndLine   = $entry.EndLine
            Type      = $entry.Type
            Embedding = [float[]]$entry.Embedding
        }
        $count++
    }

    $count
}

# G03 — Semantic search tool for agents
function Invoke-SemanticSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$TopK = 10
    )

    # Collect all cached chunks that have embeddings
    $chunks = @()
    foreach ($key in $Global:EmbeddingCache.Keys) {
        $entry = $Global:EmbeddingCache[$key]
        if ($entry.Embedding) {
            $chunks += $entry
        }
    }

    if ($chunks.Count -eq 0) {
        Write-Warning "Invoke-SemanticSearch: No embedded chunks available in cache"
        return @()
    }

    $results = Search-Embeddings -Query $Query -Chunks $chunks -TopK $TopK

    # Format results as structured objects for agent context injection
    $formatted = @()
    foreach ($r in $results) {
        $snippet = ""
        if ($r.Chunk -and $r.Chunk.Text) {
            # Truncate snippet to first 300 chars for readability
            $text = $r.Chunk.Text
            if ($text.Length -gt 300) {
                $snippet = $text.Substring(0, 300) + "..."
            } else {
                $snippet = $text
            }
        }

        $formatted += [PSCustomObject]@{
            File       = $r.File
            StartLine  = $r.StartLine
            EndLine    = $r.EndLine
            Type       = $r.Type
            Similarity = [Math]::Round($r.Similarity, 4)
            Snippet    = $snippet
        }
    }

    $formatted
}

# G05 — Context-aware RAG for agent prompts
function Get-RAGContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailureMessage,
        [string]$StackTrace = "",
        [string]$RepoRoot = "."
    )

    # Combine failure message and stack trace for a richer query
    $query = $FailureMessage
    if ($StackTrace) {
        $query = "$FailureMessage`n$StackTrace"
    }

    # Collect all cached chunks
    $chunks = @()
    foreach ($key in $Global:EmbeddingCache.Keys) {
        $entry = $Global:EmbeddingCache[$key]
        if ($entry.Embedding) {
            $chunks += $entry
        }
    }

    if ($chunks.Count -eq 0) {
        Write-Warning "Get-RAGContext: No embedded chunks available in cache"
        return "RELEVANT_CODE:`n(no embedded code chunks available)`n"
    }

    # Retrieve top-10 most relevant code chunks
    $results = Search-Embeddings -Query $query -Chunks $chunks -TopK 10

    $contextBlock = "RELEVANT_CODE:`n"

    # Track which classes we have already retrieved interface/test info for
    $processedClasses = @{}

    foreach ($r in $results) {
        $file = $r.File
        $startLine = $r.StartLine
        $endLine = $r.EndLine
        $chunkType = $r.Type
        $similarity = [Math]::Round($r.Similarity, 4)

        $snippet = ""
        if ($r.Chunk -and $r.Chunk.Text) {
            $text = $r.Chunk.Text
            if ($text.Length -gt 500) {
                $snippet = $text.Substring(0, 500) + "..."
            } else {
                $snippet = $text
            }
        }

        $contextBlock += "--- $file (L${startLine}-L${endLine}, ${chunkType}, score: ${similarity}) ---`n"
        $contextBlock += "${snippet}`n`n"

        # For class chunks, also retrieve the interface definition and test file
        if ($chunkType -eq "class" -or $chunkType -eq "method" -or $chunkType -eq "constructor") {
            # Extract class name from the chunk ID or file path
            $className = ""
            if ($r.Chunk -and $r.Chunk.Id) {
                # ID format: path:type:ClassName or path:type:MethodName
                $idParts = $r.Chunk.Id -split ':'
                if ($idParts.Count -ge 3) {
                    $className = $idParts[2]
                }
            }

            if ($className -and -not $processedClasses.ContainsKey($className)) {
                $processedClasses[$className] = $true

                # Try to find interface definition (I + ClassName convention)
                $interfaceName = "I$className"
                try {
                    $interfaceInfo = Get-CSharpInterface -InterfaceName $interfaceName -RepoRoot $RepoRoot
                    if ($interfaceInfo) {
                        $contextBlock += "  [Interface: $interfaceName from $($interfaceInfo.Path)]`n"
                        foreach ($m in $interfaceInfo.Methods) {
                            $paramList = ($m.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ', '
                            $contextBlock += "    $($m.ReturnType) $($m.Name)($paramList)`n"
                        }
                        $contextBlock += "`n"
                    }
                } catch {
                    Write-Warning "Get-RAGContext: Failed to retrieve interface for ${interfaceName}: $($_.Exception.Message)"
                }

                # Try to find existing test file for this class
                try {
                    $testFileName = "${className}Tests.cs"
                    $testFiles = @()
                    if (Test-Path $RepoRoot) {
                        $testFiles = @(Get-ChildItem $RepoRoot -Filter $testFileName -Recurse -Depth 10 -ErrorAction SilentlyContinue |
                            Where-Object { $_.FullName -notmatch '[\\/](obj|bin|\.git)[\\/]' } |
                            Select-Object -First 1)
                    }
                    if ($testFiles.Count -gt 0) {
                        $testPath = $testFiles[0].FullName
                        $relativePath = $testPath
                        if ($testPath.StartsWith($RepoRoot)) {
                            $relativePath = $testPath.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                        }
                        $contextBlock += "  [Existing test: $relativePath]`n"
                        # Include first 50 lines of the test file as context
                        $testContent = Get-Content $testPath -TotalCount 50 -ErrorAction SilentlyContinue
                        if ($testContent) {
                            $contextBlock += "  " + (($testContent | Select-Object -First 50) -join "`n  ") + "`n`n"
                        }
                    }
                } catch {
                    Write-Warning "Get-RAGContext: Failed to find test file for ${className}: $($_.Exception.Message)"
                }
            }
        }
    }

    $contextBlock
}

# G06 — Incremental embedding updates
function Update-EmbeddingIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CachePath
    )

    $maxFileSize = 50KB

    # Load existing cache if present
    $cacheData = @{}
    if (Test-Path $CachePath) {
        try {
            $json = Get-Content $CachePath -Raw | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                $entry = $prop.Value
                $cacheData[$prop.Name] = @{
                    Id         = $entry.Id
                    Text       = $entry.Text
                    File       = $entry.File
                    StartLine  = $entry.StartLine
                    EndLine    = $entry.EndLine
                    Type       = $entry.Type
                    Embedding  = if ($entry.Embedding) { [float[]]$entry.Embedding } else { $null }
                    CommitSHA  = if ($entry.PSObject.Properties['CommitSHA']) { $entry.CommitSHA } else { "" }
                }
                # Also populate global cache
                $Global:EmbeddingCache[$prop.Name] = $cacheData[$prop.Name]
            }
        } catch {
            Write-Warning "Update-EmbeddingIndex: Failed to load existing cache: $($_.Exception.Message)"
        }
    }

    # Get changed .cs files from git diff HEAD~1
    $changedFiles = @()
    $savedLocation = Get-Location
    try {
        Set-Location $RepoRoot
        $diffOutput = git diff --name-only HEAD~1 2>$null
        if ($diffOutput) {
            $changedFiles = @($diffOutput | Where-Object { $_ -match '\.cs$' -and $_ -notmatch '(^|/)bin/' -and $_ -notmatch '(^|/)obj/' })
        }
    } catch {
        Write-Warning "Update-EmbeddingIndex: Failed to get git diff: $($_.Exception.Message)"
    } finally {
        Set-Location $savedLocation
    }

    if ($changedFiles.Count -eq 0) {
        Write-Warning "Update-EmbeddingIndex: No changed .cs files found"
        return 0
    }

    # Get current HEAD commit SHA
    $currentSHA = ""
    $savedLocation2 = Get-Location
    try {
        Set-Location $RepoRoot
        $currentSHA = (git rev-parse HEAD 2>$null)
        if ($currentSHA) { $currentSHA = $currentSHA.Trim() }
    } catch {
        Write-Warning "Update-EmbeddingIndex: Failed to get HEAD SHA: $($_.Exception.Message)"
    } finally {
        Set-Location $savedLocation2
    }

    $totalChunks = 0

    foreach ($file in $changedFiles) {
        $fullPath = Join-Path $RepoRoot $file

        # Skip files over 50KB or that don't exist
        $fileInfo = Get-Item $fullPath -ErrorAction SilentlyContinue
        if (-not $fileInfo -or $fileInfo.Length -gt $maxFileSize) { continue }

        # Check if file was already embedded at this commit
        $existingKeys = @($cacheData.Keys | Where-Object { $_ -like "${fullPath}:*" })
        $alreadyEmbedded = $false
        if ($existingKeys.Count -gt 0 -and $currentSHA) {
            $firstEntry = $cacheData[$existingKeys[0]]
            if ($firstEntry.CommitSHA -eq $currentSHA) {
                $alreadyEmbedded = $true
            }
        }

        if ($alreadyEmbedded) { continue }

        # Remove old chunks for this file from cache
        foreach ($oldKey in $existingKeys) {
            $cacheData.Remove($oldKey)
            $Global:EmbeddingCache.Remove($oldKey)
        }

        # Re-embed the file
        $chunks = Split-CSharpFile -Path $fullPath
        foreach ($chunk in $chunks) {
            $embedding = Get-Embedding -Text $chunk.Text
            if ($embedding) {
                $chunk.Embedding = $embedding
                $chunk.CommitSHA = $currentSHA
                $Global:EmbeddingCache[$chunk.Id] = $chunk
                $cacheData[$chunk.Id] = @{
                    Id        = $chunk.Id
                    Text      = $chunk.Text
                    File      = $chunk.File
                    StartLine = $chunk.StartLine
                    EndLine   = $chunk.EndLine
                    Type      = $chunk.Type
                    Embedding = @($chunk.Embedding)
                    CommitSHA = $currentSHA
                }
                $totalChunks++
            }
            # Rate limit: 100ms delay between API calls
            Start-Sleep -Milliseconds 100
        }
    }

    # Save updated cache to disk
    try {
        $cacheData | ConvertTo-Json -Depth 10 | Set-Content -Path $CachePath -Encoding utf8
    } catch {
        Write-Warning "Update-EmbeddingIndex: Failed to save cache: $($_.Exception.Message)"
    }

    $totalChunks
}

# G07 — Test-to-implementation semantic mapping
function Build-TestMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$OutputPath
    )

    if (-not (Test-Path $RepoRoot)) {
        Write-Warning "Build-TestMapping: RepoRoot not found: $RepoRoot"
        return @{}
    }

    # Find all .cs files
    $csFiles = @()
    $savedLocation = Get-Location
    try {
        Set-Location $RepoRoot
        $gitFiles = git ls-files '*.cs' 2>$null
        if ($gitFiles) {
            $csFiles = @($gitFiles |
                Where-Object { $_ -notmatch '(^|/)bin/' -and $_ -notmatch '(^|/)obj/' -and $_ -notmatch '(^|/)\.git/' })
        }
    } catch {
        Write-Warning "Build-TestMapping: Failed to list git files: $($_.Exception.Message)"
    } finally {
        Set-Location $savedLocation
    }

    if ($csFiles.Count -eq 0) {
        Write-Warning "Build-TestMapping: No .cs files found"
        return @{}
    }

    # Classify files as test or implementation
    $testFiles = @()
    $implFiles = @()
    foreach ($file in $csFiles) {
        if ($file -match '(Test|Tests|_test|_tests|\.Tests\.|\.Test\.)' -or $file -match '[\\/]Tests?[\\/]') {
            $testFiles += $file
        } else {
            $implFiles += $file
        }
    }

    $mappings = @{}

    # Phase 1: Naming convention matching (TestClass -> Class)
    foreach ($testFile in $testFiles) {
        $testBaseName = [IO.Path]::GetFileNameWithoutExtension($testFile)
        # Strip common test suffixes
        $implName = $testBaseName -replace '(Tests|Test|_tests|_test)$', ''

        foreach ($implFile in $implFiles) {
            $implBaseName = [IO.Path]::GetFileNameWithoutExtension($implFile)
            if ($implBaseName -eq $implName) {
                if (-not $mappings.ContainsKey($testFile)) {
                    $mappings[$testFile] = @()
                }
                $mappings[$testFile] += $implFile
            }
        }
    }

    # Phase 2: DI-based mapping — parse test files for mocked interfaces, map to implementations
    foreach ($testFile in $testFiles) {
        $fullTestPath = Join-Path $RepoRoot $testFile
        if (-not (Test-Path $fullTestPath)) { continue }

        $testContent = Get-Content $fullTestPath -Raw -ErrorAction SilentlyContinue
        if (-not $testContent) { continue }

        # Find Mock<IFoo> or Substitute.For<IFoo> or A.Fake<IFoo> patterns
        $mockPatterns = @(
            'Mock<(I\w+)>',
            'Substitute\.For<(I\w+)>',
            'A\.Fake<(I\w+)>'
        )

        $mockedInterfaces = @()
        foreach ($pattern in $mockPatterns) {
            $matches2 = [regex]::Matches($testContent, $pattern)
            foreach ($m in $matches2) {
                $interfaceName = $m.Groups[1].Value
                if ($mockedInterfaces -notcontains $interfaceName) {
                    $mockedInterfaces += $interfaceName
                }
            }
        }

        # For each mocked interface, find the implementation file
        foreach ($iface in $mockedInterfaces) {
            # Convention: IFooRepository -> FooRepository.cs
            $implClassName = $iface.Substring(1)  # Remove leading 'I'
            foreach ($implFile in $implFiles) {
                $implBaseName = [IO.Path]::GetFileNameWithoutExtension($implFile)
                if ($implBaseName -eq $implClassName) {
                    if (-not $mappings.ContainsKey($testFile)) {
                        $mappings[$testFile] = @()
                    }
                    if ($mappings[$testFile] -notcontains $implFile) {
                        $mappings[$testFile] += $implFile
                    }
                }
            }
        }
    }

    # Phase 3: Semantic similarity (embed both test and impl classes, build similarity matrix)
    $testChunks = @()
    $implChunks = @()

    foreach ($testFile in $testFiles) {
        $fullPath = Join-Path $RepoRoot $testFile
        $fileInfo = Get-Item $fullPath -ErrorAction SilentlyContinue
        if (-not $fileInfo -or $fileInfo.Length -gt 50KB) { continue }

        # Check if already in cache
        $cacheKey = "${fullPath}:class:*"
        $cached = $Global:EmbeddingCache.Keys | Where-Object { $_ -like $cacheKey }
        if ($cached) {
            foreach ($k in $cached) {
                $testChunks += @{ Key = $k; File = $testFile; Chunk = $Global:EmbeddingCache[$k] }
            }
        } else {
            $chunks = Split-CSharpFile -Path $fullPath
            foreach ($c in ($chunks | Where-Object { $_.Type -eq 'class' })) {
                $embedding = Get-Embedding -Text $c.Text
                if ($embedding) {
                    $c.Embedding = $embedding
                    $Global:EmbeddingCache[$c.Id] = $c
                    $testChunks += @{ Key = $c.Id; File = $testFile; Chunk = $c }
                }
                Start-Sleep -Milliseconds 100
            }
        }
    }

    foreach ($implFile in $implFiles) {
        $fullPath = Join-Path $RepoRoot $implFile
        $fileInfo = Get-Item $fullPath -ErrorAction SilentlyContinue
        if (-not $fileInfo -or $fileInfo.Length -gt 50KB) { continue }

        $cacheKey = "${fullPath}:class:*"
        $cached = $Global:EmbeddingCache.Keys | Where-Object { $_ -like $cacheKey }
        if ($cached) {
            foreach ($k in $cached) {
                $implChunks += @{ Key = $k; File = $implFile; Chunk = $Global:EmbeddingCache[$k] }
            }
        } else {
            $chunks = Split-CSharpFile -Path $fullPath
            foreach ($c in ($chunks | Where-Object { $_.Type -eq 'class' })) {
                $embedding = Get-Embedding -Text $c.Text
                if ($embedding) {
                    $c.Embedding = $embedding
                    $Global:EmbeddingCache[$c.Id] = $c
                    $implChunks += @{ Key = $c.Id; File = $implFile; Chunk = $c }
                }
                Start-Sleep -Milliseconds 100
            }
        }
    }

    # Build similarity matrix and add semantic matches above threshold
    $similarityThreshold = 0.7
    foreach ($tc in $testChunks) {
        if (-not $tc.Chunk.Embedding) { continue }
        foreach ($ic in $implChunks) {
            if (-not $ic.Chunk.Embedding) { continue }
            $sim = Get-CosineSimilarity -VectorA $tc.Chunk.Embedding -VectorB $ic.Chunk.Embedding
            if ($sim -ge $similarityThreshold) {
                if (-not $mappings.ContainsKey($tc.File)) {
                    $mappings[$tc.File] = @()
                }
                if ($mappings[$tc.File] -notcontains $ic.File) {
                    $mappings[$tc.File] += $ic.File
                }
            }
        }
    }

    # Save to code-intel.json if OutputPath provided
    if ($OutputPath) {
        try {
            $output = @{}
            foreach ($key in $mappings.Keys) {
                $output[$key] = @($mappings[$key])
            }
            $output | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding utf8
        } catch {
            Write-Warning "Build-TestMapping: Failed to save output: $($_.Exception.Message)"
        }
    }

    $mappings
}

# G08 — Solution-aware indexing
function Get-SolutionGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionPath
    )

    $result = @{
        Projects      = @()
        TestProjects  = @()
        IndexProjects = @()
    }

    if (-not (Test-Path $SolutionPath)) {
        Write-Warning "Get-SolutionGraph: Solution file not found: $SolutionPath"
        return $result
    }

    $slnDir = Split-Path $SolutionPath -Parent
    $slnContent = Get-Content $SolutionPath -Raw -ErrorAction SilentlyContinue
    if (-not $slnContent) {
        Write-Warning "Get-SolutionGraph: Failed to read solution file"
        return $result
    }

    # Parse .sln for project references
    # Pattern: Project("{GUID}") = "Name", "Path.csproj", "{GUID}"
    $projPattern = 'Project\("\{[^}]+\}"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+\.csproj)"\s*,'
    $projMatches = [regex]::Matches($slnContent, $projPattern)

    $allProjects = @()
    foreach ($pm in $projMatches) {
        $projName = $pm.Groups[1].Value
        $projRelPath = $pm.Groups[2].Value
        # Normalize path separators for cross-platform
        $projRelPath = $projRelPath -replace '\\', [IO.Path]::DirectorySeparatorChar
        $projFullPath = Join-Path $slnDir $projRelPath

        if (-not (Test-Path $projFullPath)) { continue }

        $projDir = Split-Path $projFullPath -Parent
        $projContent = Get-Content $projFullPath -Raw -ErrorAction SilentlyContinue
        if (-not $projContent) { continue }

        # Parse ProjectReferences
        $projRefs = @()
        $refPattern = '<ProjectReference\s+Include="([^"]+)"'
        $refMatches = [regex]::Matches($projContent, $refPattern)
        foreach ($rm in $refMatches) {
            $refPath = $rm.Groups[1].Value -replace '\\', [IO.Path]::DirectorySeparatorChar
            # Resolve relative path from the project directory
            $refFullPath = [IO.Path]::GetFullPath((Join-Path $projDir $refPath))
            $projRefs += $refFullPath
        }

        # Parse NuGet packages
        $packages = @()
        $pkgPattern = '<PackageReference\s+Include="([^"]+)"'
        $pkgMatches = [regex]::Matches($projContent, $pkgPattern)
        foreach ($pkm in $pkgMatches) {
            $packages += $pkm.Groups[1].Value
        }

        # Determine if test project (contains test framework NuGet packages)
        $testFrameworkPackages = @('xunit', 'xunit.core', 'nunit', 'nunit3testadapter', 'mstest.testframework', 'microsoft.net.test.sdk')
        $isTestProject = $false
        foreach ($pkg in $packages) {
            if ($testFrameworkPackages -contains $pkg.ToLower()) {
                $isTestProject = $true
                break
            }
        }

        $projectInfo = @{
            Name              = $projName
            Path              = $projFullPath
            RelativePath      = $projRelPath
            Directory         = $projDir
            ProjectReferences = $projRefs
            NuGetPackages     = $packages
            IsTestProject     = $isTestProject
        }

        $allProjects += $projectInfo

        if ($isTestProject) {
            $result.TestProjects += $projectInfo
        }
    }

    $result.Projects = $allProjects

    # Determine which projects to index: projects referenced by test projects
    $projectsToIndex = @{}

    foreach ($testProj in $result.TestProjects) {
        # The test project itself should be indexed
        $projectsToIndex[$testProj.Path] = $testProj

        # All projects referenced by this test project should be indexed
        foreach ($refPath in $testProj.ProjectReferences) {
            # Find the project info for this reference
            foreach ($proj in $allProjects) {
                if ($proj.Path -eq $refPath) {
                    $projectsToIndex[$proj.Path] = $proj
                    break
                }
            }
        }
    }

    $result.IndexProjects = @($projectsToIndex.Values)

    # Collect .cs files from indexable projects, skipping obj/, bin/, generated code
    $indexFiles = @()
    foreach ($proj in $result.IndexProjects) {
        $projDir = $proj.Directory
        if (-not (Test-Path $projDir)) { continue }

        $csFiles = Get-ChildItem $projDir -Filter '*.cs' -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch '[\\/](obj|bin)[\\/]' -and
                $_.FullName -notmatch '\.g\.cs$' -and
                $_.FullName -notmatch '\.g\.i\.cs$' -and
                $_.FullName -notmatch '\.Designer\.cs$' -and
                $_.FullName -notmatch '\.AssemblyInfo\.cs$' -and
                $_.FullName -notmatch '\.AssemblyAttributes\.cs$' -and
                $_.FullName -notmatch 'GlobalUsings\.g\.cs$'
            }

        foreach ($f in $csFiles) {
            $indexFiles += $f.FullName
        }
    }

    $result.IndexFiles = $indexFiles

    $result
}
