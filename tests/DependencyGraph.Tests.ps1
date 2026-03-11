BeforeAll {
    . $PSScriptRoot/../lib/DependencyGraph.ps1
}

Describe "Get-ProjectDependencies" {
    It "Parses csproj dependencies correctly" {
        $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\Core\Core.csproj" />
    <ProjectReference Include="..\Data\Data.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.1" />
  </ItemGroup>
</Project>
"@
        $path = [System.IO.Path]::Combine((Get-PSDrive TestDrive).Root, "App.csproj")
        Set-Content -Path $path -Value $csprojContent

        $deps = Get-ProjectDependencies -CsprojPath $path

        $deps.ProjectName | Should -Be "App"
        $deps.TargetFramework | Should -Be "net8.0"
        $deps.IsTestProject | Should -Be $false

        $deps.ProjectReferences.Count | Should -Be 2
        $deps.ProjectReferences[0].Name | Should -Be "Core"
        $deps.ProjectReferences[1].Name | Should -Be "Data"

        $deps.PackageReferences.Count | Should -Be 1
        $deps.PackageReferences[0].Name | Should -Be "Newtonsoft.Json"
    }

    It "Detects test projects based on name and packages" {
        $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.4.1" />
  </ItemGroup>
</Project>
"@
        $path = [System.IO.Path]::Combine((Get-PSDrive TestDrive).Root, "App.Tests.csproj")
        Set-Content -Path $path -Value $csprojContent

        $deps = Get-ProjectDependencies -CsprojPath $path
        $deps.IsTestProject | Should -Be $true
    }
}

Describe "Get-SolutionGraph" {
    It "Parses solution and returns dependency graph" {
        $solPath = [System.IO.Path]::Combine((Get-PSDrive TestDrive).Root, "App.sln")
        $solContent = @"
Microsoft Visual Studio Solution File, Format Version 12.00
Project("{GUID}") = "Core", "Core\Core.csproj", "{GUID}"
EndProject
Project("{GUID}") = "App", "App\App.csproj", "{GUID}"
EndProject
"@
        Set-Content -Path $solPath -Value $solContent

        $coreDir = [System.IO.Path]::Combine((Get-PSDrive TestDrive).Root, "Core")
        New-Item -ItemType Directory -Path $coreDir -Force | Out-Null
        $coreProjPath = [System.IO.Path]::Combine($coreDir, "Core.csproj")
        Set-Content -Path $coreProjPath -Value "<Project></Project>"

        $appDir = [System.IO.Path]::Combine((Get-PSDrive TestDrive).Root, "App")
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        $appProjPath = [System.IO.Path]::Combine($appDir, "App.csproj")
        Set-Content -Path $appProjPath -Value "<Project><ItemGroup><ProjectReference Include=`"..\Core\Core.csproj`" /></ItemGroup></Project>"

        $graph = Get-SolutionGraph -SolutionPath $solPath

        $graph.SolutionName | Should -Be "App"
        $graph.Projects.Count | Should -Be 2
        $graph.DependencyEdges.Count | Should -Be 1
        $graph.DependencyEdges[0].From | Should -Be "App"
        $graph.DependencyEdges[0].To | Should -Be "Core"
    }
}
