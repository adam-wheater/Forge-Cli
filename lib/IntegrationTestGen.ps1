# IntegrationTestGen.ps1 — Integration test generation for controllers/endpoints (I10)
# Detects [ApiController] classes, extracts HTTP endpoints, and generates
# WebApplicationFactory-based integration test scaffolds.

# Dot-source CSharpAnalyser for Get-CSharpSymbols
. "$PSScriptRoot/CSharpAnalyser.ps1"

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

        # Generate mock setups for this endpoint
        foreach ($dep in $mockDeps) {
            $fieldName = "_mock" + ($dep.Name.TrimStart('_').Substring(0,1).ToUpper() + $dep.Name.TrimStart('_').Substring(1))
            [void]$sb.AppendLine("            // TODO: Configure $fieldName setup for this test case")
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
                    [void]$sb.AppendLine("            var request = new $($bodyParam.Type)(); // TODO: populate test data")
                    [void]$sb.AppendLine("            var response = await _client.PostAsJsonAsync(`"/$testRoute`", request);")
                } else {
                    [void]$sb.AppendLine("            var response = await _client.PostAsJsonAsync(`"/$testRoute`", new { });")
                }
            }
            "PUT" {
                $bodyParam = $endpoint.Parameters | Where-Object { $_.Binding -eq 'Body' } | Select-Object -First 1
                if ($bodyParam) {
                    [void]$sb.AppendLine("            var request = new $($bodyParam.Type)(); // TODO: populate test data")
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
            [void]$sb.AppendLine("            // TODO: Configure mocks to return null/empty for the requested resource")
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
