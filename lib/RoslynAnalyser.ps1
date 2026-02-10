# RoslynAnalyser.ps1 — Enhanced code analysis with Roslyn AST backend (I02)
#
# Architecture: Each public function tries the Roslyn C# tool (tools/RoslynAnalyser/)
# first via Invoke-RoslynTool from CSharpAnalyser.ps1. If the tool isn't built or
# fails, falls back to the regex implementation (*Regex suffix variants below).

# Dot-source CSharpAnalyser for Invoke-RoslynTool and ConvertTo-Hashtable
. "$PSScriptRoot/CSharpAnalyser.ps1"

# ── Public API (Roslyn-first, regex fallback) ──

function Get-MethodAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = Invoke-RoslynTool -Command "methods" -ToolArgs @($Path)
    if ($result) { return $result }
    return Get-MethodAnalysisRegex -Path $Path
}

function Get-ClassComplexity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = Invoke-RoslynTool -Command "complexity" -ToolArgs @($Path)
    if ($result) { return $result }
    return Get-ClassComplexityRegex -Path $Path
}

function Get-ThrowStatements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = Invoke-RoslynTool -Command "throws" -ToolArgs @($Path)
    if ($result) { return $result }
    return Get-ThrowStatementsRegex -Path $Path
}

# ── Regex Fallback Implementations ──

function Get-MethodAnalysisRegex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = @()

    if (-not (Test-Path $Path)) {
        Write-Warning "Get-MethodAnalysis: File '$Path' not found."
        return $result
    }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    $lines = $content -split "\r?\n"

    # Extract method signatures with full detail
    # Pattern captures: attributes on preceding lines, visibility, static, async, return type, name, params
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Check if this line contains a method declaration
        $methodPattern = '^\s*(public|private|protected|internal)\s+(static\s+)?(async\s+)?(virtual\s+)?(override\s+)?([\w<>\[\],\?\s]+)\s+(\w+)\s*\(([^)]*)\)'
        if ($line -notmatch $methodPattern) { continue }

        $visibility = $matches[1]
        $isStatic = [bool]$matches[2]
        $isAsync = [bool]$matches[3]
        $isVirtual = [bool]$matches[4]
        $isOverride = [bool]$matches[5]
        $returnType = $matches[6].Trim()
        $methodName = $matches[7]
        $paramString = $matches[8].Trim()

        # Skip constructors (return type would match class name pattern)
        if ($returnType -match '\bclass\b') { continue }

        # Collect attributes from preceding lines
        $attributes = @()
        $attrIdx = $i - 1
        while ($attrIdx -ge 0 -and $lines[$attrIdx].Trim() -match '^\[') {
            $attrLine = $lines[$attrIdx].Trim()
            $attrMatches = [regex]::Matches($attrLine, '\[(\w+)(?:\([^)]*\))?\]')
            foreach ($am in $attrMatches) {
                $attributes += $am.Groups[1].Value
            }
            $attrIdx--
        }

        # Parse parameters with full type information
        $parameters = @()
        if ($paramString) {
            $parts = $paramString -split ','
            foreach ($p in $parts) {
                $tokens = $p.Trim() -split '\s+'
                if ($tokens.Count -ge 2) {
                    $paramType = ($tokens[0..($tokens.Count - 2)] -join ' ')
                    $paramName = $tokens[-1]
                    $isNullable = $paramType -match '\?$' -or $paramType -match 'Nullable<'
                    $parameters += @{
                        Type     = $paramType
                        Name     = $paramName
                        Nullable = $isNullable
                    }
                }
            }
        }

        # Count throw statements within the method body
        $throwStatements = @()
        $braceDepth = 0
        $inMethod = $false
        $methodBodyStart = $i
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $bodyLine = $lines[$j]
            $openBraces = ([regex]::Matches($bodyLine, '\{')).Count
            $closeBraces = ([regex]::Matches($bodyLine, '\}')).Count

            if ($openBraces -gt 0 -and -not $inMethod) {
                $inMethod = $true
            }
            $braceDepth += $openBraces - $closeBraces

            if ($inMethod) {
                if ($bodyLine -match 'throw\s+new\s+([\w.]+)') {
                    $throwStatements += @{
                        ExceptionType = $matches[1]
                        Line          = $j + 1
                    }
                } elseif ($bodyLine -match 'throw\s+(\w+)') {
                    $throwStatements += @{
                        ExceptionType = $matches[1]
                        Line          = $j + 1
                    }
                }
            }

            if ($inMethod -and $braceDepth -le 0) { break }
        }
        $methodBodyEnd = $j

        # Calculate branching complexity (cyclomatic approximation)
        $complexity = 1  # base complexity
        for ($j = $methodBodyStart; $j -le $methodBodyEnd -and $j -lt $lines.Count; $j++) {
            $bodyLine = $lines[$j]
            $complexity += ([regex]::Matches($bodyLine, '\bif\b')).Count
            $complexity += ([regex]::Matches($bodyLine, '\belse\s+if\b')).Count
            $complexity += ([regex]::Matches($bodyLine, '\bcase\b')).Count
            $complexity += ([regex]::Matches($bodyLine, '\bcatch\b')).Count
            $complexity += ([regex]::Matches($bodyLine, '\?\?')).Count
            $complexity += ([regex]::Matches($bodyLine, '\?\.')).Count
            $complexity += ([regex]::Matches($bodyLine, '\?[^?\.]')).Count  # ternary ?
            $complexity += ([regex]::Matches($bodyLine, '\b&&\b')).Count
            $complexity += ([regex]::Matches($bodyLine, '\b\|\|\b')).Count
        }

        # Detect nullable annotations in return type and parameters
        $hasNullableReturn = $returnType -match '\?$' -or $returnType -match 'Nullable<'

        $result += @{
            Name            = $methodName
            ReturnType      = $returnType
            Visibility      = $visibility
            Static          = $isStatic
            Async           = $isAsync
            Virtual         = $isVirtual
            Override        = $isOverride
            Attributes      = $attributes
            Parameters      = $parameters
            ThrowStatements = $throwStatements
            Complexity      = $complexity
            NullableReturn  = $hasNullableReturn
            Line            = $i + 1
            EndLine         = $methodBodyEnd + 1
        }
    }

    return $result
}

function Get-ClassComplexityRegex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = @()

    if (-not (Test-Path $Path)) {
        Write-Warning "Get-ClassComplexity: File '$Path' not found."
        return $result
    }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    $lines = $content -split "\r?\n"

    # Find all classes in the file
    $classPattern = '(public|internal|private|protected)?\s*(static\s+)?(abstract\s+)?(partial\s+)?class\s+(\w+)\s*(?::\s*(.+?))?(?:\s*where|\s*\{)'
    $classMatches = [regex]::Matches($content, $classPattern)

    foreach ($cm in $classMatches) {
        $className = $cm.Groups[5].Value
        $inheritanceClause = $cm.Groups[6].Value

        # Determine inheritance depth (approximate — count base classes in chain)
        $inheritanceDepth = 0
        if ($inheritanceClause) {
            $inheritParts = $inheritanceClause -split ',' | ForEach-Object { $_.Trim() }
            foreach ($part in $inheritParts) {
                if ($part -notmatch '^I[A-Z]') {
                    $inheritanceDepth++
                }
            }
        }

        # Count dependencies (constructor parameters, typically interfaces)
        $ctorPattern = '(?:public|private|protected|internal)\s+' + [regex]::Escape($className) + '\s*\(([^)]*)\)'
        $ctorMatch = [regex]::Match($content, $ctorPattern)
        $dependencyCount = 0
        if ($ctorMatch.Success -and $ctorMatch.Groups[1].Value.Trim()) {
            $dependencyCount = ($ctorMatch.Groups[1].Value -split ',').Count
        }

        # Get method-level complexities (use regex variant directly to avoid recursion)
        $methods = Get-MethodAnalysisRegex -Path $Path
        $classMethods = @()
        $totalComplexity = 0

        foreach ($m in $methods) {
            $classMethods += @{
                Name       = $m.Name
                Complexity = $m.Complexity
            }
            $totalComplexity += $m.Complexity
        }

        $avgComplexity = 0
        if ($classMethods.Count -gt 0) {
            $avgComplexity = [Math]::Round($totalComplexity / $classMethods.Count, 1)
        }

        $result += @{
            ClassName        = $className
            InheritanceDepth = $inheritanceDepth
            DependencyCount  = $dependencyCount
            MethodCount      = $classMethods.Count
            TotalComplexity  = $totalComplexity
            AvgComplexity    = $avgComplexity
            Methods          = $classMethods
        }
    }

    return $result
}

function Get-ThrowStatementsRegex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = @()

    if (-not (Test-Path $Path)) {
        Write-Warning "Get-ThrowStatements: File '$Path' not found."
        return $result
    }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    $lines = $content -split "\r?\n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Match: throw new ExceptionType(...)
        if ($line -match 'throw\s+new\s+([\w.]+)\s*\(([^)]*)\)') {
            $result += @{
                ExceptionType = $matches[1]
                Message       = $matches[2].Trim().Trim('"')
                Line          = $i + 1
                IsRethrow     = $false
                RawLine       = $line.Trim()
            }
        }
        # Match: throw; (rethrow)
        elseif ($line -match '^\s*throw\s*;') {
            $result += @{
                ExceptionType = "(rethrow)"
                Message       = ""
                Line          = $i + 1
                IsRethrow     = $true
                RawLine       = $line.Trim()
            }
        }
        # Match: throw exceptionVariable;
        elseif ($line -match 'throw\s+(\w+)\s*;') {
            $result += @{
                ExceptionType = $matches[1]
                Message       = ""
                Line          = $i + 1
                IsRethrow     = $false
                RawLine       = $line.Trim()
            }
        }
    }

    return $result
}
