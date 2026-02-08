# MockScaffolder.ps1 — Auto mock scaffolding (I06)
# Analyzes constructors via Get-CSharpSymbols, extracts I* interface
# parameters, looks up interface definitions, and generates complete
# mock setup code for test scaffolding.

# Dot-source CSharpAnalyser for Get-CSharpSymbols and Get-CSharpInterface
. "$PSScriptRoot/CSharpAnalyser.ps1"

function Get-MockScaffold {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $ClassPath)) {
        Write-Warning "Get-MockScaffold: File '$ClassPath' not found."
        return ""
    }

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Get-MockScaffold: RepoRoot '$RepoRoot' does not exist."
        return ""
    }

    # Extract class symbols
    $symbols = Get-CSharpSymbols -Path $ClassPath
    if (-not $symbols -or -not $symbols.Classes -or $symbols.Classes.Count -eq 0) {
        Write-Warning "Get-MockScaffold: No classes found in '$ClassPath'."
        return ""
    }

    $scaffoldLines = @()

    foreach ($class in $symbols.Classes) {
        if (-not $class.Constructors -or $class.Constructors.Count -eq 0) { continue }

        # Use the constructor with the most parameters (primary DI constructor)
        $ctor = $class.Constructors | Sort-Object { $_.Parameters.Count } -Descending | Select-Object -First 1
        if (-not $ctor.Parameters -or $ctor.Parameters.Count -eq 0) { continue }

        $scaffoldLines += "// Mock scaffold for $($class.Name)"
        $scaffoldLines += ""

        $mockVarNames = @()
        $ctorArgs = @()

        foreach ($param in $ctor.Parameters) {
            $paramType = $param.Type
            $paramName = $param.Name

            # Check if this is an interface parameter (starts with I followed by uppercase)
            if ($paramType -match '^I[A-Z]') {
                $interfaceName = $paramType
                $varName = "mock" + ($paramName.Substring(0,1).ToUpper() + $paramName.Substring(1))

                # Strip leading underscore if present
                if ($varName -match '^mock_') {
                    $varName = "mock" + ($paramName.TrimStart('_').Substring(0,1).ToUpper() + $paramName.TrimStart('_').Substring(1))
                }

                $scaffoldLines += "var $varName = new Mock<$interfaceName>();"

                # Look up interface definition for Setup generation
                $interfaceDef = Get-CSharpInterface -InterfaceName $interfaceName -RepoRoot $RepoRoot
                if ($interfaceDef -and $interfaceDef.Methods) {
                    foreach ($method in $interfaceDef.Methods) {
                        $setupLine = Get-MockSetupLine -VarName $varName -Method $method
                        if ($setupLine) {
                            $scaffoldLines += $setupLine
                        }
                    }
                }

                $scaffoldLines += ""
                $mockVarNames += $varName
                $ctorArgs += "$varName.Object"
            } else {
                # Non-interface parameter — provide a default or placeholder
                $defaultValue = Get-DefaultValue -TypeName $paramType
                $ctorArgs += $defaultValue
            }
        }

        # Generate SUT (System Under Test) instantiation
        $scaffoldLines += "// Create system under test"
        $argsJoined = $ctorArgs -join ", "
        $scaffoldLines += "var sut = new $($class.Name)($argsJoined);"
    }

    return ($scaffoldLines -join "`n")
}

function Get-MockSetupLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VarName,
        [Parameter(Mandatory)][hashtable]$Method
    )

    $methodName = $Method.Name
    $returnType = $Method.ReturnType
    $params = $Method.Parameters

    # Build parameter matchers
    $paramMatchers = @()
    foreach ($p in $params) {
        $pType = $p.Type
        # Handle generic types for It.IsAny<T>
        if ($pType -match '<') {
            $paramMatchers += "It.IsAny<$pType>()"
        } else {
            $paramMatchers += "It.IsAny<$pType>()"
        }
    }
    $matchersJoined = $paramMatchers -join ", "

    # Determine return value based on return type
    $isAsync = $returnType -match '^Task' -or $returnType -match '^ValueTask'
    $innerType = $returnType

    if ($returnType -match '^Task<(.+)>$') {
        $innerType = $matches[1]
    } elseif ($returnType -match '^ValueTask<(.+)>$') {
        $innerType = $matches[1]
    }

    $returnValue = Get-DefaultValue -TypeName $innerType

    # Build the setup line
    $setup = "$VarName.Setup(x => x.$methodName($matchersJoined))"

    if ($returnType -eq 'Task' -or $returnType -eq 'ValueTask') {
        $setup += ".Returns(Task.CompletedTask);"
    } elseif ($isAsync -and $returnType -match 'Task<') {
        $setup += ".ReturnsAsync($returnValue);"
    } elseif ($isAsync -and $returnType -match 'ValueTask<') {
        $setup += ".Returns(new ValueTask<$innerType>($returnValue));"
    } elseif ($returnType -eq 'void') {
        $setup += ";"
    } else {
        $setup += ".Returns($returnValue);"
    }

    return $setup
}

function Get-DefaultValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName
    )

    $type = $TypeName.Trim()

    # Common C# type defaults
    switch -Regex ($type) {
        '^string\??$'               { return '"test-value"' }
        '^int\??$'                  { return '1' }
        '^long\??$'                 { return '1L' }
        '^decimal\??$'              { return '1.0m' }
        '^double\??$'               { return '1.0' }
        '^float\??$'                { return '1.0f' }
        '^bool\??$'                 { return 'true' }
        '^Guid\??$'                 { return 'Guid.NewGuid()' }
        '^DateTime\??$'             { return 'DateTime.UtcNow' }
        '^DateTimeOffset\??$'       { return 'DateTimeOffset.UtcNow' }
        '^TimeSpan\??$'             { return 'TimeSpan.FromMinutes(1)' }
        '^CancellationToken\??$'    { return 'CancellationToken.None' }
        '^byte\??$'                 { return '0' }
        '^char\??$'                 { return "'a'" }
        '^IEnumerable<'             { return "Enumerable.Empty<$($type -replace 'IEnumerable<(.+)>','$1')>()" }
        '^IList<|^List<'            { return "new List<$($type -replace '(?:IList|List)<(.+)>','$1')>()" }
        '^ICollection<'             { return "new List<$($type -replace 'ICollection<(.+)>','$1')>()" }
        '^IDictionary<|^Dictionary<' { return "new Dictionary<$($type -replace '(?:IDictionary|Dictionary)<(.+)>','$1')>()" }
        '^ILogger<'                 { return "Mock.Of<$type>()" }
        '^IOptions<'                { return "Options.Create(new $($type -replace 'IOptions<(.+)>','$1')())" }
        '^Task$'                    { return 'Task.CompletedTask' }
        '^Task<'                    { return "Task.FromResult(default($($type -replace 'Task<(.+)>','$1')))" }
        '^void$'                    { return '' }
        default                      { return "new $type()" }
    }
}

function Get-MockScaffoldContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TestStyle
    )

    $scaffold = Get-MockScaffold -ClassPath $ClassPath -RepoRoot $RepoRoot
    if (-not $scaffold) {
        return ""
    }

    # Adapt mock syntax based on test style (mock library)
    $adapted = $scaffold
    switch ($TestStyle.ToLower()) {
        "nsubstitute" {
            # Convert Moq syntax to NSubstitute syntax
            $adapted = $adapted -replace 'new Mock<([^>]+)>\(\)', 'Substitute.For<$1>()'
            $adapted = $adapted -replace '\.Setup\(x => x\.(\w+)\(([^)]*)\)\)\.ReturnsAsync\(([^)]+)\)', '.$1($2).Returns($3)'
            $adapted = $adapted -replace '\.Setup\(x => x\.(\w+)\(([^)]*)\)\)\.Returns\(([^)]+)\)', '.$1($2).Returns($3)'
            $adapted = $adapted -replace 'It\.IsAny<([^>]+)>\(\)', 'Arg.Any<$1>()'
            $adapted = $adapted -replace '(\w+)\.Object', '$1'
            $adapted = $adapted -replace 'var (mock\w+) = Substitute', 'var $1 = Substitute'
        }
        "fakeiteasy" {
            # Convert Moq syntax to FakeItEasy syntax
            $adapted = $adapted -replace 'new Mock<([^>]+)>\(\)', 'A.Fake<$1>()'
            $adapted = $adapted -replace '\.Setup\(x => x\.(\w+)\(([^)]*)\)\)\.ReturnsAsync\(([^)]+)\)', ''
            $adapted = $adapted -replace '\.Setup\(x => x\.(\w+)\(([^)]*)\)\)\.Returns\(([^)]+)\)', ''
            $adapted = $adapted -replace 'It\.IsAny<([^>]+)>\(\)', 'A<$1>.Ignored'
            $adapted = $adapted -replace '(\w+)\.Object', '$1'
        }
        # Default: Moq (already generated in Moq syntax)
    }

    $lines = @()
    $lines += "MOCK_SCAFFOLD:"
    $lines += $adapted
    $lines += ""

    return ($lines -join "`n")
}
