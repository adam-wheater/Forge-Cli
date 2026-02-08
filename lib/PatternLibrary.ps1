# PatternLibrary.ps1 — C# test pattern library (I04)
# Stores and retrieves successful test patterns as JSON files.
# Categories: moq-setup, async-test, exception-test, theory-inlinedata,
# fixture-setup, httpClient-mock, dbContext-mock, mediator-test,
# controller-test, middleware-test.

function Save-TestPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Example,
        [string]$MemoryRoot = ""
    )

    $validCategories = @(
        "moq-setup", "async-test", "exception-test", "theory-inlinedata",
        "fixture-setup", "httpClient-mock", "dbContext-mock", "mediator-test",
        "controller-test", "middleware-test"
    )

    if ($Category -notin $validCategories) {
        Write-Warning "Save-TestPattern: Invalid category '$Category'. Valid categories: $($validCategories -join ', ')."
        return $false
    }

    if (-not $MemoryRoot) {
        $MemoryRoot = Join-Path $PWD ".forge-memory"
    }

    $patternsDir = Join-Path $MemoryRoot "patterns"
    if (-not (Test-Path $patternsDir)) {
        New-Item -ItemType Directory -Path $patternsDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $categoryFile = Join-Path $patternsDir "$Category.json"

    # Load existing patterns for this category
    $patterns = @()
    if (Test-Path $categoryFile) {
        try {
            $raw = Get-Content $categoryFile -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [array]) {
                $patterns = @($parsed)
            } else {
                $patterns = @($parsed)
            }
        } catch {
            Write-Warning "Save-TestPattern: Failed to load existing patterns from '$categoryFile': $_"
            $patterns = @()
        }
    }

    # Check if this pattern already exists (by pattern text match)
    $existing = $null
    for ($i = 0; $i -lt $patterns.Count; $i++) {
        if ($patterns[$i].Pattern -eq $Pattern) {
            $existing = $i
            break
        }
    }

    if ($null -ne $existing) {
        # Increment usage count for existing pattern
        $entry = $patterns[$existing]
        $newCount = 1
        if ($entry.PSObject.Properties['UsageCount']) {
            $newCount = [int]$entry.UsageCount + 1
        }
        # Rebuild as a new PSCustomObject with updated count
        $patterns[$existing] = [PSCustomObject]@{
            Pattern    = $entry.Pattern
            Example    = $entry.Example
            Category   = $Category
            UsageCount = $newCount
            LastUsed   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
    } else {
        # Add new pattern
        $newEntry = [PSCustomObject]@{
            Pattern    = $Pattern
            Example    = $Example
            Category   = $Category
            UsageCount = 1
            LastUsed   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
        $patterns += $newEntry
    }

    try {
        $json = $patterns | ConvertTo-Json -Depth 10
        Set-Content -Path $categoryFile -Value $json -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Save-TestPattern: Failed to save patterns to '$categoryFile': $_"
        return $false
    }
}

function Get-TestPatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [int]$TopK = 3,
        [string]$MemoryRoot = ""
    )

    if (-not $MemoryRoot) {
        $MemoryRoot = Join-Path $PWD ".forge-memory"
    }

    $categoryFile = Join-Path $MemoryRoot "patterns" "$Category.json"

    if (-not (Test-Path $categoryFile)) {
        return @()
    }

    try {
        $raw = Get-Content $categoryFile -Raw -ErrorAction Stop
        $patterns = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Get-TestPatterns: Failed to load patterns from '$categoryFile': $_"
        return @()
    }

    if (-not $patterns) { return @() }

    # Sort by usage count descending, then by LastUsed descending
    $sorted = @($patterns | Sort-Object -Property @{Expression={$_.UsageCount}; Descending=$true}, @{Expression={$_.LastUsed}; Descending=$true})

    $result = @($sorted | Select-Object -First $TopK)

    return $result
}

function Match-TestPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassUnderTest,
        [Parameter(Mandatory)][string]$MethodSignature,
        [string]$MemoryRoot = ""
    )

    if (-not $MemoryRoot) {
        $MemoryRoot = Join-Path $PWD ".forge-memory"
    }

    $matchedCategories = @()

    # Detect relevant categories based on method signature and class name

    # Async methods -> async-test
    if ($MethodSignature -match '\basync\b' -or $MethodSignature -match '\bTask\b' -or $MethodSignature -match '\bTask<') {
        $matchedCategories += "async-test"
    }

    # Methods that throw -> exception-test
    if ($MethodSignature -match '\bthrow\b' -or $MethodSignature -match 'Exception') {
        $matchedCategories += "exception-test"
    }

    # IMediator parameter -> mediator-test
    if ($MethodSignature -match '\bIMediator\b' -or $ClassUnderTest -match 'Handler$' -or $MethodSignature -match '\bIRequest\b') {
        $matchedCategories += "mediator-test"
    }

    # Controller classes -> controller-test
    if ($ClassUnderTest -match 'Controller$' -or $MethodSignature -match '\bIActionResult\b' -or $MethodSignature -match '\bActionResult\b') {
        $matchedCategories += "controller-test"
    }

    # HttpClient usage -> httpClient-mock
    if ($MethodSignature -match '\bHttpClient\b' -or $MethodSignature -match '\bIHttpClientFactory\b') {
        $matchedCategories += "httpClient-mock"
    }

    # DbContext usage -> dbContext-mock
    if ($MethodSignature -match '\bDbContext\b' -or $MethodSignature -match '\bIDbContext\b' -or $ClassUnderTest -match 'Repository$') {
        $matchedCategories += "dbContext-mock"
    }

    # Middleware classes -> middleware-test
    if ($ClassUnderTest -match 'Middleware$' -or $MethodSignature -match '\bRequestDelegate\b' -or $MethodSignature -match '\bHttpContext\b') {
        $matchedCategories += "middleware-test"
    }

    # IClassFixture or shared context -> fixture-setup
    if ($MethodSignature -match '\bIClassFixture\b' -or $ClassUnderTest -match 'Fixture$') {
        $matchedCategories += "fixture-setup"
    }

    # Multiple parameter sets or enum-like -> theory-inlinedata
    if ($MethodSignature -match '\benum\b' -or $MethodSignature -match '\bbool\b' -or ($MethodSignature -split ',' ).Count -ge 3) {
        $matchedCategories += "theory-inlinedata"
    }

    # Default: if nothing specific matched, suggest moq-setup (most common)
    if ($matchedCategories.Count -eq 0) {
        $matchedCategories += "moq-setup"
    }

    # Retrieve patterns for each matched category
    $result = @()
    foreach ($category in $matchedCategories) {
        $patterns = Get-TestPatterns -Category $category -TopK 3 -MemoryRoot $MemoryRoot
        if ($patterns.Count -gt 0) {
            $result += @{
                Category = $category
                Patterns = $patterns
            }
        } else {
            $result += @{
                Category = $category
                Patterns = @()
            }
        }
    }

    return $result
}
