# TestDataBuilder.ps1 — Test data builder pattern generation (I11)
# Detects entity/model classes and generates fluent builder classes
# for test data setup, reducing boilerplate in test methods.

# Dot-source CSharpAnalyser for Get-CSharpSymbols
. "$PSScriptRoot/CSharpAnalyser.ps1"

function Get-EntityClasses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Get-EntityClasses: RepoRoot '$RepoRoot' does not exist."
        return @()
    }

    # Find all .cs files
    $csFiles = @()
    try {
        $csFiles = @(git -C $RepoRoot ls-files '*.cs' 2>$null | ForEach-Object { Join-Path $RepoRoot $_ })
    } catch {
        # Fallback if not a git repo
    }
    if ($csFiles.Count -eq 0) {
        $csFiles = @(Get-ChildItem $RepoRoot -Filter '*.cs' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](obj|bin|\.git|node_modules)[\\/]' } |
            ForEach-Object { $_.FullName })
    }

    $entities = @()

    foreach ($file in $csFiles) {
        if (-not (Test-Path $file)) { continue }

        # Skip test files
        $fileName = [System.IO.Path]::GetFileName($file)
        if ($fileName -match 'Test' -or $fileName -match 'Builder') { continue }

        # Prefer files in common entity/model directories
        $isEntityDir = $file -match '[\\/](Models|Entities|Domain|Dtos|ViewModels)[\\/]'

        $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Skip controller files
        if ($content -match '\[ApiController\]') { continue }

        # Skip service/repository files (they have complex constructors, not simple entities)
        if ($content -match '\bclass\s+\w+(?:Service|Repository|Handler|Controller|Middleware|Filter)\b') { continue }

        $symbols = Get-CSharpSymbols -Path $file

        foreach ($class in $symbols.Classes) {
            # Entity/model heuristics:
            # - Has properties (at least 2)
            # - Does not have [ApiController]
            # - Not abstract
            # - Not static
            # - Constructors are simple (0 or few parameters, no interface dependencies)

            if ($class.Static) { continue }
            if ($class.Abstract) { continue }
            if ($class.Properties.Count -lt 2) { continue }

            # Check that constructors don't have complex DI dependencies
            $hasComplexCtor = $false
            foreach ($ctor in $class.Constructors) {
                $interfaceParams = @($ctor.Parameters | Where-Object { $_.Type -match '^I[A-Z]' })
                if ($interfaceParams.Count -gt 0) {
                    $hasComplexCtor = $true
                    break
                }
            }
            if ($hasComplexCtor) { continue }

            $relativePath = $file
            if ($file.StartsWith($RepoRoot)) {
                $relativePath = $file.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            }

            $entities += @{
                Name         = $class.Name
                Path         = $file
                RelativePath = $relativePath
                Namespace    = $symbols.Namespace
                Properties   = $class.Properties
                IsEntityDir  = $isEntityDir
            }
        }
    }

    # Sort: entity directories first, then by name
    $sorted = $entities | Sort-Object @{Expression={$_.IsEntityDir}; Descending=$true}, @{Expression={$_.Name}}

    return @($sorted)
}

function Get-TestDataBuilder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntityPath
    )

    if (-not (Test-Path $EntityPath)) {
        Write-Warning "Get-TestDataBuilder: File '$EntityPath' not found."
        return ""
    }

    $symbols = Get-CSharpSymbols -Path $EntityPath
    if (-not $symbols -or -not $symbols.Classes -or $symbols.Classes.Count -eq 0) {
        Write-Warning "Get-TestDataBuilder: No classes found in '$EntityPath'."
        return ""
    }

    $namespace = $symbols.Namespace
    $sb = [System.Text.StringBuilder]::new()

    foreach ($class in $symbols.Classes) {
        # Skip classes with few properties
        if ($class.Properties.Count -lt 2) { continue }
        if ($class.Static) { continue }
        if ($class.Abstract) { continue }

        $className = $class.Name
        $builderName = "${className}Builder"

        [void]$sb.AppendLine("using System;")
        [void]$sb.AppendLine("using System.Collections.Generic;")
        if ($namespace) {
            [void]$sb.AppendLine("using $namespace;")
        }
        [void]$sb.AppendLine("")

        $testNamespace = if ($namespace) { "$namespace.Tests.Builders" } else { "Tests.Builders" }
        [void]$sb.AppendLine("namespace $testNamespace")
        [void]$sb.AppendLine("{")
        [void]$sb.AppendLine("    /// <summary>")
        [void]$sb.AppendLine("    /// Fluent builder for creating $className test instances.")
        [void]$sb.AppendLine("    /// Usage: new ${builderName}().WithEmail(`"test@example.com`").WithName(`"Test`").Build()")
        [void]$sb.AppendLine("    /// </summary>")
        [void]$sb.AppendLine("    public class $builderName")
        [void]$sb.AppendLine("    {")

        # Generate private fields with default values
        foreach ($prop in $class.Properties) {
            if ($prop.Visibility -ne 'public') { continue }
            $fieldName = "_" + ($prop.Name.Substring(0,1).ToLower() + $prop.Name.Substring(1))
            $defaultValue = Get-BuilderDefaultValue -TypeName $prop.Type -PropName $prop.Name
            [void]$sb.AppendLine("        private $($prop.Type) $fieldName = $defaultValue;")
        }

        [void]$sb.AppendLine("")

        # Generate With methods for each property
        foreach ($prop in $class.Properties) {
            if ($prop.Visibility -ne 'public') { continue }
            $fieldName = "_" + ($prop.Name.Substring(0,1).ToLower() + $prop.Name.Substring(1))
            $paramName = $prop.Name.Substring(0,1).ToLower() + $prop.Name.Substring(1)

            [void]$sb.AppendLine("        public $builderName With$($prop.Name)($($prop.Type) $paramName)")
            [void]$sb.AppendLine("        {")
            [void]$sb.AppendLine("            $fieldName = $paramName;")
            [void]$sb.AppendLine("            return this;")
            [void]$sb.AppendLine("        }")
            [void]$sb.AppendLine("")
        }

        # Generate Build method
        [void]$sb.AppendLine("        public $className Build()")
        [void]$sb.AppendLine("        {")
        [void]$sb.AppendLine("            return new $className")
        [void]$sb.AppendLine("            {")

        $publicProps = @($class.Properties | Where-Object { $_.Visibility -eq 'public' })
        for ($i = 0; $i -lt $publicProps.Count; $i++) {
            $prop = $publicProps[$i]
            $fieldName = "_" + ($prop.Name.Substring(0,1).ToLower() + $prop.Name.Substring(1))
            $comma = if ($i -lt $publicProps.Count - 1) { "," } else { "" }
            [void]$sb.AppendLine("                $($prop.Name) = $fieldName$comma")
        }

        [void]$sb.AppendLine("            };")
        [void]$sb.AppendLine("        }")

        [void]$sb.AppendLine("    }")
        [void]$sb.AppendLine("}")
        [void]$sb.AppendLine("")
    }

    return $sb.ToString()
}

function Get-BuilderDefaultValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][string]$PropName
    )

    $type = $TypeName.Trim()
    $name = $PropName.ToLower()

    # Smart defaults based on property name patterns
    if ($name -match 'email') { return '"test@example.com"' }
    if ($name -match 'name' -and $name -notmatch 'username') { return '"Test Name"' }
    if ($name -match 'username') { return '"testuser"' }
    if ($name -match 'phone') { return '"+1234567890"' }
    if ($name -match 'url' -or $name -match 'link') { return '"https://example.com"' }
    if ($name -match 'description') { return '"Test description"' }
    if ($name -match 'title') { return '"Test Title"' }
    if ($name -match 'password') { return '"P@ssw0rd123!"' }
    if ($name -match 'address') { return '"123 Test Street"' }

    # Type-based defaults
    switch -Regex ($type) {
        '^string\??$'               { return '"test-value"' }
        '^int\??$'                  { return '1' }
        '^long\??$'                 { return '1L' }
        '^decimal\??$'              { return '1.0m' }
        '^double\??$'               { return '1.0' }
        '^float\??$'                { return '1.0f' }
        '^bool\??$'                 { return 'false' }
        '^Guid\??$'                 { return 'Guid.NewGuid()' }
        '^DateTime\??$'             { return 'DateTime.UtcNow' }
        '^DateTimeOffset\??$'       { return 'DateTimeOffset.UtcNow' }
        '^TimeSpan\??$'             { return 'TimeSpan.Zero' }
        '^byte\??$'                 { return '0' }
        '^IEnumerable<|^IList<|^List<|^ICollection<' { return "new $($type -replace '^I(Enumerable|List|Collection)', 'List')()" }
        default                      { return "default($type)" }
    }
}

function Get-AllBuilders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$OutputDir = ""
    )

    $entities = Get-EntityClasses -RepoRoot $RepoRoot

    if ($entities.Count -eq 0) {
        Write-Warning "Get-AllBuilders: No entity classes found in '$RepoRoot'."
        return @()
    }

    $builders = @()

    foreach ($entity in $entities) {
        $builderCode = Get-TestDataBuilder -EntityPath $entity.Path

        if (-not $builderCode) { continue }

        $builderInfo = @{
            EntityName   = $entity.Name
            EntityPath   = $entity.Path
            BuilderName  = "$($entity.Name)Builder"
            BuilderCode  = $builderCode
        }

        # Write to output directory if specified
        if ($OutputDir) {
            if (-not (Test-Path $OutputDir)) {
                New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction SilentlyContinue | Out-Null
            }

            $outputFile = Join-Path $OutputDir "$($entity.Name)Builder.cs"
            try {
                Set-Content -Path $outputFile -Value $builderCode -Encoding UTF8 -ErrorAction Stop
                $builderInfo.OutputPath = $outputFile
            } catch {
                Write-Warning "Get-AllBuilders: Failed to write builder to '$outputFile': $_"
            }
        }

        $builders += $builderInfo
    }

    return $builders
}
