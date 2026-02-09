. "$PSScriptRoot/AzureAgent.ps1"
. "$PSScriptRoot/RepoTools.ps1"
. "$PSScriptRoot/ImportGraph.ps1"
. "$PSScriptRoot/CallGraph.ps1"
. "$PSScriptRoot/TokenBudget.ps1"
. "$PSScriptRoot/DebugLogger.ps1"
. "$PSScriptRoot/CSharpAnalyser.ps1"

$TOOL_PERMISSIONS = @{
    builder  = @("search_files", "open_file", "write_file", "run_tests", "read_test_output", "get_coverage", "list_tests", "get_symbols", "get_interface", "get_nuget_info", "get_di_registrations", "semantic_search", "explain_error")
    reviewer = @("show_diff", "get_symbols")
    judge    = @()
}

$MAX_SEARCHES = 6
$MAX_OPENS = 5
$MAX_WRITES = 3
$MAX_TEST_RUNS = 2
$MAX_COVERAGE_RUNS = 1

$MAX_AGENT_ITERATIONS = 20

# J11: Flag to enable native function calling instead of JSON-in-text protocol
$USE_FUNCTION_CALLING = $false

function New-AgentError {
    param (
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Message
    )
    return @{
        type      = $Type
        role      = $Role
        message   = $Message
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Invoke-WriteFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    try {
        $resolvedRepo = (Resolve-Path $RepoRoot -ErrorAction Stop).Path
        $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $resolvedRepo $Path }
        $fullPath = [System.IO.Path]::GetFullPath($fullPath)

        # Validate: path must be within RepoRoot
        if (-not $fullPath.StartsWith($resolvedRepo)) {
            return "WRITE_FAILED: Path '$Path' is outside the repository root"
        }

        # Validate: path must be a .cs file
        if ($fullPath -notmatch '\.cs$') {
            return "WRITE_FAILED: Only .cs files can be written (got '$Path')"
        }

        # Ensure directory exists
        $dir = Split-Path $fullPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $Content | Out-File -FilePath $fullPath -Encoding utf8 -Force
        $lineCount = ($Content | Measure-Object -Line).Lines
        return "FILE_WRITTEN: $Path ($lineCount lines)"
    } catch {
        return "WRITE_FAILED: $($_.Exception.Message)"
    }
}

function Invoke-RunTests {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Filter
    )

    try {
        $testArgs = @("test", $RepoRoot, "--verbosity", "normal")
        if ($Filter) {
            $testArgs += "--filter"
            $testArgs += $Filter
        }

        $output = $null
        $job = Start-Job -ScriptBlock {
            param($a)
            & dotnet @a 2>&1 | Out-String
        } -ArgumentList (,$testArgs)

        $completed = $job | Wait-Job -Timeout 120
        if (-not $completed) {
            $job | Stop-Job
            $job | Remove-Job -Force
            return '{"Error":"TEST_TIMEOUT: Tests exceeded 120 second limit"}'
        }

        $output = $job | Receive-Job
        $job | Remove-Job -Force

        $result = @{
            Passed    = @()
            Failed    = @()
            Total     = 0
            PassCount = 0
            FailCount = 0
        }

        # Parse passed tests
        $passMatches = [regex]::Matches($output, 'Passed\s+([\w.]+)')
        foreach ($m in $passMatches) {
            $result.Passed += $m.Groups[1].Value
        }

        # Parse failed tests
        $failPattern = 'Failed\s+([\w.]+)\s*.*?Message:\s*(.+?)(?:Stack Trace:\s*(.+?))?(?=Failed\s+|$)'
        $failMatches = [regex]::Matches($output, $failPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        foreach ($m in $failMatches) {
            $result.Failed += @{
                Name       = $m.Groups[1].Value
                Message    = $m.Groups[2].Value.Trim()
                StackTrace = if ($m.Groups[3].Value) { $m.Groups[3].Value.Trim() } else { "" }
            }
        }

        # Parse summary line: "Total tests: X, Passed: Y, Failed: Z"
        if ($output -match 'Total tests:\s*(\d+)') {
            $result.Total = [int]$matches[1]
        }
        if ($output -match 'Passed:\s*(\d+)') {
            $result.PassCount = [int]$matches[1]
        }
        if ($output -match 'Failed:\s*(\d+)') {
            $result.FailCount = [int]$matches[1]
        }

        return ($result | ConvertTo-Json -Depth 5 -Compress)
    } catch {
        return "{`"Error`":`"TEST_RUN_FAILED: $($_.Exception.Message)`"}"
    }
}

function Invoke-ReadTestOutput {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    try {
        # Look for most recent .trx file in RepoRoot/**/TestResults/
        $trxFiles = Get-ChildItem $RepoRoot -Filter "*.trx" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'TestResults' } |
            Sort-Object LastWriteTime -Descending

        if (-not $trxFiles -or $trxFiles.Count -eq 0) {
            return "NO_TEST_RESULTS_FOUND"
        }

        $trxPath = $trxFiles[0].FullName
        [xml]$trx = Get-Content $trxPath -Raw

        $ns = @{ t = "http://microsoft.com/schemas/VisualStudio/TeamTest/2010" }
        $results = @()

        $testResults = $trx.TestRun.Results.UnitTestResult
        if (-not $testResults) {
            return "NO_TEST_RESULTS_FOUND"
        }

        foreach ($tr in $testResults) {
            $entry = @{
                Name    = $tr.testName
                Outcome = $tr.outcome
            }

            if ($tr.Output -and $tr.Output.ErrorInfo) {
                $entry.ErrorMessage = if ($tr.Output.ErrorInfo.Message) { $tr.Output.ErrorInfo.Message } else { "" }
                $entry.StackTrace = if ($tr.Output.ErrorInfo.StackTrace) { $tr.Output.ErrorInfo.StackTrace } else { "" }
            }

            $results += $entry
        }

        return ($results | ConvertTo-Json -Depth 5 -Compress)
    } catch {
        return "READ_TEST_OUTPUT_FAILED: $($_.Exception.Message)"
    }
}

function Invoke-GetCoverage {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    try {
        $resultsDir = Join-Path $RepoRoot "TestResults"

        $job = Start-Job -ScriptBlock {
            param($root, $dir)
            & dotnet test $root --collect:"XPlat Code Coverage" --results-directory $dir 2>&1 | Out-String
        } -ArgumentList $RepoRoot, $resultsDir

        $completed = $job | Wait-Job -Timeout 180
        if (-not $completed) {
            $job | Stop-Job
            $job | Remove-Job -Force
            return "COVERAGE_TIMEOUT: Coverage collection exceeded 180 second limit"
        }

        $output = $job | Receive-Job
        $job | Remove-Job -Force

        # Find coverage.cobertura.xml in results
        $coverageFiles = Get-ChildItem $resultsDir -Filter "coverage.cobertura.xml" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        if (-not $coverageFiles -or $coverageFiles.Count -eq 0) {
            return "COVERAGE_NOT_AVAILABLE: Install coverlet.collector NuGet package"
        }

        [xml]$coverage = Get-Content $coverageFiles[0].FullName -Raw

        $lines = @()
        $packages = $coverage.coverage.packages.package
        if (-not $packages) {
            return "COVERAGE_NOT_AVAILABLE: No coverage data found in report"
        }

        foreach ($pkg in $packages) {
            $classes = $pkg.classes.class
            if (-not $classes) { continue }

            foreach ($cls in $classes) {
                $className = $cls.name
                $lineRate = [math]::Round([double]$cls.'line-rate' * 100, 1)

                # Find uncovered lines
                $uncovered = @()
                if ($cls.lines -and $cls.lines.line) {
                    foreach ($line in $cls.lines.line) {
                        if ([int]$line.hits -eq 0) {
                            $uncovered += [int]$line.number
                        }
                    }
                }

                # Group consecutive uncovered lines into ranges
                $ranges = @()
                if ($uncovered.Count -gt 0) {
                    $uncovered = $uncovered | Sort-Object
                    $start = $uncovered[0]
                    $end = $uncovered[0]
                    for ($i = 1; $i -lt $uncovered.Count; $i++) {
                        if ($uncovered[$i] -eq $end + 1) {
                            $end = $uncovered[$i]
                        } else {
                            $ranges += if ($start -eq $end) { "$start" } else { "$start-$end" }
                            $start = $uncovered[$i]
                            $end = $uncovered[$i]
                        }
                    }
                    $ranges += if ($start -eq $end) { "$start" } else { "$start-$end" }
                }

                $uncoveredStr = if ($ranges.Count -gt 0) { ", uncovered lines: $($ranges -join ', ')" } else { "" }
                $lines += "CLASS: $className — ${lineRate}% covered${uncoveredStr}"
            }
        }

        return ($lines -join "`n")
    } catch {
        return "COVERAGE_FAILED: $($_.Exception.Message)"
    }
}

function Invoke-ExplainError {
    param(
        [Parameter(Mandatory)][string]$ErrorText
    )

    $result = @{
        Category        = "Unknown"
        Explanation     = ""
        LikelyFile      = ""
        SuggestedAction = ""
    }

    # Extract file reference from error text
    if ($ErrorText -match '(?:in\s+|at\s+\S+\s+in\s+)([^\s:]+\.cs)') {
        $result.LikelyFile = $matches[1]
    }

    # Parse common C# error patterns
    if ($ErrorText -match "CS0246.*?'([^']+)'") {
        $result.Category = "MissingType"
        $result.Explanation = "Missing using directive or assembly reference for '$($matches[1])'"
        $result.SuggestedAction = "Add the correct using directive or install the required NuGet package for '$($matches[1])'"
    }
    elseif ($ErrorText -match 'NullReferenceException') {
        $result.Category = "NullReference"
        $result.Explanation = "Object is null. Check mock setup returns non-null values."
        $result.SuggestedAction = "Verify mock Setup() calls return non-null values and all dependencies are properly initialized"
    }
    elseif ($ErrorText -match 'InvalidOperationException') {
        $result.Category = "InvalidOperation"
        $result.Explanation = "Check service registration in DI container."
        $result.SuggestedAction = "Verify all required services are registered in Startup.cs or Program.cs"
    }
    elseif ($ErrorText -match 'NotImplementedException') {
        $result.Category = "NotImplemented"
        $result.Explanation = "Method has throw new NotImplementedException() — needs implementation."
        $result.SuggestedAction = "Implement the method body instead of throwing NotImplementedException"
    }
    elseif ($ErrorText -match 'CS1002') {
        $result.Category = "SyntaxError"
        $result.Explanation = "Missing semicolon in C# code"
        $result.SuggestedAction = "Add the missing semicolon at the indicated line"
    }
    elseif ($ErrorText -match 'CS1513') {
        $result.Category = "SyntaxError"
        $result.Explanation = "Expected closing brace '}' in C# code"
        $result.SuggestedAction = "Add the missing closing brace at the indicated location"
    }
    elseif ($ErrorText -match "CS0103.*?'([^']+)'") {
        $result.Category = "UndefinedName"
        $result.Explanation = "The name '$($matches[1])' does not exist in the current context"
        $result.SuggestedAction = "Declare the variable '$($matches[1])' or add the correct using directive"
    }
    elseif ($ErrorText -match 'CS0029') {
        $result.Category = "TypeMismatch"
        $result.Explanation = "Cannot implicitly convert between types"
        $result.SuggestedAction = "Add an explicit cast or change the variable type to match"
    }
    elseif ($ErrorText -match 'CS0115') {
        $result.Category = "OverrideError"
        $result.Explanation = "No suitable method found to override"
        $result.SuggestedAction = "Check the base class has the method marked as virtual or abstract"
    }
    else {
        $result.Category = "General"
        $result.Explanation = "Unrecognized error pattern"
        $result.SuggestedAction = "Review the full error message and stack trace for more context"
    }

    return "$($result.Category): $($result.Explanation)`nLikelyFile: $($result.LikelyFile)`nSuggestedAction: $($result.SuggestedAction)"
}

function Invoke-ListTests {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    try {
        $output = & dotnet test $RepoRoot --list-tests --verbosity quiet 2>&1 | Out-String

        # Parse output to extract test method names
        $testNames = @()
        $inList = $false
        foreach ($line in $output -split "`n") {
            $trimmed = $line.Trim()
            if ($trimmed -match '^The following Tests are available:') {
                $inList = $true
                continue
            }
            if ($inList -and $trimmed -ne '' -and $trimmed -notmatch '^(Test run|Microsoft|$)') {
                $testNames += $trimmed
            }
        }

        if ($testNames.Count -eq 0) {
            return "NO_TESTS_FOUND"
        }

        # Group by class name
        $grouped = @{}
        foreach ($name in $testNames) {
            # Try to split on last dot to get class and method
            $lastDot = $name.LastIndexOf('.')
            if ($lastDot -gt 0) {
                $className = $name.Substring(0, $lastDot)
                $methodName = $name.Substring($lastDot + 1)
                # Use just the last part of the class name
                $classShort = $className.Split('.')[-1]
            } else {
                $classShort = "Tests"
                $methodName = $name
            }

            if (-not $grouped.ContainsKey($classShort)) {
                $grouped[$classShort] = @()
            }
            $grouped[$classShort] += $methodName
        }

        $lines = @()
        foreach ($cls in $grouped.Keys | Sort-Object) {
            $methods = $grouped[$cls] -join ", "
            $lines += "${cls}: $methods"
        }

        return ($lines -join "`n")
    } catch {
        return "LIST_TESTS_FAILED: $($_.Exception.Message)"
    }
}

function Run-Agent {
    param (
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$InitialContext
    )

    $context = $InitialContext
    $searches = 0
    $opens = 0
    $writes = 0
    $testRuns = 0
    $coverageRuns = 0
    $iterations = 0

    while ($true) {
        if ($iterations++ -ge $MAX_AGENT_ITERATIONS) {
            Write-DebugLog "$Role-limit" "Hit max iteration limit ($MAX_AGENT_ITERATIONS)"
            return 'NO_CHANGES'
        }

        $formatHint = ""
        if ($Role -eq "builder") {
            $formatHint = "`nREMINDER: You may call tools via JSON (e.g. {""tool"":""search_files"",""pattern"":""...""}) to gather information. When you are DONE investigating and ready to produce your final answer, return ONLY a unified git diff starting with 'diff --git'. No prose, no markdown fences. If no changes needed, reply exactly: NO_CHANGES"
        }
        $response = Invoke-AzureAgent $Deployment $SystemPrompt "$context$formatHint"
        Write-DebugLog "$Role-response" $response

        # Persist raw model response for debugging
        try {
            $repoRoot = (Get-Location).Path
            $logDir = Join-Path $repoRoot 'tmp-logs'
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $safeRole = ($Role -replace '[^a-zA-Z0-9_-]', '_')
            $fileName = "$($safeRole)-response-iteration-$($iterations).txt"
            $fullPath = Join-Path $logDir $fileName
            $response | Out-File -FilePath $fullPath -Encoding utf8 -Force
        } catch {
            Write-DebugLog "log-dump-failed" $_.Exception.Message
        }

        # Ensure response is a string before checking content
        if ($response -and -not ($response -is [string])) {
            try {
                if ($response.Content) { $response = $response.Content }
                else { $response = $response | ConvertTo-Json -Depth 6 }
            } catch { $response = $response.ToString() }
        }
        if (-not $response) {
            Write-DebugLog "$Role-empty" "Empty response from model"
            return 'NO_CHANGES'
        }

        if ($response.TrimStart().StartsWith("diff --git") -or $response.TrimStart().StartsWith("--- a/") -or $response -eq "NO_CHANGES") {
            return $response
        }

        try {
            $json = $response | ConvertFrom-Json
        } catch {
            Write-DebugLog "$Role-parse-error" "Failed to parse response as JSON: $($_.Exception.Message) - attempting tolerant parse"
            # Attempt tolerant parsing: convert concatenated JSON objects into an array
            try {
                $maybe = "[$($response -replace '\}\s*\{', '},{')]"
                $json = $maybe | ConvertFrom-Json
            } catch {
                Write-DebugLog "$Role-parse-error2" "Tolerant parse failed: $($_.Exception.Message)"
                # If response looks like it contains a diff buried in prose, try to extract it
                if ($response -match 'diff --git') {
                    $idx = $response.IndexOf('diff --git')
                    return $response.Substring($idx).Trim()
                }
                return (New-AgentError -Type "parse_error" -Role $Role -Message "Failed to parse response as JSON: $($_.Exception.Message)")
            }
        }

        # If parsed JSON is an array, process each tool-call sequentially
        if ($json -is [System.Array]) {
            foreach ($item in $json) {
                if (-not $item.tool) {
                    Write-DebugLog "$Role-no-tool" "One of the response items is missing 'tool'"
                    return (New-AgentError -Type "no_tool" -Role $Role -Message "One of the response items is missing 'tool'")
                }
                if (-not ($TOOL_PERMISSIONS[$Role] -contains $item.tool)) {
                    throw "Forbidden tool $($item.tool) for role $Role"
                }

                # Build arguments hashtable from item properties (excluding 'tool')
                $toolArgs = @{}
                foreach ($p in $item.PSObject.Properties) {
                    if ($p.Name -ne 'tool') { $toolArgs[$p.Name] = $p.Value }
                }

                try {
                    $toolResult = Invoke-ToolCall -Role $Role -ToolName $item.tool -Arguments $toolArgs -Searches ([ref]$searches) -Opens ([ref]$opens) -Writes ([ref]$writes) -TestRuns ([ref]$testRuns) -CoverageRuns ([ref]$coverageRuns)
                } catch {
                    $toolResult = "TOOL_ERROR: $($_.Exception.Message)"
                }

                Write-DebugLog "$Role-array-tool-result" $toolResult
                $context += "`n$($item.tool) result:`n$toolResult"
            }

            # After processing array, continue loop to ask model again
            continue
        }
        if (-not $json.tool) {
            Write-DebugLog "$Role-no-tool" "Response JSON missing 'tool' field"
            return (New-AgentError -Type "no_tool" -Role $Role -Message "Response JSON missing 'tool' field")
        }

        if (-not ($TOOL_PERMISSIONS[$Role] -contains $json.tool)) {
            throw "Forbidden tool $($json.tool) for role $Role"
        }

        switch ($json.tool) {
            "search_files" {
                if ($searches++ -ge $MAX_SEARCHES) { return 'NO_CHANGES' }
                $results = Search-Files $json.pattern
                Write-DebugLog "$Role-search" ($results -join "`n")
                $context += "`nSEARCH_RESULTS:`n$($results -join "`n")"
            }
            "open_file" {
                if ($opens++ -ge $MAX_OPENS) { return 'NO_CHANGES' }
                $file = Open-File $json.path
                $imports = Get-Imports $json.path
                $ctors = Get-ConstructorDependencies $json.path
                Write-DebugLog "$Role-open" $file
                $context += "`nFILE $($json.path):`n$file"
                if ($imports) { $context += "`nIMPORTS:`n$($imports -join "`n")" }
                if ($ctors) { $context += "`nCONSTRUCTOR_DEPENDENCIES:`n$($ctors -join "`n")" }
            }
            "show_diff" {
                $diff = Show-Diff
                Write-DebugLog "$Role-diff" $diff
                $context += "`nDIFF:`n$diff"
            }
            "write_file" {
                if ($writes++ -ge $MAX_WRITES) { return 'NO_CHANGES' }
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Invoke-WriteFile -Path $json.path -Content $json.content -RepoRoot $repoRoot
                Write-DebugLog "$Role-write" $result
                $context += "`nWRITE_RESULT:`n$result"
            }
            "run_tests" {
                if ($testRuns++ -ge $MAX_TEST_RUNS) { return 'NO_CHANGES' }
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Invoke-RunTests -RepoRoot $repoRoot -Filter $json.filter
                Write-DebugLog "$Role-tests" $result
                $context += "`nTEST_RESULTS:`n$result"
            }
            "read_test_output" {
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Invoke-ReadTestOutput -RepoRoot $repoRoot
                Write-DebugLog "$Role-test-output" $result
                $context += "`nTEST_OUTPUT:`n$result"
            }
            "get_coverage" {
                if ($coverageRuns++ -ge $MAX_COVERAGE_RUNS) { return 'NO_CHANGES' }
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Invoke-GetCoverage -RepoRoot $repoRoot
                Write-DebugLog "$Role-coverage" $result
                $context += "`nCOVERAGE:`n$result"
            }
            "explain_error" {
                $result = Invoke-ExplainError -ErrorText $json.error_text
                Write-DebugLog "$Role-explain" $result
                $context += "`nERROR_EXPLANATION:`n$result"
            }
            "list_tests" {
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Invoke-ListTests -RepoRoot $repoRoot
                Write-DebugLog "$Role-list-tests" $result
                $context += "`nTEST_LIST:`n$result"
            }
            "get_symbols" {
                $result = Get-CSharpSymbols -Path $json.path
                $formatted = "Namespace: $($result.Namespace)`n"
                foreach ($cls in $result.Classes) {
                    $formatted += "Class: $($cls.Name) [$($cls.Visibility)] Line:$($cls.Line)`n"
                    foreach ($m in $cls.Methods) {
                        $params = ($m.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                        $formatted += "  Method: $($m.ReturnType) $($m.Name)($params) Line:$($m.Line)`n"
                    }
                    foreach ($p in $cls.Properties) {
                        $formatted += "  Prop: $($p.Type) $($p.Name) Line:$($p.Line)`n"
                    }
                    foreach ($c in $cls.Constructors) {
                        $params = ($c.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                        $formatted += "  Ctor: ($params) Line:$($c.Line)`n"
                    }
                }
                Write-DebugLog "$Role-symbols" $formatted
                $context += "`nSYMBOLS:`n$formatted"
            }
            "get_interface" {
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Get-CSharpInterface -InterfaceName $json.name -RepoRoot $repoRoot
                if ($result) {
                    $formatted = "Interface: $($result.Name) in $($result.Path)`n"
                    foreach ($m in $result.Methods) {
                        $params = ($m.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                        $formatted += "  $($m.ReturnType) $($m.Name)($params)`n"
                    }
                } else {
                    $formatted = "INTERFACE_NOT_FOUND: $($json.name)"
                }
                Write-DebugLog "$Role-interface" $formatted
                $context += "`nINTERFACE:`n$formatted"
            }
            "get_nuget_info" {
                $result = Get-NuGetPackages -ProjectPath $json.path
                $formatted = "TestFramework: $($result.TestFramework), MockLibrary: $($result.MockLibrary), AssertionLibrary: $($result.AssertionLibrary)`n"
                $formatted += "Packages: $(($result.Packages | ForEach-Object { "$($_.Name)@$($_.Version)" }) -join ', ')`n"
                if ($result.CoverageTools.Count -gt 0) {
                    $formatted += "CoverageTools: $($result.CoverageTools -join ', ')"
                }
                Write-DebugLog "$Role-nuget" $formatted
                $context += "`nNUGET_INFO:`n$formatted"
            }
            "get_di_registrations" {
                $repoRoot = if ($json.repo_root) { $json.repo_root } else { (Get-Location).Path }
                $result = Get-DIRegistrations -RepoRoot $repoRoot
                $formatted = ""
                foreach ($reg in $result.Registrations) {
                    $formatted += "$($reg.Lifetime): $($reg.Interface) -> $($reg.Implementation) (line $($reg.Line))`n"
                }
                if (-not $formatted) { $formatted = "NO_DI_REGISTRATIONS_FOUND" }
                Write-DebugLog "$Role-di" $formatted
                $context += "`nDI_REGISTRATIONS:`n$formatted"
            }
            "semantic_search" {
                # G03: Semantic search tool — prefer Invoke-SemanticSearch, fallback to Search-Embeddings
                $query = $json.query
                $topK = if ($json.top_k) { [int]$json.top_k } else { 10 }
                if (Get-Command Invoke-SemanticSearch -ErrorAction SilentlyContinue) {
                    try {
                        $result = Invoke-SemanticSearch -Query $query -TopK $topK
                        $formatted = $result
                    } catch {
                        $formatted = "SEMANTIC_SEARCH_FAILED: $($_.Exception.Message)"
                    }
                } elseif (Get-Command Search-Embeddings -ErrorAction SilentlyContinue) {
                    $result = Search-Embeddings -Query $query
                    $formatted = ($result | ForEach-Object { "$($_.Path): $($_.Score)" }) -join "`n"
                } else {
                    $formatted = "SEMANTIC_SEARCH_NOT_AVAILABLE: Embeddings module not loaded"
                }
                Write-DebugLog "$Role-semantic" $formatted
                $context += "`nSEMANTIC_RESULTS:`n$formatted"
            }
            default {
                Write-DebugLog "$Role-unknown-tool" "Unknown tool: $($json.tool)"
                return (New-AgentError -Type "unknown_tool" -Role $Role -Message "Unknown tool: $($json.tool)")
            }
        }
    }
}

# J11: Build tool definitions array for native function calling
function Build-ToolDefinitions {
    param (
        [Parameter(Mandatory)][string]$Role
    )

    $allTools = @{
        search_files = @{
            type = "function"
            function = @{
                name = "search_files"
                description = "Search repository for files matching a regex pattern"
                parameters = @{
                    type = "object"
                    properties = @{
                        pattern = @{ type = "string"; description = "Regex pattern to match file names/paths" }
                    }
                    required = @("pattern")
                }
            }
        }
        open_file = @{
            type = "function"
            function = @{
                name = "open_file"
                description = "Read a file's contents including imports and constructor dependencies"
                parameters = @{
                    type = "object"
                    properties = @{
                        path = @{ type = "string"; description = "File path relative to repository root" }
                    }
                    required = @("path")
                }
            }
        }
        show_diff = @{
            type = "function"
            function = @{
                name = "show_diff"
                description = "View current git diff of working tree"
                parameters = @{
                    type = "object"
                    properties = @{}
                }
            }
        }
        write_file = @{
            type = "function"
            function = @{
                name = "write_file"
                description = "Create or overwrite a file in the repository"
                parameters = @{
                    type = "object"
                    properties = @{
                        path = @{ type = "string"; description = "File path relative to repository root" }
                        content = @{ type = "string"; description = "Full file content to write" }
                    }
                    required = @("path", "content")
                }
            }
        }
        run_tests = @{
            type = "function"
            function = @{
                name = "run_tests"
                description = "Execute dotnet test and get structured pass/fail results"
                parameters = @{
                    type = "object"
                    properties = @{
                        filter = @{ type = "string"; description = "Optional test filter expression" }
                    }
                }
            }
        }
        read_test_output = @{
            type = "function"
            function = @{
                name = "read_test_output"
                description = "Read structured TRX test results from the most recent test run"
                parameters = @{
                    type = "object"
                    properties = @{}
                }
            }
        }
        get_coverage = @{
            type = "function"
            function = @{
                name = "get_coverage"
                description = "Run tests with code coverage and return uncovered lines per class"
                parameters = @{
                    type = "object"
                    properties = @{}
                }
            }
        }
        list_tests = @{
            type = "function"
            function = @{
                name = "list_tests"
                description = "List all test method names grouped by test class"
                parameters = @{
                    type = "object"
                    properties = @{}
                }
            }
        }
        get_symbols = @{
            type = "function"
            function = @{
                name = "get_symbols"
                description = "Get class/method/property signatures from a C# file"
                parameters = @{
                    type = "object"
                    properties = @{
                        path = @{ type = "string"; description = "File path to analyse" }
                    }
                    required = @("path")
                }
            }
        }
        get_interface = @{
            type = "function"
            function = @{
                name = "get_interface"
                description = "Find and return an interface definition by name"
                parameters = @{
                    type = "object"
                    properties = @{
                        name = @{ type = "string"; description = "Interface name (e.g. IUserService)" }
                    }
                    required = @("name")
                }
            }
        }
        get_nuget_info = @{
            type = "function"
            function = @{
                name = "get_nuget_info"
                description = "Get NuGet packages and detected test framework, mock library, assertion library"
                parameters = @{
                    type = "object"
                    properties = @{
                        path = @{ type = "string"; description = "Path to .csproj file" }
                    }
                    required = @("path")
                }
            }
        }
        get_di_registrations = @{
            type = "function"
            function = @{
                name = "get_di_registrations"
                description = "Get dependency injection registrations from Startup.cs or Program.cs"
                parameters = @{
                    type = "object"
                    properties = @{}
                }
            }
        }
        semantic_search = @{
            type = "function"
            function = @{
                name = "semantic_search"
                description = "Search code by semantic meaning using embeddings"
                parameters = @{
                    type = "object"
                    properties = @{
                        query = @{ type = "string"; description = "Natural language query" }
                        top_k = @{ type = "integer"; description = "Number of results to return (default 10)" }
                    }
                    required = @("query")
                }
            }
        }
        explain_error = @{
            type = "function"
            function = @{
                name = "explain_error"
                description = "Get structured explanation of a C# error or stack trace"
                parameters = @{
                    type = "object"
                    properties = @{
                        error_text = @{ type = "string"; description = "Error message or stack trace text" }
                    }
                    required = @("error_text")
                }
            }
        }
    }

    # Filter to only tools permitted for this role
    $permitted = $TOOL_PERMISSIONS[$Role]
    if (-not $permitted -or $permitted.Count -eq 0) {
        return @()
    }

    $definitions = @()
    foreach ($toolName in $permitted) {
        if ($allTools.ContainsKey($toolName)) {
            $definitions += $allTools[$toolName]
        }
    }

    return $definitions
}

# J11: Execute a tool call from function calling response
function Invoke-ToolCall {
    param (
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [ref]$Searches,
        [ref]$Opens,
        [ref]$Writes,
        [ref]$TestRuns,
        [ref]$CoverageRuns
    )

    # Permission check
    if (-not ($TOOL_PERMISSIONS[$Role] -contains $ToolName)) {
        return "FORBIDDEN: Tool $ToolName not allowed for role $Role"
    }

    switch ($ToolName) {
        "search_files" {
            if ($Searches.Value -ge $MAX_SEARCHES) { return "LIMIT_REACHED: Max searches ($MAX_SEARCHES) exceeded" }
            $Searches.Value++
            $results = Search-Files $Arguments.pattern
            return "SEARCH_RESULTS:`n$($results -join "`n")"
        }
        "open_file" {
            if ($Opens.Value -ge $MAX_OPENS) { return "LIMIT_REACHED: Max opens ($MAX_OPENS) exceeded" }
            $Opens.Value++
            $file = Open-File $Arguments.path
            $imports = Get-Imports $Arguments.path
            $ctors = Get-ConstructorDependencies $Arguments.path
            $result = "FILE $($Arguments.path):`n$file"
            if ($imports) { $result += "`nIMPORTS:`n$($imports -join "`n")" }
            if ($ctors) { $result += "`nCONSTRUCTOR_DEPENDENCIES:`n$($ctors -join "`n")" }
            return $result
        }
        "show_diff" {
            return "DIFF:`n$(Show-Diff)"
        }
        "write_file" {
            if ($Writes.Value -ge $MAX_WRITES) { return "LIMIT_REACHED: Max writes ($MAX_WRITES) exceeded" }
            $Writes.Value++
            $repoRoot = (Get-Location).Path
            return Invoke-WriteFile -Path $Arguments.path -Content $Arguments.content -RepoRoot $repoRoot
        }
        "run_tests" {
            if ($TestRuns.Value -ge $MAX_TEST_RUNS) { return "LIMIT_REACHED: Max test runs ($MAX_TEST_RUNS) exceeded" }
            $TestRuns.Value++
            $repoRoot = (Get-Location).Path
            return Invoke-RunTests -RepoRoot $repoRoot -Filter $Arguments.filter
        }
        "read_test_output" {
            $repoRoot = (Get-Location).Path
            return Invoke-ReadTestOutput -RepoRoot $repoRoot
        }
        "get_coverage" {
            if ($CoverageRuns.Value -ge $MAX_COVERAGE_RUNS) { return "LIMIT_REACHED: Max coverage runs ($MAX_COVERAGE_RUNS) exceeded" }
            $CoverageRuns.Value++
            $repoRoot = (Get-Location).Path
            return Invoke-GetCoverage -RepoRoot $repoRoot
        }
        "list_tests" {
            $repoRoot = (Get-Location).Path
            return Invoke-ListTests -RepoRoot $repoRoot
        }
        "get_symbols" {
            $result = Get-CSharpSymbols -Path $Arguments.path
            $formatted = "Namespace: $($result.Namespace)`n"
            foreach ($cls in $result.Classes) {
                $formatted += "Class: $($cls.Name) [$($cls.Visibility)] Line:$($cls.Line)`n"
                foreach ($m in $cls.Methods) {
                    $params = ($m.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                    $formatted += "  Method: $($m.ReturnType) $($m.Name)($params) Line:$($m.Line)`n"
                }
                foreach ($p in $cls.Properties) {
                    $formatted += "  Prop: $($p.Type) $($p.Name) Line:$($p.Line)`n"
                }
                foreach ($c in $cls.Constructors) {
                    $params = ($c.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                    $formatted += "  Ctor: ($params) Line:$($c.Line)`n"
                }
            }
            return "SYMBOLS:`n$formatted"
        }
        "get_interface" {
            $repoRoot = (Get-Location).Path
            $result = Get-CSharpInterface -InterfaceName $Arguments.name -RepoRoot $repoRoot
            if ($result) {
                $formatted = "Interface: $($result.Name) in $($result.Path)`n"
                foreach ($m in $result.Methods) {
                    $params = ($m.Parameters | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ", "
                    $formatted += "  $($m.ReturnType) $($m.Name)($params)`n"
                }
                return "INTERFACE:`n$formatted"
            } else {
                return "INTERFACE_NOT_FOUND: $($Arguments.name)"
            }
        }
        "get_nuget_info" {
            $result = Get-NuGetPackages -ProjectPath $Arguments.path
            $formatted = "TestFramework: $($result.TestFramework), MockLibrary: $($result.MockLibrary), AssertionLibrary: $($result.AssertionLibrary)`n"
            $formatted += "Packages: $(($result.Packages | ForEach-Object { "$($_.Name)@$($_.Version)" }) -join ', ')`n"
            if ($result.CoverageTools.Count -gt 0) {
                $formatted += "CoverageTools: $($result.CoverageTools -join ', ')"
            }
            return "NUGET_INFO:`n$formatted"
        }
        "get_di_registrations" {
            $repoRoot = (Get-Location).Path
            $result = Get-DIRegistrations -RepoRoot $repoRoot
            $formatted = ""
            foreach ($reg in $result.Registrations) {
                $formatted += "$($reg.Lifetime): $($reg.Interface) -> $($reg.Implementation) (line $($reg.Line))`n"
            }
            if (-not $formatted) { $formatted = "NO_DI_REGISTRATIONS_FOUND" }
            return "DI_REGISTRATIONS:`n$formatted"
        }
        "semantic_search" {
            $topK = if ($Arguments.top_k) { [int]$Arguments.top_k } else { 10 }
            if (Get-Command Invoke-SemanticSearch -ErrorAction SilentlyContinue) {
                try {
                    return Invoke-SemanticSearch -Query $Arguments.query -TopK $topK
                } catch {
                    return "SEMANTIC_SEARCH_FAILED: $($_.Exception.Message)"
                }
            } elseif (Get-Command Search-Embeddings -ErrorAction SilentlyContinue) {
                $result = Search-Embeddings -Query $Arguments.query
                return "SEMANTIC_RESULTS:`n$(($result | ForEach-Object { "$($_.Path): $($_.Score)" }) -join "`n")"
            } else {
                return "SEMANTIC_SEARCH_NOT_AVAILABLE: Embeddings module not loaded"
            }
        }
        "explain_error" {
            return Invoke-ExplainError -ErrorText $Arguments.error_text
        }
        default {
            return "UNKNOWN_TOOL: $ToolName"
        }
    }
}

# J11: Run agent using native Azure OpenAI function calling
function Run-AgentWithFunctionCalling {
    param (
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$InitialContext
    )

    $tools = Build-ToolDefinitions -Role $Role
    $searches = 0
    $opens = 0
    $writes = 0
    $testRuns = 0
    $coverageRuns = 0
    $iterations = 0

    # Accumulate context across iterations so the model sees prior tool results
    $accumulatedContext = $InitialContext

    while ($true) {
        if ($iterations++ -ge $MAX_AGENT_ITERATIONS) {
            Write-DebugLog "$Role-fc-limit" "Hit max iteration limit ($MAX_AGENT_ITERATIONS)"
            return 'NO_CHANGES'
        }

        try {
            $response = Invoke-AzureAgentWithTools -Deployment $Deployment `
                -SystemPrompt $SystemPrompt -UserPrompt $accumulatedContext `
                -Tools $tools
        } catch {
            Write-DebugLog "$Role-fc-error" "Function calling API error: $($_.Exception.Message)"
            return (New-AgentError -Type "api_error" -Role $Role -Message $_.Exception.Message)
        }

        # Persist raw function-calling response for debugging
        try {
            $repoRoot = (Get-Location).Path
            $logDir = Join-Path $repoRoot 'tmp-logs'
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $safeRole = ($Role -replace '[^a-zA-Z0-9_-]', '_')
            $fileName = "$($safeRole)-fc-response-iteration-$($iterations).json"
            $fullPath = Join-Path $logDir $fileName
            $response | ConvertTo-Json -Depth 10 | Out-File -FilePath $fullPath -Encoding utf8 -Force
        } catch {
            Write-DebugLog "log-dump-failed-fc" $_.Exception.Message
        }

        # If no tool calls, the model returned final content
        if (-not $response.ToolCalls -or $response.ToolCalls.Count -eq 0) {
            $content = $response.Content
            if ($content -and $content.TrimStart().StartsWith("diff --git") -or $content -eq "NO_CHANGES") {
                return $content
            }
            # Model returned content but no diff — treat as no changes
            Write-DebugLog "$Role-fc-no-diff" "Model returned content without diff or tool calls"
            return $content
        }

        # Process tool calls and accumulate results into context
        foreach ($tc in $response.ToolCalls) {
            Write-DebugLog "$Role-fc-tool" "Tool call: $($tc.Name) args: $($tc.Arguments | ConvertTo-Json -Compress -Depth 5)"

            try {
                $toolResult = Invoke-ToolCall -Role $Role -ToolName $tc.Name `
                    -Arguments $tc.Arguments `
                    -Searches ([ref]$searches) -Opens ([ref]$opens) -Writes ([ref]$writes) `
                    -TestRuns ([ref]$testRuns) -CoverageRuns ([ref]$coverageRuns)
            } catch {
                $toolResult = "TOOL_ERROR: $($_.Exception.Message)"
            }

            Write-DebugLog "$Role-fc-result" $toolResult

            # Append tool result to accumulated context so next iteration sees it
            $accumulatedContext += "`n$($tc.Name) result:`n$toolResult"
        }
    }
}
