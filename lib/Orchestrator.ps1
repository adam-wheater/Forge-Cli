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

function Run-Agent {
    param ($Role, $Deployment, $SystemPrompt, $InitialContext)

    $context = $InitialContext
    $searches = 0
    $opens = 0

    while ($true) {
        $response = Invoke-AzureAgent $Deployment $SystemPrompt $context
        Write-DebugLog "$Role-response" $response

        if ($response.TrimStart().StartsWith("diff --git") -or $response -eq "NO_CHANGES") {
            return $response
        }

        $json = $response | ConvertFrom-Json
        if (-not ($TOOL_PERMISSIONS[$Role] -contains $json.tool)) {
            throw "Forbidden tool $($json.tool) for role $Role"
        }

        switch ($json.tool) {
            "search_files" {
                if ($searches++ -ge $MAX_SEARCHES) { continue }
                $results = Search-Files $json.pattern
                Write-DebugLog "$Role-search" ($results -join "`n")
                $context += "`nSEARCH_RESULTS:`n$($results -join "`n")"
            }
            "open_file" {
                if ($opens++ -ge $MAX_OPENS) { continue }
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
        }
    }
}
