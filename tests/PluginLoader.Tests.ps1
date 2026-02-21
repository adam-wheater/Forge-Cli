BeforeAll {
    . "$PSScriptRoot/../lib/PluginLoader.ps1"
}

Describe 'PluginLoader' {
    BeforeEach {
        $Global:LoadedPlugins = @()
    }

    Context 'Initialize-Plugins' {
        BeforeAll {
            $TestPluginDir = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            New-Item -Path $TestPluginDir -ItemType Directory -Force | Out-Null
        }

        AfterEach {
            Get-ChildItem -Path $TestPluginDir -Recurse | Remove-Item -Recurse -Force
            $Global:LoadedPlugins = @()
        }

        AfterAll {
            if (Test-Path $TestPluginDir) {
                Remove-Item -Path $TestPluginDir -Recurse -Force
            }
        }

        It 'Warns if plugin directory not found' {
            $nonExistentDir = Join-Path $TestPluginDir "NonExistent"

            # Using Should -Throw is tricky with Write-Warning, Pester usually mocks Write-Warning
            # But let's verify it returns early and doesn't crash
            Initialize-Plugins -PluginDir $nonExistentDir

            $Global:LoadedPlugins.Count | Should -Be 0
        }

        It 'Loads valid plugin' {
            $pluginFile = Join-Path $TestPluginDir "ValidPlugin.ps1"
            $content = @'
$PluginDefinition = @{
    Name        = "TestPlugin"
    Description = "A test plugin"
    Permissions = @("builder")
    Handler     = { return "Success" }
}
'@
            Set-Content -Path $pluginFile -Value $content

            Initialize-Plugins -PluginDir $TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 1
            $Global:LoadedPlugins[0].Name | Should -Be "TestPlugin"
        }

        It 'Skips plugin without PluginDefinition' {
            $pluginFile = Join-Path $TestPluginDir "NoDefPlugin.ps1"
            Set-Content -Path $pluginFile -Value '$x = 1'

            Initialize-Plugins -PluginDir $TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
        }

        It 'Skips plugin missing required fields' {
            $pluginFile = Join-Path $TestPluginDir "BadPlugin.ps1"
            $content = @'
$PluginDefinition = @{
    Name = "BadPlugin"
    # Missing Description, Permissions, Handler
}
'@
            Set-Content -Path $pluginFile -Value $content

            Initialize-Plugins -PluginDir $TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
        }

        It 'Skips plugin with invalid permissions' {
            $pluginFile = Join-Path $TestPluginDir "InvalidPermPlugin.ps1"
            $content = @'
$PluginDefinition = @{
    Name        = "InvalidPermPlugin"
    Description = "Invalid permissions"
    Permissions = @("invalid_role")
    Handler     = { }
}
'@
            Set-Content -Path $pluginFile -Value $content

            Initialize-Plugins -PluginDir $TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
        }

        It 'Skips duplicate plugin' {
            $pluginFile1 = Join-Path $TestPluginDir "Plugin1.ps1"
            $content1 = @'
$PluginDefinition = @{
    Name        = "DuplicatePlugin"
    Description = "Plugin 1"
    Permissions = @("builder")
    Handler     = { }
}
'@
            Set-Content -Path $pluginFile1 -Value $content1

            $pluginFile2 = Join-Path $TestPluginDir "Plugin2.ps1"
            $content2 = @'
$PluginDefinition = @{
    Name        = "DuplicatePlugin"
    Description = "Plugin 2"
    Permissions = @("builder")
    Handler     = { }
}
'@
            Set-Content -Path $pluginFile2 -Value $content2

            Initialize-Plugins -PluginDir $TestPluginDir

            # Should only load one (the first one encountered)
            $Global:LoadedPlugins.Count | Should -Be 1
            $Global:LoadedPlugins[0].Name | Should -Be "DuplicatePlugin"
        }
    }

    Context 'Get-LoadedPlugins' {
        It 'Returns all loaded plugins' {
            $Global:LoadedPlugins = @(
                @{ Name = "P1" },
                @{ Name = "P2" }
            )

            $result = Get-LoadedPlugins
            $result.Count | Should -Be 2
            $result[0].Name | Should -Be "P1"
        }
    }

    Context 'Get-PluginPermissions' {
        It 'Returns correct permissions mapping' {
            $Global:LoadedPlugins = @(
                @{ Name = "P1"; Permissions = @("builder") },
                @{ Name = "P2"; Permissions = @("reviewer", "judge") }
            )

            $result = Get-PluginPermissions
            $result["P1"] | Should -Contain "builder"
            $result["P2"] | Should -Contain "reviewer"
            $result["P2"] | Should -Contain "judge"
        }
    }

    Context 'Invoke-Plugin' {
        It 'Invokes handler successfully' {
            $Global:LoadedPlugins = @(
                @{
                    Name = "TestPlugin"
                    Handler = { return "Invoked" }
                }
            )

            $result = Invoke-Plugin -Name "TestPlugin" -Arguments "" -RepoRoot ""
            $result | Should -Be "Invoked"
        }

        It 'Passes arguments correctly' {
             $Global:LoadedPlugins = @(
                @{
                    Name = "ArgsPlugin"
                    Handler = {
                        param($args, $repo)
                        return "$args:$repo"
                    }
                }
            )

            $result = Invoke-Plugin -Name "ArgsPlugin" -Arguments "myargs" -RepoRoot "myrepo"
            $result | Should -Be "myargs:myrepo"
        }

        It 'Returns null if plugin not found' {
            $Global:LoadedPlugins = @()
            $result = Invoke-Plugin -Name "MissingPlugin" -Arguments "" -RepoRoot ""
            $result | Should -BeNullOrEmpty
        }

        It 'Handles exception in plugin' {
            $Global:LoadedPlugins = @(
                @{
                    Name = "ErrorPlugin"
                    Handler = { throw "Oops" }
                }
            )

            # Should not throw, but return null (and write warning)
            $result = Invoke-Plugin -Name "ErrorPlugin" -Arguments "" -RepoRoot ""
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Register-BuiltinPlugins' {
        It 'Registers builtin plugins' {
            $Global:LoadedPlugins = @()

            # Mock Get-Command to simulate tools missing or present so it runs fast
            # We don't need to actually run the tools, just check registration
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Get-CSharpSymbols' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet-stryker' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Parse-CoberturaReport' }

            Register-BuiltinPlugins

            $names = $Global:LoadedPlugins.Name
            $names | Should -Contain "roslyn-analyser"
            $names | Should -Contain "stryker-runner"
            $names | Should -Contain "coverage-parser"
        }
    }
}
