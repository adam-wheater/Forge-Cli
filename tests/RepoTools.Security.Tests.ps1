
Describe 'Path Traversal Security' {
    BeforeAll {
        . "$PSScriptRoot/../lib/RepoTools.ps1"
        . "$PSScriptRoot/../lib/Orchestrator.ps1"
    }

    Context 'Test-PathInRepo' {
        BeforeAll {
            $RepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "test_repo_pester"
            if (Test-Path $RepoRoot) { Remove-Item $RepoRoot -Recurse -Force }
            New-Item -ItemType Directory -Path $RepoRoot -Force | Out-Null
        }
        AfterAll {
            if (Test-Path $RepoRoot) { Remove-Item $RepoRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'Returns true for files inside repo' {
            Test-PathInRepo -Path "file.cs" -RepoRoot $RepoRoot | Should -BeTrue
            Test-PathInRepo -Path "dir/file.cs" -RepoRoot $RepoRoot | Should -BeTrue
            Test-PathInRepo -Path (Join-Path $RepoRoot "file.cs") -RepoRoot $RepoRoot | Should -BeTrue
        }

        It 'Returns true for repo root itself' {
            Test-PathInRepo -Path "." -RepoRoot $RepoRoot | Should -BeTrue
            Test-PathInRepo -Path $RepoRoot -RepoRoot $RepoRoot | Should -BeTrue
        }

        It 'Returns false for files outside repo' {
            Test-PathInRepo -Path "../outside.cs" -RepoRoot $RepoRoot | Should -BeFalse

            $outside = Join-Path ([System.IO.Path]::GetTempPath()) "outside.cs"
            Test-PathInRepo -Path $outside -RepoRoot $RepoRoot | Should -BeFalse
        }

        It 'Returns false for prefix matching directories' {
            $suffixDir = "${RepoRoot}_suffix"
            $attackPath = Join-Path $suffixDir "file.cs"

            Test-PathInRepo -Path $attackPath -RepoRoot $RepoRoot | Should -BeFalse

            # Relative path attack
            # If CWD is /tmp, and repo is /tmp/repo
            # ../repo_suffix/file.cs -> /tmp/repo_suffix/file.cs
            # We need to simulate relative path relative to repo?
            # Test-PathInRepo assumes $Path is relative to CWD if relative.
            # But usually CWD IS RepoRoot when running tools.
            # Let's test assuming CWD is RepoRoot

            # But we can't easily change CWD in Pester safely without side effects.
            # However, Test-PathInRepo does:
            # $targetPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $resolvedRepo $Path }
            # So relative paths are resolved against $RepoRoot!
            # So "file.cs" -> $RepoRoot/file.cs

            # So "../repo_suffix/file.cs" -> $RepoRoot/../repo_suffix/file.cs
            # = /tmp/repo/../repo_suffix/file.cs -> /tmp/repo_suffix/file.cs

            $relAttack = "../$(Split-Path $RepoRoot -Leaf)_suffix/file.cs"
            Test-PathInRepo -Path $relAttack -RepoRoot $RepoRoot | Should -BeFalse
        }

        It 'Handles mixed separators correctly' {
            if ($IsWindows) {
                Test-PathInRepo -Path "dir\file.cs" -RepoRoot $RepoRoot | Should -BeTrue
            }
        }
    }
}
