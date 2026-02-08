$Global:LoadedPlugins = @()

function Initialize-Plugins {
    [CmdletBinding()]
    param (
        [string]$PluginDir = (Join-Path $PSScriptRoot ".." "plugins")
    )

    $Global:LoadedPlugins = @()

    if (-not (Test-Path $PluginDir)) {
        Write-Warning "Plugin directory not found: $PluginDir"
        return
    }

    $pluginFiles = Get-ChildItem -Path $PluginDir -Filter "*.ps1" -File -ErrorAction SilentlyContinue

    if (-not $pluginFiles -or $pluginFiles.Count -eq 0) {
        Write-Host "No plugins found in $PluginDir"
        return
    }

    foreach ($file in $pluginFiles) {
        try {
            # Clear any previous PluginDefinition before loading
            $PluginDefinition = $null

            # Dot-source the plugin file to load its definition
            . $file.FullName

            if (-not $PluginDefinition) {
                Write-Warning "Plugin file '$($file.Name)' does not export `$PluginDefinition — skipping."
                continue
            }

            # Validate required fields
            if (-not $PluginDefinition.Name) {
                Write-Warning "Plugin in '$($file.Name)' missing 'Name' — skipping."
                continue
            }
            if (-not $PluginDefinition.Description) {
                Write-Warning "Plugin '$($PluginDefinition.Name)' missing 'Description' — skipping."
                continue
            }
            if (-not $PluginDefinition.Permissions -or $PluginDefinition.Permissions.Count -eq 0) {
                Write-Warning "Plugin '$($PluginDefinition.Name)' missing 'Permissions' — skipping."
                continue
            }
            if (-not $PluginDefinition.Handler) {
                Write-Warning "Plugin '$($PluginDefinition.Name)' missing 'Handler' — skipping."
                continue
            }

            # Validate permissions are valid roles
            $validRoles = @("builder", "reviewer", "judge")
            foreach ($perm in $PluginDefinition.Permissions) {
                if ($perm -notin $validRoles) {
                    Write-Warning "Plugin '$($PluginDefinition.Name)' has invalid permission '$perm' — must be one of: $($validRoles -join ', '). Skipping."
                    continue
                }
            }

            # Check for duplicate plugin names
            $existing = $Global:LoadedPlugins | Where-Object { $_.Name -eq $PluginDefinition.Name }
            if ($existing) {
                Write-Warning "Duplicate plugin name '$($PluginDefinition.Name)' in '$($file.Name)' — skipping."
                continue
            }

            $Global:LoadedPlugins += @{
                Name        = $PluginDefinition.Name
                Description = $PluginDefinition.Description
                Permissions = $PluginDefinition.Permissions
                Handler     = $PluginDefinition.Handler
                SourceFile  = $file.FullName
            }

            Write-Host "Loaded plugin: $($PluginDefinition.Name) ($($file.Name))"
        } catch {
            Write-Warning "Failed to load plugin '$($file.Name)': $($_.Exception.Message)"
        }
    }

    Write-Host "Loaded $($Global:LoadedPlugins.Count) plugin(s)."
}

function Get-LoadedPlugins {
    [CmdletBinding()]
    param ()
    return $Global:LoadedPlugins
}

function Get-PluginPermissions {
    [CmdletBinding()]
    param ()

    $permissions = @{}

    foreach ($plugin in $Global:LoadedPlugins) {
        $permissions[$plugin.Name] = $plugin.Permissions
    }

    return $permissions
}

function Invoke-Plugin {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $plugin = $Global:LoadedPlugins | Where-Object { $_.Name -eq $Name }

    if (-not $plugin) {
        Write-Warning "Plugin '$Name' not found."
        return $null
    }

    try {
        $result = & $plugin.Handler $Arguments $RepoRoot
        return $result
    } catch {
        Write-Warning "Plugin '$Name' execution failed: $($_.Exception.Message)"
        return $null
    }
}

function Register-BuiltinPlugins {
    [CmdletBinding()]
    param ()

    # Register roslyn-analyser stub
    $roslynPlugin = @{
        Name        = "roslyn-analyser"
        Description = "Runs Roslyn-based code analysis on C# files to extract symbols, call graphs, and diagnostics."
        Permissions = @("builder", "reviewer")
        Handler     = {
            param ($json, $repoRoot)
            try {
                $args = $json | ConvertFrom-Json
                $targetPath = if ($args.path) { $args.path } else { $repoRoot }

                # Delegate to CSharpAnalyser module if available
                if (Get-Command -Name "Get-CSharpSymbols" -ErrorAction SilentlyContinue) {
                    return Get-CSharpSymbols -FilePath $targetPath
                }

                return @{
                    status  = "stub"
                    message = "Roslyn analyser: CSharpAnalyser module not loaded. Provide a .cs file path in arguments."
                    path    = $targetPath
                }
            } catch {
                return @{
                    status = "error"
                    message = "roslyn-analyser failed: $($_.Exception.Message)"
                }
            }
        }
        SourceFile  = "builtin"
    }

    # Register stryker-runner stub
    $strykerPlugin = @{
        Name        = "stryker-runner"
        Description = "Runs Stryker.NET mutation testing on the target project to verify test quality."
        Permissions = @("builder")
        Handler     = {
            param ($json, $repoRoot)
            try {
                $args = $json | ConvertFrom-Json
                $projectPath = if ($args.project) { Join-Path $repoRoot $args.project } else { $repoRoot }

                # Attempt to run dotnet-stryker if available
                $strykerPath = Get-Command "dotnet-stryker" -ErrorAction SilentlyContinue
                if ($strykerPath) {
                    $output = & dotnet-stryker --project $projectPath --output json 2>&1
                    return @{
                        status = "completed"
                        output = $output
                    }
                }

                return @{
                    status  = "stub"
                    message = "Stryker.NET not installed. Run 'dotnet tool install -g dotnet-stryker' to enable mutation testing."
                    project = $projectPath
                }
            } catch {
                return @{
                    status  = "error"
                    message = "stryker-runner failed: $($_.Exception.Message)"
                }
            }
        }
        SourceFile  = "builtin"
    }

    # Register coverage-parser stub
    $coveragePlugin = @{
        Name        = "coverage-parser"
        Description = "Parses Cobertura XML or other code coverage reports and returns structured coverage data."
        Permissions = @("builder", "reviewer")
        Handler     = {
            param ($json, $repoRoot)
            try {
                $args = $json | ConvertFrom-Json
                $reportPath = if ($args.reportPath) { $args.reportPath } else { $null }

                # Delegate to CoverageAnalyser module if available
                if (Get-Command -Name "Parse-CoberturaReport" -ErrorAction SilentlyContinue) {
                    if ($reportPath) {
                        return Parse-CoberturaReport -ReportPath $reportPath
                    }
                }

                # Auto-discover coverage reports
                if (-not $reportPath) {
                    $candidates = Get-ChildItem -Path $repoRoot -Recurse -Filter "coverage.cobertura.xml" -ErrorAction SilentlyContinue
                    if ($candidates -and $candidates.Count -gt 0) {
                        $reportPath = $candidates[0].FullName
                    }
                }

                if ($reportPath -and (Test-Path $reportPath)) {
                    try {
                        [xml]$xml = Get-Content $reportPath -Raw
                        $lineRate = $xml.coverage.'line-rate'
                        $branchRate = $xml.coverage.'branch-rate'
                        return @{
                            status     = "completed"
                            reportPath = $reportPath
                            lineRate   = $lineRate
                            branchRate = $branchRate
                        }
                    } catch {
                        return @{
                            status  = "error"
                            message = "Failed to parse coverage report: $($_.Exception.Message)"
                        }
                    }
                }

                return @{
                    status  = "stub"
                    message = "No coverage report found. Run tests with --collect:'XPlat Code Coverage' first."
                }
            } catch {
                return @{
                    status  = "error"
                    message = "coverage-parser failed: $($_.Exception.Message)"
                }
            }
        }
        SourceFile  = "builtin"
    }

    # Register all builtin plugins
    foreach ($plugin in @($roslynPlugin, $strykerPlugin, $coveragePlugin)) {
        $existing = $Global:LoadedPlugins | Where-Object { $_.Name -eq $plugin.Name }
        if (-not $existing) {
            $Global:LoadedPlugins += $plugin
            Write-Host "Registered builtin plugin: $($plugin.Name)"
        }
    }
}
