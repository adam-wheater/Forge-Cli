BeforeAll {
    . "$PSScriptRoot/../lib/PluginLoader.ps1"
}

Describe 'PluginLoader' {

    Describe 'Initialize-Plugins' {
        BeforeAll {
            # Create a temporary directory for plugins
            $script:TestPluginDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $script:TestPluginDir -Force | Out-Null
        }

        AfterAll {
            # Clean up temporary directory
            if (Test-Path $script:TestPluginDir) {
                Remove-Item -Path $script:TestPluginDir -Recurse -Force
            }
        }

        BeforeEach {
            # Reset global state
            $Global:LoadedPlugins = @()
        }

        It 'Warns if plugin directory not found' {
            Mock Write-Warning
            $NonExistentDir = Join-Path $script:TestPluginDir "NonExistent"

            Initialize-Plugins -PluginDir $NonExistentDir

            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "Plugin directory not found*" }
        }

        It 'Loads a valid plugin' {
            $pluginContent = @'
$PluginDefinition = @{
    Name        = "TestPlugin"
    Description = "A test plugin"
    Permissions = @("builder")
    Handler     = { "Hello World" }
}
'@
            $pluginPath = Join-Path $script:TestPluginDir "ValidPlugin.ps1"
            $pluginContent | Out-File -FilePath $pluginPath -Encoding utf8

            Initialize-Plugins -PluginDir $script:TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 1
            $Global:LoadedPlugins[0].Name | Should -Be "TestPlugin"

            # Cleanup
            Remove-Item $pluginPath -Force
        }

        It 'Skips plugin without PluginDefinition' {
            Mock Write-Warning
            $pluginContent = '# Just a comment'
            $pluginPath = Join-Path $script:TestPluginDir "NoDefinition.ps1"
            $pluginContent | Out-File -FilePath $pluginPath -Encoding utf8

            Initialize-Plugins -PluginDir $script:TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "*does not export `$PluginDefinition*" }

            # Cleanup
            Remove-Item $pluginPath -Force
        }

        It 'Skips plugin missing required fields' {
            Mock Write-Warning
            # Missing Name
            $pluginContent = @'
$PluginDefinition = @{
    Description = "Missing Name"
    Permissions = @("builder")
    Handler     = { }
}
'@
            $pluginPath = Join-Path $script:TestPluginDir "MissingName.ps1"
            $pluginContent | Out-File -FilePath $pluginPath -Encoding utf8

            Initialize-Plugins -PluginDir $script:TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "*missing 'Name'*" }

            # Cleanup
            Remove-Item $pluginPath -Force
        }

        It 'Skips plugin with invalid permissions' {
            Mock Write-Warning
            $pluginContent = @'
$PluginDefinition = @{
    Name        = "InvalidPerms"
    Description = "Invalid permissions"
    Permissions = @("invalid_role")
    Handler     = { }
}
'@
            $pluginPath = Join-Path $script:TestPluginDir "InvalidPerms.ps1"
            $pluginContent | Out-File -FilePath $pluginPath -Encoding utf8

            Initialize-Plugins -PluginDir $script:TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 0
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "*invalid permission*" }

            # Cleanup
            Remove-Item $pluginPath -Force
        }

        It 'Skips duplicate plugin name' {
            Mock Write-Warning
            $pluginContent1 = @'
$PluginDefinition = @{
    Name        = "DuplicatePlugin"
    Description = "First one"
    Permissions = @("builder")
    Handler     = { }
}
'@
            $pluginContent2 = @'
$PluginDefinition = @{
    Name        = "DuplicatePlugin"
    Description = "Second one"
    Permissions = @("builder")
    Handler     = { }
}
'@
            $pluginPath1 = Join-Path $script:TestPluginDir "Dup1.ps1"
            $pluginContent1 | Out-File -FilePath $pluginPath1 -Encoding utf8

            $pluginPath2 = Join-Path $script:TestPluginDir "Dup2.ps1"
            $pluginContent2 | Out-File -FilePath $pluginPath2 -Encoding utf8

            Initialize-Plugins -PluginDir $script:TestPluginDir

            $Global:LoadedPlugins.Count | Should -Be 1
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "*Duplicate plugin name*" }

            # Cleanup
            Remove-Item $pluginPath1 -Force
            Remove-Item $pluginPath2 -Force
        }
    }

    Describe 'Get-LoadedPlugins' {
        BeforeEach {
            $Global:LoadedPlugins = @()
        }

        It 'Returns all loaded plugins' {
            $Global:LoadedPlugins += @{ Name = "P1" }
            $Global:LoadedPlugins += @{ Name = "P2" }

            $result = Get-LoadedPlugins
            $result.Count | Should -Be 2
            $result[0].Name | Should -Be "P1"
            $result[1].Name | Should -Be "P2"
        }
    }

    Describe 'Get-PluginPermissions' {
        BeforeEach {
            $Global:LoadedPlugins = @()
        }

        It 'Returns correct permissions mapping' {
            $Global:LoadedPlugins += @{ Name = "P1"; Permissions = @("builder") }
            $Global:LoadedPlugins += @{ Name = "P2"; Permissions = @("reviewer", "judge") }

            $perms = Get-PluginPermissions

            $perms["P1"] | Should -Be "builder"
            $perms["P2"] | Should -Contain "reviewer"
            $perms["P2"] | Should -Contain "judge"
        }
    }

    Describe 'Invoke-Plugin' {
        BeforeEach {
            $Global:LoadedPlugins = @()
        }

        It 'Invokes handler successfully' {
            $handler = {
                param($arguments, $root)
                return "Invoked $arguments in $root"
            }
            $Global:LoadedPlugins += @{ Name = "TestPlugin"; Handler = $handler }

            $result = Invoke-Plugin -Name "TestPlugin" -Arguments "args" -RepoRoot "/root"
            $result | Should -Be "Invoked args in /root"
        }

        It 'Passes arguments correctly' {
             $Global:LoadedPlugins += @{
                Name = "ArgsPlugin"
                Handler = {
                    param($arguments, $repo)
                    return "$arguments:$repo"
                }
            }

            $result = Invoke-Plugin -Name "ArgsPlugin" -Arguments "myargs" -RepoRoot "myrepo"
            $result | Should -Be "myargs:myrepo"
        }

        It 'Returns null if plugin not found' {
            Mock Write-Warning
            $result = Invoke-Plugin -Name "NonExistent" -Arguments "" -RepoRoot ""
            $result | Should -BeNullOrEmpty
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "Plugin 'NonExistent' not found." }
        }

        It 'Handles exception in plugin' {
            Mock Write-Warning
            $handler = { throw "Boom" }
            $Global:LoadedPlugins += @{ Name = "ErrorPlugin"; Handler = $handler }

            $result = Invoke-Plugin -Name "ErrorPlugin" -Arguments "" -RepoRoot ""
            $result | Should -BeNullOrEmpty
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like "Plugin 'ErrorPlugin' execution failed: Boom" }
        }
    }

    Describe 'Register-BuiltinPlugins' {
        BeforeEach {
            $Global:LoadedPlugins = @()
        }

        It 'Registers builtin plugins' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Get-CSharpSymbols' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet-stryker' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Parse-CoberturaReport' }

            Register-BuiltinPlugins

            $names = $Global:LoadedPlugins.Name
            $names | Should -Contain "roslyn-analyser"
            $names | Should -Contain "stryker-runner"
            $names | Should -Contain "coverage-parser"
        }

        It 'Does not duplicate plugins' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Get-CSharpSymbols' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'dotnet-stryker' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Parse-CoberturaReport' }

            Register-BuiltinPlugins
            Register-BuiltinPlugins # Call twice

            $roslyn = $Global:LoadedPlugins | Where-Object { $_.Name -eq "roslyn-analyser" }
            $roslyn.Count | Should -Be 1
        }
    }
}
