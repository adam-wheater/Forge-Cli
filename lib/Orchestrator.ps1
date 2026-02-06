. "$PSScriptRoot/AzureAgent.ps1"
. "$PSScriptRoot/RepoTools.ps1"
. "$PSScriptRoot/ImportGraph.ps1"
. "$PSScriptRoot/CallGraph.ps1"
. "$PSScriptRoot/TokenBudget.ps1"
. "$PSScriptRoot/DebugLogger.ps1"

$TOOL_PERMISSIONS = @{
    builder  = @("search_files", "open_file")
    reviewer = @("show_diff")
    judge    = @()
}

$MAX_SEARCHES = 6
$MAX_OPENS = 5

$MAX_AGENT_ITERATIONS = 20

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
    $iterations = 0

    while ($true) {
        if ($iterations++ -ge $MAX_AGENT_ITERATIONS) {
            Write-DebugLog "$Role-limit" "Hit max iteration limit ($MAX_AGENT_ITERATIONS)"
            return 'NO_CHANGES'
        }

        $response = Invoke-AzureAgent $Deployment $SystemPrompt $context
        Write-DebugLog "$Role-response" $response

        if ($response.TrimStart().StartsWith("diff --git") -or $response -eq "NO_CHANGES") {
            return $response
        }

        try {
            $json = $response | ConvertFrom-Json
        } catch {
            Write-DebugLog "$Role-parse-error" "Failed to parse response as JSON: $($_.Exception.Message)"
            return 'NO_CHANGES'
        }

        if (-not $json.tool) {
            Write-DebugLog "$Role-no-tool" "Response JSON missing 'tool' field"
            return 'NO_CHANGES'
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
            default {
                Write-DebugLog "$Role-unknown-tool" "Unknown tool: $($json.tool)"
                return 'NO_CHANGES'
            }
        }
    }
}
