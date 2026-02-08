function Get-CSharpSymbols {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = @{
        Namespace    = ""
        Classes      = @()
    }

    if (-not (Test-Path $Path)) { return $result }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    $lines = $content -split "\r?\n"

    # Extract namespace
    if ($content -match 'namespace\s+([\w.]+)') {
        $result.Namespace = $matches[1]
    }

    # Extract classes
    $classPattern = '(public|internal|private|protected)?\s*(static\s+)?(abstract\s+)?(partial\s+)?class\s+(\w+)\s*(?::\s*(.+?))?(?:\s*where|\s*\{)'
    $classMatches = [regex]::Matches($content, $classPattern)

    foreach ($cm in $classMatches) {
        $className = $cm.Groups[5].Value
        $visibility = if ($cm.Groups[1].Value) { $cm.Groups[1].Value } else { "internal" }
        $isStatic = [bool]$cm.Groups[2].Value
        $isAbstract = [bool]$cm.Groups[3].Value

        # Parse base class and interfaces from inheritance clause
        $baseClass = ""
        $interfaces = @()
        if ($cm.Groups[6].Value) {
            $inheritParts = $cm.Groups[6].Value -split ',' | ForEach-Object { $_.Trim() }
            foreach ($part in $inheritParts) {
                if ($part -match '^I[A-Z]') {
                    $interfaces += $part
                } elseif (-not $baseClass) {
                    $baseClass = $part
                } else {
                    $interfaces += $part
                }
            }
        }

        # Find class line number
        $classLineNum = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "class\s+$className") {
                $classLineNum = $i + 1
                break
            }
        }

        $classInfo = @{
            Name         = $className
            Visibility   = $visibility
            Static       = $isStatic
            Abstract     = $isAbstract
            BaseClass    = $baseClass
            Interfaces   = $interfaces
            Line         = $classLineNum
            Methods      = @()
            Properties   = @()
            Constructors = @()
        }

        # Extract constructors for this class
        $ctorPattern = '(public|private|protected|internal)\s+' + [regex]::Escape($className) + '\s*\(([^)]*)\)\s*(?::|{)'
        $ctorMatches = [regex]::Matches($content, $ctorPattern)
        foreach ($ctm in $ctorMatches) {
            $ctorLineNum = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match ([regex]::Escape($ctm.Value.Substring(0, [Math]::Min(40, $ctm.Value.Length))))) {
                    $ctorLineNum = $i + 1
                    break
                }
            }
            # Fallback: search for constructor signature pattern
            if ($ctorLineNum -eq 0) {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match "$className\s*\(") {
                        $ctorLineNum = $i + 1
                        break
                    }
                }
            }

            $ctorParams = @()
            $paramStr = $ctm.Groups[2].Value.Trim()
            if ($paramStr) {
                $parts = $paramStr -split ','
                foreach ($p in $parts) {
                    $tokens = $p.Trim() -split '\s+'
                    if ($tokens.Count -ge 2) {
                        $ctorParams += @{ Type = $tokens[0..($tokens.Count - 2)] -join ' '; Name = $tokens[-1] }
                    }
                }
            }

            $classInfo.Constructors += @{
                Visibility = $ctm.Groups[1].Value
                Parameters = $ctorParams
                Line       = $ctorLineNum
            }
        }

        # Extract methods (exclude constructors by checking return type differs from class name)
        $methodPattern = '(public|private|protected|internal)\s+(static\s+)?(async\s+)?([\w<>\[\],\s\?]+)\s+(\w+)\s*\(([^)]*)\)'
        $methodMatches = [regex]::Matches($content, $methodPattern)
        foreach ($mm in $methodMatches) {
            $methodName = $mm.Groups[5].Value
            $returnType = $mm.Groups[4].Value.Trim()

            # Skip if this is actually a constructor (return type matches class name)
            if ($methodName -eq $className) { continue }
            # Skip if the return type is a class keyword match
            if ($returnType -match '\bclass\b') { continue }

            $isMethodStatic = [bool]$mm.Groups[2].Value
            $isAsync = [bool]$mm.Groups[3].Value

            $methodLineNum = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "\b$methodName\s*\(") {
                    $methodLineNum = $i + 1
                    break
                }
            }

            $methodParams = @()
            $paramStr = $mm.Groups[6].Value.Trim()
            if ($paramStr) {
                $parts = $paramStr -split ','
                foreach ($p in $parts) {
                    $tokens = $p.Trim() -split '\s+'
                    if ($tokens.Count -ge 2) {
                        $methodParams += @{ Type = $tokens[0..($tokens.Count - 2)] -join ' '; Name = $tokens[-1] }
                    }
                }
            }

            $classInfo.Methods += @{
                Name       = $methodName
                ReturnType = $returnType
                Visibility = $mm.Groups[1].Value
                Static     = $isMethodStatic
                Async      = $isAsync
                Parameters = $methodParams
                Line       = $methodLineNum
            }
        }

        # Extract properties
        $propPattern = '(public|private|protected|internal)\s+(static\s+)?([\w<>\[\],\?\s]+)\s+(\w+)\s*\{'
        $propMatches = [regex]::Matches($content, $propPattern)
        foreach ($pm in $propMatches) {
            $propName = $pm.Groups[4].Value
            $propType = $pm.Groups[3].Value.Trim()

            # Skip if this looks like a class, method, or namespace
            if ($propType -match '\b(class|namespace|void|return)\b') { continue }
            # Skip if name matches a known method name (getters look like props in regex)
            $isMethod = $false
            foreach ($m in $classInfo.Methods) {
                if ($m.Name -eq $propName) { $isMethod = $true; break }
            }
            if ($isMethod) { continue }

            $propLineNum = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "\b$propName\s*\{") {
                    $propLineNum = $i + 1
                    break
                }
            }

            $classInfo.Properties += @{
                Name       = $propName
                Type       = $propType
                Visibility = $pm.Groups[1].Value
                Static     = [bool]$pm.Groups[2].Value
                Line       = $propLineNum
            }
        }

        $result.Classes += $classInfo
    }

    return $result
}

function Get-CSharpInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InterfaceName,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot)) { return $null }

    # Find .cs files using git ls-files or fallback to Get-ChildItem
    $csFiles = @()
    try {
        $csFiles = @(git -C $RepoRoot ls-files '*.cs' 2>$null | ForEach-Object { Join-Path $RepoRoot $_ })
    } catch {
        # Fallback if not a git repo
    }
    if ($csFiles.Count -eq 0) {
        $csFiles = @(Get-ChildItem $RepoRoot -Filter '*.cs' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    foreach ($file in $csFiles) {
        if (-not (Test-Path $file)) { continue }
        $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Check if this file contains the interface definition
        $interfacePattern = '(public|internal)?\s*interface\s+' + [regex]::Escape($InterfaceName) + '(?:\s*<[^>]+>)?\s*(?::\s*[^{]+)?\s*\{'
        if ($content -notmatch $interfacePattern) { continue }

        # Found the interface — extract method signatures
        $methods = @()

        # Get the interface body by finding matching braces
        $startIdx = $content.IndexOf($matches[0])
        $braceStart = $content.IndexOf('{', $startIdx)
        if ($braceStart -lt 0) { continue }

        $depth = 1
        $pos = $braceStart + 1
        while ($pos -lt $content.Length -and $depth -gt 0) {
            if ($content[$pos] -eq '{') { $depth++ }
            elseif ($content[$pos] -eq '}') { $depth-- }
            $pos++
        }

        $body = $content.Substring($braceStart + 1, $pos - $braceStart - 2)

        # Extract method signatures from the interface body
        $methodPattern = '([\w<>\[\],\?\s]+)\s+(\w+)\s*\(([^)]*)\)\s*;'
        $methodMatches = [regex]::Matches($body, $methodPattern)
        foreach ($mm in $methodMatches) {
            $returnType = $mm.Groups[1].Value.Trim()
            $methodName = $mm.Groups[2].Value
            $paramStr = $mm.Groups[3].Value.Trim()

            $methodParams = @()
            if ($paramStr) {
                $parts = $paramStr -split ','
                foreach ($p in $parts) {
                    $tokens = $p.Trim() -split '\s+'
                    if ($tokens.Count -ge 2) {
                        $methodParams += @{ Type = $tokens[0..($tokens.Count - 2)] -join ' '; Name = $tokens[-1] }
                    }
                }
            }

            $methods += @{
                Name       = $methodName
                ReturnType = $returnType
                Parameters = $methodParams
            }
        }

        # Build relative path from repo root
        $relativePath = $file
        if ($file.StartsWith($RepoRoot)) {
            $relativePath = $file.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        }

        return @{
            Name    = $InterfaceName
            Path    = $relativePath
            Methods = $methods
        }
    }

    return $null
}

function Get-NuGetPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath
    )

    $result = @{
        Packages         = @()
        TestFramework    = ""
        MockLibrary      = ""
        AssertionLibrary = "builtin"
        CoverageTools    = @()
    }

    if (-not (Test-Path $ProjectPath)) { return $result }

    $content = Get-Content $ProjectPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    # Extract PackageReference elements
    $pkgPattern = '<PackageReference\s+Include="([^"]+)"\s+Version="([^"]*)"'
    $pkgMatches = [regex]::Matches($content, $pkgPattern)
    foreach ($pm in $pkgMatches) {
        $result.Packages += @{
            Name    = $pm.Groups[1].Value
            Version = $pm.Groups[2].Value
        }
    }

    # Also handle PackageReference with child Version element
    $pkgAltPattern = '<PackageReference\s+Include="([^"]+)"\s*/?>'
    $pkgAltMatches = [regex]::Matches($content, $pkgAltPattern)
    foreach ($pm in $pkgAltMatches) {
        $pkgName = $pm.Groups[1].Value
        # Skip if already captured with inline version
        $alreadyCaptured = $false
        foreach ($existing in $result.Packages) {
            if ($existing.Name -eq $pkgName) { $alreadyCaptured = $true; break }
        }
        if (-not $alreadyCaptured) {
            $result.Packages += @{ Name = $pkgName; Version = "" }
        }
    }

    # Detect test framework
    $packageNames = @($result.Packages | ForEach-Object { $_.Name.ToLower() })
    if ($packageNames -match 'xunit') {
        $result.TestFramework = "xunit"
    } elseif ($packageNames -match 'nunit') {
        $result.TestFramework = "nunit"
    } elseif ($packageNames -match 'mstest\.testframework') {
        $result.TestFramework = "mstest"
    }

    # Detect mock library
    if ($packageNames -match '^moq$') {
        $result.MockLibrary = "moq"
    } elseif ($packageNames -match 'nsubstitute') {
        $result.MockLibrary = "nsubstitute"
    } elseif ($packageNames -match 'fakeiteasy') {
        $result.MockLibrary = "fakeiteasy"
    }

    # Detect assertion library
    if ($packageNames -match 'fluentassertions') {
        $result.AssertionLibrary = "fluentassertions"
    } elseif ($packageNames -match 'shouldly') {
        $result.AssertionLibrary = "shouldly"
    }

    # Detect coverage tools
    if ($packageNames -match 'coverlet\.collector') {
        $result.CoverageTools += "coverlet"
    }

    return $result
}

function Get-DIRegistrations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $result = @{
        Registrations = @()
    }

    if (-not (Test-Path $RepoRoot)) { return $result }

    # Search for Startup.cs or Program.cs
    $targetFiles = @()
    $candidates = @("Startup.cs", "Program.cs")
    foreach ($name in $candidates) {
        $found = Get-ChildItem $RepoRoot -Filter $name -Recurse -Depth 5 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](obj|bin|node_modules|\.git)[\\/]' }
        if ($found) {
            $targetFiles += @($found | ForEach-Object { $_.FullName })
        }
    }

    if ($targetFiles.Count -eq 0) { return $result }

    foreach ($file in $targetFiles) {
        $content = Get-Content $file -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        for ($i = 0; $i -lt $content.Count; $i++) {
            $line = $content[$i]
            $lineNum = $i + 1

            # Match: services.AddScoped<IFoo, Foo>() or builder.Services.AddScoped<IFoo, Foo>()
            $genericPattern = '(?:services|builder\.Services)\.Add(Scoped|Transient|Singleton)<([^,>]+),\s*([^>]+)>\s*\('
            if ($line -match $genericPattern) {
                $result.Registrations += @{
                    Interface      = $matches[2].Trim()
                    Implementation = $matches[3].Trim()
                    Lifetime       = $matches[1]
                    Line           = $lineNum
                }
                continue
            }

            # Match: services.AddScoped(typeof(IGeneric<>), typeof(Generic<>))
            $typeofPattern = '(?:services|builder\.Services)\.Add(Scoped|Transient|Singleton)\s*\(\s*typeof\(([^)]+)\)\s*,\s*typeof\(([^)]+)\)\s*\)'
            if ($line -match $typeofPattern) {
                $result.Registrations += @{
                    Interface      = $matches[2].Trim()
                    Implementation = $matches[3].Trim()
                    Lifetime       = $matches[1]
                    Line           = $lineNum
                }
                continue
            }

            # Match: services.AddDbContext<AppDbContext>()
            $dbContextPattern = '(?:services|builder\.Services)\.AddDbContext<([^>]+)>\s*\('
            if ($line -match $dbContextPattern) {
                $result.Registrations += @{
                    Interface      = $matches[1].Trim()
                    Implementation = $matches[1].Trim()
                    Lifetime       = "Scoped"
                    Line           = $lineNum
                }
                continue
            }

            # Match: services.AddHttpClient<IApiClient, ApiClient>()
            $httpClientPattern = '(?:services|builder\.Services)\.AddHttpClient<([^,>]+),\s*([^>]+)>\s*\('
            if ($line -match $httpClientPattern) {
                $result.Registrations += @{
                    Interface      = $matches[1].Trim()
                    Implementation = $matches[2].Trim()
                    Lifetime       = "Transient"
                    Line           = $lineNum
                }
                continue
            }
        }
    }

    return $result
}
