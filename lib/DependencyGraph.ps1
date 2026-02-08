# DependencyGraph.ps1 — Dependency-graph-aware test ordering (I05 + J10)
# Parses .sln and .csproj files to build a dependency graph.
# Determines test ordering based on dependency depth: test leaf
# services first (repositories, validators), then composed services,
# then controllers.

function Get-ProjectDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CsprojPath
    )

    $result = @{
        ProjectReferences = @()
        PackageReferences = @()
        ProjectName       = ""
        TargetFramework   = ""
        IsTestProject     = $false
    }

    if (-not (Test-Path $CsprojPath)) {
        Write-Warning "Get-ProjectDependencies: File '$CsprojPath' not found."
        return $result
    }

    $content = Get-Content $CsprojPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    # Extract project name from file path
    $result.ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($CsprojPath)

    # Extract TargetFramework
    if ($content -match '<TargetFramework>(.*?)</TargetFramework>') {
        $result.TargetFramework = $matches[1]
    }

    # Extract ProjectReference elements
    $projRefPattern = '<ProjectReference\s+Include="([^"]+)"'
    $projRefMatches = [regex]::Matches($content, $projRefPattern)
    foreach ($m in $projRefMatches) {
        $refPath = $m.Groups[1].Value
        # Normalise to forward slashes and extract project name
        $refPath = $refPath -replace '\\', '/'
        $refName = [System.IO.Path]::GetFileNameWithoutExtension($refPath)
        $result.ProjectReferences += @{
            Path = $refPath
            Name = $refName
        }
    }

    # Extract PackageReference elements
    $pkgRefPattern = '<PackageReference\s+Include="([^"]+)"(?:\s+Version="([^"]*)")?'
    $pkgRefMatches = [regex]::Matches($content, $pkgRefPattern)
    foreach ($m in $pkgRefMatches) {
        $pkgName = $m.Groups[1].Value
        $pkgVersion = if ($m.Groups[2].Value) { $m.Groups[2].Value } else { "" }
        $result.PackageReferences += @{
            Name    = $pkgName
            Version = $pkgVersion
        }
    }

    # Detect if this is a test project
    $packageNames = @($result.PackageReferences | ForEach-Object { $_.Name.ToLower() })
    $isTest = $false
    if ($result.ProjectName -match 'Test' -or $result.ProjectName -match '\.Tests$') {
        $isTest = $true
    }
    if ($packageNames -match 'xunit' -or $packageNames -match 'nunit' -or $packageNames -match 'mstest\.testframework' -or $packageNames -match 'microsoft\.net\.test\.sdk') {
        $isTest = $true
    }
    $result.IsTestProject = $isTest

    return $result
}

function Get-SolutionGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionPath
    )

    $result = @{
        Projects        = @()
        TestProjects    = @()
        DependencyEdges = @()
        SolutionName    = ""
    }

    if (-not (Test-Path $SolutionPath)) {
        Write-Warning "Get-SolutionGraph: Solution file '$SolutionPath' not found."
        return $result
    }

    $content = Get-Content $SolutionPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    $result.SolutionName = [System.IO.Path]::GetFileNameWithoutExtension($SolutionPath)
    $solutionDir = Split-Path $SolutionPath -Parent

    # Extract project paths from .sln file
    # Format: Project("{GUID}") = "ProjectName", "relative\path\ProjectName.csproj", "{GUID}"
    $projPattern = 'Project\("[^"]*"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+\.csproj)"'
    $projMatches = [regex]::Matches($content, $projPattern)

    $projectMap = @{}  # Name -> full dependency info

    foreach ($pm in $projMatches) {
        $projName = $pm.Groups[1].Value
        $projRelPath = $pm.Groups[2].Value -replace '\\', '/'
        $projFullPath = Join-Path $solutionDir $projRelPath

        if (-not (Test-Path $projFullPath)) {
            Write-Warning "Get-SolutionGraph: Project file '$projFullPath' not found, skipping."
            continue
        }

        $deps = Get-ProjectDependencies -CsprojPath $projFullPath

        $projectInfo = @{
            Name              = $projName
            Path              = $projFullPath
            RelativePath      = $projRelPath
            TargetFramework   = $deps.TargetFramework
            IsTestProject     = $deps.IsTestProject
            ProjectReferences = $deps.ProjectReferences
            PackageReferences = $deps.PackageReferences
        }

        $projectMap[$projName] = $projectInfo

        if ($deps.IsTestProject) {
            $result.TestProjects += $projectInfo
        }

        $result.Projects += $projectInfo

        # Build dependency edges
        foreach ($ref in $deps.ProjectReferences) {
            $result.DependencyEdges += @{
                From = $projName
                To   = $ref.Name
            }
        }
    }

    return $result
}

function Get-TestOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$SolutionGraph
    )

    if (-not $SolutionGraph.Projects -or $SolutionGraph.Projects.Count -eq 0) {
        return @()
    }

    # Build adjacency list for non-test projects
    $projects = @{}
    foreach ($proj in $SolutionGraph.Projects) {
        if (-not $proj.IsTestProject) {
            $projects[$proj.Name] = @{
                Name         = $proj.Name
                Path         = $proj.Path
                DependsOn    = @($proj.ProjectReferences | ForEach-Object { $_.Name })
                Depth        = -1
            }
        }
    }

    # Calculate dependency depth via BFS (leaves = depth 0)
    # First, find leaf projects (those that depend on nothing within the solution)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($name in @($projects.Keys)) {
            $proj = $projects[$name]
            if ($proj.Depth -ge 0) { continue }

            $deps = @($proj.DependsOn | Where-Object { $projects.ContainsKey($_) })

            if ($deps.Count -eq 0) {
                # Leaf project — no internal dependencies
                $projects[$name].Depth = 0
                $changed = $true
            } else {
                # Check if all dependencies have been assigned depths
                $allResolved = $true
                $maxDepth = 0
                foreach ($dep in $deps) {
                    if ($projects[$dep].Depth -lt 0) {
                        $allResolved = $false
                        break
                    }
                    if ($projects[$dep].Depth -gt $maxDepth) {
                        $maxDepth = $projects[$dep].Depth
                    }
                }
                if ($allResolved) {
                    $projects[$name].Depth = $maxDepth + 1
                    $changed = $true
                }
            }
        }
    }

    # Handle circular dependencies — assign remaining projects max depth + 1
    $maxAssigned = 0
    foreach ($name in $projects.Keys) {
        if ($projects[$name].Depth -gt $maxAssigned) {
            $maxAssigned = $projects[$name].Depth
        }
    }
    foreach ($name in $projects.Keys) {
        if ($projects[$name].Depth -lt 0) {
            Write-Warning "Get-TestOrder: Circular dependency detected for '$name', assigning max depth."
            $projects[$name].Depth = $maxAssigned + 1
        }
    }

    # Map test projects to implementation projects they cover
    $testOrder = @()
    foreach ($testProj in $SolutionGraph.TestProjects) {
        $coveredProjects = @($testProj.ProjectReferences | ForEach-Object { $_.Name })

        # Determine the max depth of covered projects
        $testDepth = 0
        foreach ($covered in $coveredProjects) {
            if ($projects.ContainsKey($covered) -and $projects[$covered].Depth -gt $testDepth) {
                $testDepth = $projects[$covered].Depth
            }
        }

        $testOrder += @{
            TestProject     = $testProj.Name
            TestPath        = $testProj.Path
            CoveredProjects = $coveredProjects
            Priority        = $testDepth
        }
    }

    # Sort: lowest depth first (test leaf services first, then composed, then controllers)
    $sorted = $testOrder | Sort-Object { $_.Priority }

    return @($sorted)
}
