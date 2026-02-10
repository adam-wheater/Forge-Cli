# IntegrationTestGen.ps1 — Integration test generation for controllers/endpoints (I10)
# Detects [ApiController] classes, extracts HTTP endpoints, and generates
# WebApplicationFactory-based integration test scaffolds with smart mock setup
# and populated test data.

# Dot-source dependencies
. "$PSScriptRoot/CSharpAnalyser.ps1"
. "$PSScriptRoot/MockScaffolder.ps1"
. "$PSScriptRoot/TestDataBuilder.ps1"

function Get-DtoProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) { return @() }

    # Strip generic wrappers and nullable suffix to get the core type name
    $coreName = $TypeName -replace '\?$', ''
    $coreName = $coreName -replace '^.*<(.+)>$', '$1'
    $coreName = $coreName -replace '\[\]$', ''

    # Fast search: find files likely containing this class via git grep or filename heuristic
    $candidateFiles = @()
    try {
        $gitMatches = @(git -C $RepoRoot grep -l "class\s\+$coreName" -- '*.cs' 2>$null |
            ForEach-Object { Join-Path $RepoRoot $_ })
        $candidateFiles = $gitMatches
    } catch { }

    # Fallback: search by filename matching the type name
    if ($candidateFiles.Count -eq 0) {
        $candidateFiles = @(Get-ChildItem $RepoRoot -Filter "$coreName.cs" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](obj|bin|\.git|node_modules)[\\/]' } |
            ForEach-Object { $_.FullName })
    }

    foreach ($file in $candidateFiles) {
        if (-not (Test-Path $file)) { continue }
        $symbols = Get-CSharpSymbols -Path $file
        if (-not $symbols -or -not $symbols.Classes) { continue }

        foreach ($class in $symbols.Classes) {
            if ($class.Name -eq $coreName) {
                return @($class.Properties | Where-Object { $_.Visibility -eq 'public' })
            }
        }
    }

    return @()
}

function Get-NullMockSetupLine {
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
        $paramMatchers += "It.IsAny<$($p.Type)>()"
    }
    $matchersJoined = $paramMatchers -join ", "

    $isAsync = $returnType -match '^Task' -or $returnType -match '^ValueTask'
    $innerType = $returnType

    if ($returnType -match '^Task<(.+)>$') {
        $innerType = $matches[1]
    } elseif ($returnType -match '^ValueTask<(.+)>$') {
        $innerType = $matches[1]
    }

    $setup = "$VarName.Setup(x => x.$methodName($matchersJoined))"

    # Return null for reference types, empty collections for collection types
    if ($returnType -eq 'Task' -or $returnType -eq 'ValueTask' -or $returnType -eq 'void') {
        return $null  # Not relevant for 404 tests
    }

    if ($innerType -match '^IEnumerable<(.+)>$' -or $innerType -match '^IList<(.+)>$' -or
        $innerType -match '^List<(.+)>$' -or $innerType -match '^ICollection<(.+)>$') {
        $elementType = $matches[1]
        if ($isAsync -and $returnType -match 'Task<') {
            $setup += ".ReturnsAsync(new List<$elementType>());"
        } else {
            $setup += ".Returns(new List<$elementType>());"
        }
    } else {
        # Reference type — return null
        if ($isAsync -and $returnType -match 'Task<') {
            $setup += ".ReturnsAsync(($innerType)null);"
        } elseif ($isAsync -and $returnType -match 'ValueTask<') {
            $setup += ".Returns(new ValueTask<$innerType>(($innerType)null));"
        } else {
            $setup += ".Returns(($innerType)null);"
        }
    }

    return $setup
}

function Get-ApiControllers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Get-ApiControllers: RepoRoot '$RepoRoot' does not exist."
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

    $controllers = @()

    foreach ($file in $csFiles) {
        if (-not (Test-Path $file)) { continue }
        $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Check for [ApiController] attribute
        if ($content -notmatch '\[ApiController\]') { continue }

        $symbols = Get-CSharpSymbols -Path $file

        foreach ($class in $symbols.Classes) {
            # Verify this class has the Controller suffix or inherits ControllerBase
            $isController = $class.Name -match 'Controller$' -or
                            $class.BaseClass -match 'Controller' -or
                            $class.BaseClass -match 'ControllerBase'

            if (-not $isController) { continue }

            # Extract route prefix from [Route] attribute
            $routePrefix = ""
            if ($content -match '\[Route\("([^"]+)"\)\]') {
                $routePrefix = $matches[1]
            }

            # Get endpoint details
            $endpoints = Get-ControllerEndpoints -Path $file

            $relativePath = $file
            if ($file.StartsWith($RepoRoot)) {
                $relativePath = $file.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            }

            $controllers += @{
                Name         = $class.Name
                Path         = $file
                RelativePath = $relativePath
                Namespace    = $symbols.Namespace
                RoutePrefix  = $routePrefix
                BaseClass    = $class.BaseClass
                Interfaces   = $class.Interfaces
                Constructors = $class.Constructors
                Endpoints    = $endpoints
            }
        }
    }

    return $controllers
}

function Get-ControllerEndpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "Get-ControllerEndpoints: File '$Path' not found."
        return @()
    }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return @() }

    $lines = $content -split "\r?\n"
    $endpoints = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Check for HTTP method attributes
        $httpMethod = ""
        $routeTemplate = ""

        if ($line -match '\[HttpGet(?:\("([^"]*)"\))?\]') {
            $httpMethod = "GET"
            $routeTemplate = $matches[1]
        }
        elseif ($line -match '\[HttpPost(?:\("([^"]*)"\))?\]') {
            $httpMethod = "POST"
            $routeTemplate = $matches[1]
        }
        elseif ($line -match '\[HttpPut(?:\("([^"]*)"\))?\]') {
            $httpMethod = "PUT"
            $routeTemplate = $matches[1]
        }
        elseif ($line -match '\[HttpDelete(?:\("([^"]*)"\))?\]') {
            $httpMethod = "DELETE"
            $routeTemplate = $matches[1]
        }
        elseif ($line -match '\[HttpPatch(?:\("([^"]*)"\))?\]') {
            $httpMethod = "PATCH"
            $routeTemplate = $matches[1]
        }
        else {
            continue
        }

        # Collect additional attributes on subsequent lines before the method
        $authorize = $false
        $allowAnonymous = $false
        $producesStatusCodes = @()

        $attrIdx = $i - 1
        while ($attrIdx -ge 0 -and $lines[$attrIdx].Trim() -match '^\[') {
            $attrLine = $lines[$attrIdx].Trim()
            if ($attrLine -match '\[Authorize') { $authorize = $true }
            if ($attrLine -match '\[AllowAnonymous\]') { $allowAnonymous = $true }
            if ($attrLine -match '\[ProducesResponseType\((\d+)\)') {
                $producesStatusCodes += [int]$matches[1]
            }
            if ($attrLine -match '\[ProducesResponseType\(typeof\([^)]+\),\s*(\d+)\)') {
                $producesStatusCodes += [int]$matches[1]
            }
            if ($attrLine -match 'StatusCodes\.Status(\d+)') {
                $producesStatusCodes += [int]$matches[1]
            }
            $attrIdx--
        }

        # Find the method declaration on the next non-attribute line
        $methodIdx = $i + 1
        while ($methodIdx -lt $lines.Count -and $lines[$methodIdx].Trim() -match '^\[') {
            $methodLine = $lines[$methodIdx].Trim()
            if ($methodLine -match '\[Authorize') { $authorize = $true }
            if ($methodLine -match '\[AllowAnonymous\]') { $allowAnonymous = $true }
            if ($methodLine -match '\[ProducesResponseType\((\d+)\)') {
                $producesStatusCodes += [int]$matches[1]
            }
            $methodIdx++
        }

        $methodName = ""
        $returnType = ""
        $methodParams = @()

        if ($methodIdx -lt $lines.Count) {
            $methodLine = $lines[$methodIdx]
            $methodPattern = '(?:public|private|protected|internal)\s+(?:async\s+)?(?:virtual\s+)?(?:override\s+)?([\w<>\[\],\?\s]+)\s+(\w+)\s*\(([^)]*)\)'
            if ($methodLine -match $methodPattern) {
                $returnType = $matches[1].Trim()
                $methodName = $matches[2]
                $paramStr = $matches[3].Trim()

                if ($paramStr) {
                    $parts = $paramStr -split ','
                    foreach ($p in $parts) {
                        $tokens = $p.Trim() -split '\s+'
                        # Handle attributes like [FromBody], [FromRoute], etc.
                        $paramTokens = @($tokens | Where-Object { $_ -notmatch '^\[' -and $_ -notmatch '\]$' })
                        if ($paramTokens.Count -ge 2) {
                            $binding = ""
                            foreach ($t in $tokens) {
                                if ($t -match '\[From(\w+)\]') {
                                    $binding = $matches[1]
                                }
                            }
                            $methodParams += @{
                                Type    = ($paramTokens[0..($paramTokens.Count - 2)] -join ' ')
                                Name    = $paramTokens[-1]
                                Binding = $binding
                            }
                        }
                    }
                }
            }
        }

        $endpoints += @{
            HttpMethod          = $httpMethod
            RouteTemplate       = $routeTemplate
            MethodName          = $methodName
            ReturnType          = $returnType
            Parameters          = $methodParams
            RequiresAuth        = $authorize -and -not $allowAnonymous
            ProducesStatusCodes = $producesStatusCodes
            Line                = $i + 1
        }
    }

    return $endpoints
}

function Get-IntegrationTestScaffold {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControllerPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $ControllerPath)) {
        Write-Warning "Get-IntegrationTestScaffold: File '$ControllerPath' not found."
        return ""
    }

    $symbols = Get-CSharpSymbols -Path $ControllerPath
    if (-not $symbols -or -not $symbols.Classes) {
        Write-Warning "Get-IntegrationTestScaffold: No classes found in '$ControllerPath'."
        return ""
    }

    $endpoints = Get-ControllerEndpoints -Path $ControllerPath

    # Find the controller class
    $controller = $null
    foreach ($class in $symbols.Classes) {
        if ($class.Name -match 'Controller$') {
            $controller = $class
            break
        }
    }
    if (-not $controller) {
        $controller = $symbols.Classes[0]
    }

    $controllerName = $controller.Name
    $testClassName = "${controllerName}IntegrationTests"
    $namespace = $symbols.Namespace

    # Extract route prefix
    $content = Get-Content $ControllerPath -Raw -ErrorAction SilentlyContinue
    $routePrefix = "api"
    if ($content -match '\[Route\("([^"]+)"\)\]') {
        $routePrefix = $matches[1]
        # Replace [controller] placeholder with actual controller name
        $controllerShort = $controllerName -replace 'Controller$', ''
        $routePrefix = $routePrefix -replace '\[controller\]', $controllerShort.ToLower()
    }

    # Identify external dependencies to mock (constructor interfaces)
    $mockDeps = @()
    if ($controller.Constructors -and $controller.Constructors.Count -gt 0) {
        $ctor = $controller.Constructors | Sort-Object { $_.Parameters.Count } -Descending | Select-Object -First 1
        foreach ($p in $ctor.Parameters) {
            if ($p.Type -match '^I[A-Z]') {
                $mockDeps += $p
            }
        }
    }

    # Pre-resolve interface definitions for mock dependencies (used by multiple test methods)
    $interfaceCache = @{}
    foreach ($dep in $mockDeps) {
        $interfaceDef = Get-CSharpInterface -InterfaceName $dep.Type -RepoRoot $RepoRoot
        if ($interfaceDef) {
            $interfaceCache[$dep.Type] = $interfaceDef
        }
    }

    # Build the test scaffold
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("using System.Net;")
    [void]$sb.AppendLine("using System.Net.Http;")
    [void]$sb.AppendLine("using System.Net.Http.Json;")
    [void]$sb.AppendLine("using System.Threading.Tasks;")
    [void]$sb.AppendLine("using Microsoft.AspNetCore.Mvc.Testing;")
    [void]$sb.AppendLine("using Microsoft.Extensions.DependencyInjection;")
    [void]$sb.AppendLine("using Moq;")
    [void]$sb.AppendLine("using Xunit;")
    if ($namespace) {
        [void]$sb.AppendLine("using $namespace;")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("namespace $namespace.IntegrationTests")
    [void]$sb.AppendLine("{")
    [void]$sb.AppendLine("    public class $testClassName : IClassFixture<WebApplicationFactory<Program>>")
    [void]$sb.AppendLine("    {")
    [void]$sb.AppendLine("        private readonly HttpClient _client;")
    [void]$sb.AppendLine("        private readonly WebApplicationFactory<Program> _factory;")
    [void]$sb.AppendLine("")

    # Mock fields
    foreach ($dep in $mockDeps) {
        $fieldName = "_mock" + ($dep.Name.TrimStart('_').Substring(0,1).ToUpper() + $dep.Name.TrimStart('_').Substring(1))
        [void]$sb.AppendLine("        private readonly Mock<$($dep.Type)> $fieldName = new Mock<$($dep.Type)>();")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("        public $testClassName(WebApplicationFactory<Program> factory)")
    [void]$sb.AppendLine("        {")
    [void]$sb.AppendLine("            _factory = factory.WithWebHostBuilder(builder =>")
    [void]$sb.AppendLine("            {")
    [void]$sb.AppendLine("                builder.ConfigureServices(services =>")
    [void]$sb.AppendLine("                {")

    foreach ($dep in $mockDeps) {
        $fieldName = "_mock" + ($dep.Name.TrimStart('_').Substring(0,1).ToUpper() + $dep.Name.TrimStart('_').Substring(1))
        [void]$sb.AppendLine("                    services.AddSingleton($fieldName.Object);")
    }

    [void]$sb.AppendLine("                });")
    [void]$sb.AppendLine("            });")
    [void]$sb.AppendLine("            _client = _factory.CreateClient();")
    [void]$sb.AppendLine("        }")
    [void]$sb.AppendLine("")

    # Generate test methods for each endpoint
    foreach ($endpoint in $endpoints) {
        if (-not $endpoint.MethodName) { continue }

        $httpMethod = $endpoint.HttpMethod
        $route = $routePrefix
        if ($endpoint.RouteTemplate) {
            $route = "$routePrefix/$($endpoint.RouteTemplate)"
        }

        # Replace route parameters with sample values
        $testRoute = $route -replace '\{[^}]+\}', '1'

        # Generate success test
        $testName = "$($endpoint.MethodName)_Returns$(if ($httpMethod -eq 'POST') { 'Created' } elseif ($httpMethod -eq 'DELETE') { 'NoContent' } else { 'Ok' })_WhenValid"
        [void]$sb.AppendLine("        [Fact]")
        [void]$sb.AppendLine("        public async Task $testName()")
        [void]$sb.AppendLine("        {")
        [void]$sb.AppendLine("            // Arrange")

        # Smart mock setups: look up interface methods and generate .Setup() calls
        foreach ($dep in $mockDeps) {
            $fieldName = "_mock" + ($dep.Name.TrimStart('_').Substring(0,1).ToUpper() + $dep.Name.TrimStart('_').Substring(1))
            $interfaceDef = $interfaceCache[$dep.Type]
            if ($interfaceDef -and $interfaceDef.Methods) {
                foreach ($method in $interfaceDef.Methods) {
                    $setupLine = Get-MockSetupLine -VarName $fieldName -Method $method
                    if ($setupLine) {
                        [void]$sb.AppendLine("            $setupLine")
                    }
                }
            } else {
                [void]$sb.AppendLine("            // Configure $fieldName setup for $($dep.Type)")
            }
        }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("            // Act")

        switch ($httpMethod) {
            "GET" {
                [void]$sb.AppendLine("            var response = await _client.GetAsync(`"/$testRoute`");")
            }
            "POST" {
                $bodyParam = $endpoint.Parameters | Where-Object { $_.Binding -eq 'Body' } | Select-Object -First 1
                if ($bodyParam) {
                    # Smart DTO population: look up properties and generate object initializer
                    $dtoProps = Get-DtoProperties -TypeName $bodyParam.Type -RepoRoot $RepoRoot
                    if ($dtoProps -and $dtoProps.Count -gt 0) {
                        [void]$sb.AppendLine("            var request = new $($bodyParam.Type)")
                        [void]$sb.AppendLine("            {")
                        for ($propIdx = 0; $propIdx -lt $dtoProps.Count; $propIdx++) {
                            $prop = $dtoProps[$propIdx]
                            $defaultVal = Get-BuilderDefaultValue -TypeName $prop.Type -PropName $prop.Name
                            $comma = if ($propIdx -lt $dtoProps.Count - 1) { "," } else { "" }
                            [void]$sb.AppendLine("                $($prop.Name) = $defaultVal$comma")
                        }
                        [void]$sb.AppendLine("            };")
                    } else {
                        [void]$sb.AppendLine("            var request = new $($bodyParam.Type)();")
                    }
                    [void]$sb.AppendLine("            var response = await _client.PostAsJsonAsync(`"/$testRoute`", request);")
                } else {
                    [void]$sb.AppendLine("            var response = await _client.PostAsJsonAsync(`"/$testRoute`", new { });")
                }
            }
            "PUT" {
                $bodyParam = $endpoint.Parameters | Where-Object { $_.Binding -eq 'Body' } | Select-Object -First 1
                if ($bodyParam) {
                    # Smart DTO population: look up properties and generate object initializer
                    $dtoProps = Get-DtoProperties -TypeName $bodyParam.Type -RepoRoot $RepoRoot
                    if ($dtoProps -and $dtoProps.Count -gt 0) {
                        [void]$sb.AppendLine("            var request = new $($bodyParam.Type)")
                        [void]$sb.AppendLine("            {")
                        for ($propIdx = 0; $propIdx -lt $dtoProps.Count; $propIdx++) {
                            $prop = $dtoProps[$propIdx]
                            $defaultVal = Get-BuilderDefaultValue -TypeName $prop.Type -PropName $prop.Name
                            $comma = if ($propIdx -lt $dtoProps.Count - 1) { "," } else { "" }
                            [void]$sb.AppendLine("                $($prop.Name) = $defaultVal$comma")
                        }
                        [void]$sb.AppendLine("            };")
                    } else {
                        [void]$sb.AppendLine("            var request = new $($bodyParam.Type)();")
                    }
                    [void]$sb.AppendLine("            var response = await _client.PutAsJsonAsync(`"/$testRoute`", request);")
                } else {
                    [void]$sb.AppendLine("            var response = await _client.PutAsJsonAsync(`"/$testRoute`", new { });")
                }
            }
            "DELETE" {
                [void]$sb.AppendLine("            var response = await _client.DeleteAsync(`"/$testRoute`");")
            }
            "PATCH" {
                [void]$sb.AppendLine("            var response = await _client.PatchAsync(`"/$testRoute`", new StringContent(`"{}`", System.Text.Encoding.UTF8, `"application/json`"));")
            }
        }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("            // Assert")
        [void]$sb.AppendLine("            response.EnsureSuccessStatusCode();")
        [void]$sb.AppendLine("        }")
        [void]$sb.AppendLine("")

        # Generate 404 test for endpoints with route parameters
        if ($endpoint.RouteTemplate -match '\{') {
            $notFoundTestName = "$($endpoint.MethodName)_ReturnsNotFound_WhenResourceDoesNotExist"
            [void]$sb.AppendLine("        [Fact]")
            [void]$sb.AppendLine("        public async Task $notFoundTestName()")
            [void]$sb.AppendLine("        {")
            [void]$sb.AppendLine("            // Arrange")

            # Smart 404 mock setup: configure mocks to return null/empty
            $hasAnySetup = $false
            foreach ($dep in $mockDeps) {
                $fieldName = "_mock" + ($dep.Name.TrimStart('_').Substring(0,1).ToUpper() + $dep.Name.TrimStart('_').Substring(1))
                $interfaceDef = $interfaceCache[$dep.Type]
                if ($interfaceDef -and $interfaceDef.Methods) {
                    foreach ($method in $interfaceDef.Methods) {
                        $nullSetup = Get-NullMockSetupLine -VarName $fieldName -Method $method
                        if ($nullSetup) {
                            [void]$sb.AppendLine("            $nullSetup")
                            $hasAnySetup = $true
                        }
                    }
                }
            }
            if (-not $hasAnySetup) {
                [void]$sb.AppendLine("            // Configure mocks to return null/empty for the requested resource")
            }

            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("            // Act")

            $notFoundRoute = $route -replace '\{[^}]+\}', '999999'

            switch ($httpMethod) {
                "GET"    { [void]$sb.AppendLine("            var response = await _client.GetAsync(`"/$notFoundRoute`");") }
                "PUT"    { [void]$sb.AppendLine("            var response = await _client.PutAsJsonAsync(`"/$notFoundRoute`", new { });") }
                "DELETE" { [void]$sb.AppendLine("            var response = await _client.DeleteAsync(`"/$notFoundRoute`");") }
                default  { [void]$sb.AppendLine("            var response = await _client.GetAsync(`"/$notFoundRoute`");") }
            }

            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("            // Assert")
            [void]$sb.AppendLine("            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);")
            [void]$sb.AppendLine("        }")
            [void]$sb.AppendLine("")
        }

        # Generate auth test if endpoint requires authorization
        if ($endpoint.RequiresAuth) {
            $authTestName = "$($endpoint.MethodName)_ReturnsUnauthorized_WhenNotAuthenticated"
            [void]$sb.AppendLine("        [Fact]")
            [void]$sb.AppendLine("        public async Task $authTestName()")
            [void]$sb.AppendLine("        {")
            [void]$sb.AppendLine("            // Arrange")
            [void]$sb.AppendLine("            var unauthClient = _factory.CreateClient();")
            [void]$sb.AppendLine("            // Do not add auth headers")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("            // Act")

            switch ($httpMethod) {
                "GET"    { [void]$sb.AppendLine("            var response = await unauthClient.GetAsync(`"/$testRoute`");") }
                "POST"   { [void]$sb.AppendLine("            var response = await unauthClient.PostAsJsonAsync(`"/$testRoute`", new { });") }
                "PUT"    { [void]$sb.AppendLine("            var response = await unauthClient.PutAsJsonAsync(`"/$testRoute`", new { });") }
                "DELETE" { [void]$sb.AppendLine("            var response = await unauthClient.DeleteAsync(`"/$testRoute`");") }
                default  { [void]$sb.AppendLine("            var response = await unauthClient.GetAsync(`"/$testRoute`");") }
            }

            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("            // Assert")
            [void]$sb.AppendLine("            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);")
            [void]$sb.AppendLine("        }")
            [void]$sb.AppendLine("")
        }
    }

    [void]$sb.AppendLine("    }")
    [void]$sb.AppendLine("}")

    return $sb.ToString()
}
