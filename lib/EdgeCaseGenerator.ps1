# EdgeCaseGenerator.ps1 — Edge case generation from method signatures (I09)
# Analyzes method signatures to auto-generate edge case hypotheses:
# null params, empty strings, whitespace, max length, boundary values,
# empty collections, etc.

# Dot-source CSharpAnalyser for Get-CSharpSymbols
. "$PSScriptRoot/CSharpAnalyser.ps1"

function Get-EdgeCases {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MethodSignature
    )

    $edgeCases = @()

    # Parse the method signature to extract return type and parameters
    # Expected format: "Task<User> CreateAsync(string email, string name)"
    $sigPattern = '(?:(?:async\s+)?)([\w<>\[\],\?\s]+)\s+(\w+)\s*\(([^)]*)\)'
    if ($MethodSignature -notmatch $sigPattern) {
        Write-Warning "Get-EdgeCases: Could not parse method signature: '$MethodSignature'"
        return $edgeCases
    }

    $returnType = $matches[1].Trim()
    $methodName = $matches[2]
    $paramString = $matches[3].Trim()

    # Parse parameters
    $parameters = @()
    if ($paramString) {
        $parts = $paramString -split ','
        foreach ($p in $parts) {
            $tokens = $p.Trim() -split '\s+'
            if ($tokens.Count -ge 2) {
                $paramType = ($tokens[0..($tokens.Count - 2)] -join ' ')
                $paramName = $tokens[-1]
                $parameters += @{ Type = $paramType; Name = $paramName }
            }
        }
    }

    # Generate edge cases for each parameter based on its type
    foreach ($param in $parameters) {
        $type = $param.Type
        $name = $param.Name

        $cases = Get-TypeEdgeCases -TypeName $type -ParamName $name -MethodName $methodName
        $edgeCases += $cases
    }

    # Generate return-type-specific edge cases
    if ($returnType -match 'Task<(.+)>') {
        $innerType = $matches[1]
        if ($innerType -match 'IEnumerable|IList|List|ICollection|Array') {
            $edgeCases += @{
                Category    = "return-value"
                Description = "$methodName should handle returning an empty collection gracefully."
                TestName    = "${methodName}_ReturnsEmptyCollection_WhenNoResults"
                Parameter   = "(return)"
            }
        }
    }

    # Generate concurrency edge cases for async methods
    if ($MethodSignature -match '\basync\b' -or $returnType -match '^Task') {
        $edgeCases += @{
            Category    = "concurrency"
            Description = "$methodName should handle concurrent calls without race conditions."
            TestName    = "${methodName}_ConcurrentCalls_DoNotCorruptState"
            Parameter   = "(concurrency)"
        }
        $edgeCases += @{
            Category    = "cancellation"
            Description = "$methodName should respect CancellationToken if accepted."
            TestName    = "${methodName}_CancelledToken_ThrowsOperationCancelled"
            Parameter   = "(cancellation)"
        }
    }

    return $edgeCases
}

function Get-TypeEdgeCases {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][string]$ParamName,
        [Parameter(Mandatory)][string]$MethodName
    )

    $cases = @()
    $type = $TypeName.Trim()

    # String parameters
    if ($type -match '^string\??$') {
        $cases += @{
            Category    = "null"
            Description = "Pass null for '$ParamName' — should throw ArgumentNullException or handle gracefully."
            TestName    = "${MethodName}_Null${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "empty"
            Description = "Pass empty string for '$ParamName' — should validate or handle empty input."
            TestName    = "${MethodName}_Empty${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "whitespace"
            Description = "Pass whitespace-only string for '$ParamName' — should trim or reject."
            TestName    = "${MethodName}_Whitespace${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass very long string (>10000 chars) for '$ParamName' — test max length handling."
            TestName    = "${MethodName}_VeryLong${ParamName}_HandlesMaxLength"
            Parameter   = $ParamName
        }

        # Email-specific edge cases
        if ($ParamName -match 'email' -or $ParamName -match 'Email') {
            $cases += @{
                Category    = "format"
                Description = "Pass invalid email format for '$ParamName' — should reject malformed email."
                TestName    = "${MethodName}_InvalidEmail_ThrowsValidationError"
                Parameter   = $ParamName
            }
            $cases += @{
                Category    = "duplicate"
                Description = "Pass duplicate email for '$ParamName' — test uniqueness constraint."
                TestName    = "${MethodName}_DuplicateEmail_ThrowsConflictError"
                Parameter   = $ParamName
            }
        }
    }
    # Integer / numeric parameters
    elseif ($type -match '^int\??$' -or $type -match '^Int32\??$') {
        $cases += @{
            Category    = "boundary"
            Description = "Pass 0 for '$ParamName' — test zero boundary value."
            TestName    = "${MethodName}_Zero${ParamName}_HandlesZero"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass -1 for '$ParamName' — test negative value handling."
            TestName    = "${MethodName}_Negative${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass Int32.MaxValue for '$ParamName' — test overflow handling."
            TestName    = "${MethodName}_MaxValue${ParamName}_HandlesMaxInt"
            Parameter   = $ParamName
        }

        # ID-specific edge cases
        if ($ParamName -match 'id' -or $ParamName -match 'Id') {
            $cases += @{
                Category    = "not-found"
                Description = "Pass non-existent ID for '$ParamName' — should return null or throw NotFoundException."
                TestName    = "${MethodName}_NonExistent${ParamName}_ReturnsNullOrThrows"
                Parameter   = $ParamName
            }
        }
    }
    # Long parameters
    elseif ($type -match '^long\??$' -or $type -match '^Int64\??$') {
        $cases += @{
            Category    = "boundary"
            Description = "Pass 0 for '$ParamName' — test zero boundary."
            TestName    = "${MethodName}_Zero${ParamName}_HandlesZero"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass negative value for '$ParamName'."
            TestName    = "${MethodName}_Negative${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
    }
    # Boolean parameters
    elseif ($type -match '^bool\??$') {
        $cases += @{
            Category    = "toggle"
            Description = "Test '$ParamName' with both true and false values."
            TestName    = "${MethodName}_${ParamName}True_And_${ParamName}False"
            Parameter   = $ParamName
        }
    }
    # Guid parameters
    elseif ($type -match '^Guid\??$') {
        $cases += @{
            Category    = "empty"
            Description = "Pass Guid.Empty for '$ParamName' — should reject empty GUID."
            TestName    = "${MethodName}_EmptyGuid${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
    }
    # DateTime parameters
    elseif ($type -match '^DateTime\??$' -or $type -match '^DateTimeOffset\??$') {
        $cases += @{
            Category    = "boundary"
            Description = "Pass DateTime.MinValue for '$ParamName' — test minimum date handling."
            TestName    = "${MethodName}_MinDate${ParamName}_HandlesMinDate"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass future date for '$ParamName' — test future date validation."
            TestName    = "${MethodName}_FutureDate${ParamName}_HandlesOrRejects"
            Parameter   = $ParamName
        }
    }
    # Collection parameters
    elseif ($type -match 'IEnumerable<|IList<|List<|ICollection<|Array|\[\]') {
        $cases += @{
            Category    = "null"
            Description = "Pass null collection for '$ParamName' — should throw ArgumentNullException."
            TestName    = "${MethodName}_Null${ParamName}_ThrowsArgumentNull"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "empty"
            Description = "Pass empty collection for '$ParamName' — should handle empty input."
            TestName    = "${MethodName}_Empty${ParamName}_HandlesEmptyCollection"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass single-element collection for '$ParamName' — test minimum viable input."
            TestName    = "${MethodName}_SingleElement${ParamName}_ProcessesSingleItem"
            Parameter   = $ParamName
        }
        $cases += @{
            Category    = "boundary"
            Description = "Pass very large collection for '$ParamName' — test performance/limits."
            TestName    = "${MethodName}_LargeCollection${ParamName}_HandlesLargeInput"
            Parameter   = $ParamName
        }
    }
    # Nullable reference types (ending with ?)
    elseif ($type -match '\?$') {
        $cases += @{
            Category    = "null"
            Description = "Pass null for nullable '$ParamName' — verify null handling path."
            TestName    = "${MethodName}_Null${ParamName}_HandlesNull"
            Parameter   = $ParamName
        }
    }
    # Generic object / class parameters
    else {
        $cases += @{
            Category    = "null"
            Description = "Pass null for '$ParamName' ($type) — should throw ArgumentNullException or handle gracefully."
            TestName    = "${MethodName}_Null${ParamName}_ThrowsOrHandles"
            Parameter   = $ParamName
        }
    }

    return $cases
}

function Get-EdgeCaseContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MethodName,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "Get-EdgeCaseContext: File '$Path' not found."
        return ""
    }

    # Use Get-CSharpSymbols to find the method
    $symbols = Get-CSharpSymbols -Path $Path
    if (-not $symbols -or -not $symbols.Classes) {
        return ""
    }

    $targetMethod = $null
    foreach ($class in $symbols.Classes) {
        foreach ($method in $class.Methods) {
            if ($method.Name -eq $MethodName) {
                $targetMethod = $method
                break
            }
        }
        if ($targetMethod) { break }
    }

    if (-not $targetMethod) {
        Write-Warning "Get-EdgeCaseContext: Method '$MethodName' not found in '$Path'."
        return ""
    }

    # Reconstruct the method signature string
    $asyncPrefix = if ($targetMethod.Async) { "async " } else { "" }
    $paramParts = @()
    foreach ($p in $targetMethod.Parameters) {
        $paramParts += "$($p.Type) $($p.Name)"
    }
    $paramStr = $paramParts -join ", "
    $signature = "${asyncPrefix}$($targetMethod.ReturnType) $($targetMethod.Name)($paramStr)"

    # Generate edge cases
    $edgeCases = Get-EdgeCases -MethodSignature $signature

    if ($edgeCases.Count -eq 0) {
        return ""
    }

    # Format as context section
    $lines = @()
    $lines += "EDGE_CASES:"
    $lines += "Method: $signature"
    $lines += ""

    $grouped = @{}
    foreach ($ec in $edgeCases) {
        $cat = $ec.Category
        if (-not $grouped.ContainsKey($cat)) {
            $grouped[$cat] = @()
        }
        $grouped[$cat] += $ec
    }

    foreach ($cat in $grouped.Keys) {
        $lines += "  [$cat]"
        foreach ($ec in $grouped[$cat]) {
            $lines += "    - $($ec.Description)"
            $lines += "      Suggested test: $($ec.TestName)"
        }
    }

    $lines += ""

    return ($lines -join "`n")
}
