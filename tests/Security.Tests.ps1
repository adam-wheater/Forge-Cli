Describe "Security: Path Traversal Prevention" {
    BeforeAll {
        # Source the module under test
        . "$PSScriptRoot/../lib/RepoTools.ps1"
        . "$PSScriptRoot/../lib/Orchestrator.ps1"
    }

    Context "Test-PathInRepo" {
        It "Returns true for path inside repo root" {
            $repoRoot = (Get-Location).Path
            $target = Join-Path $repoRoot "testfile.txt"

            $result = Test-PathInRepo -Path $target -RepoRoot $repoRoot
            $result | Should -Be $true
        }

        It "Returns true for repo root itself" {
            $repoRoot = (Get-Location).Path
            $result = Test-PathInRepo -Path $repoRoot -RepoRoot $repoRoot
            $result | Should -Be $true
        }

        It "Returns false for path outside repo root" {
            $repoRoot = (Get-Location).Path
            # Parent directory
            $target = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".."))

            $result = Test-PathInRepo -Path $target -RepoRoot $repoRoot
            $result | Should -Be $false
        }

        It "Returns false for file in parent directory" {
            $repoRoot = (Get-Location).Path
            $target = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "../outside.txt"))

            $result = Test-PathInRepo -Path $target -RepoRoot $repoRoot
            $result | Should -Be $false
        }

        It "Returns false for path on different drive (Windows) or root (Linux)" {
            $repoRoot = (Get-Location).Path
            if ($IsWindows) {
                $target = "C:\Windows\System32\drivers\etc\hosts"
            } else {
                $target = "/etc/passwd"
            }

            $result = Test-PathInRepo -Path $target -RepoRoot $repoRoot
            $result | Should -Be $false
        }
    }

    Context "Invoke-WriteFile Security" {
        It "Blocks writing outside repo via relative path" {
            $repoRoot = (Get-Location).Path
            # Path = ../evil.cs
            # If we pass RepoRoot = CWD.

            $result = Invoke-WriteFile -Path "../evil.cs" -Content "evil" -RepoRoot $repoRoot
            $result | Should -Match "WRITE_FAILED"
            $result | Should -Match "outside"
        }

        It "Blocks writing if RepoRoot is outside" {
             $repoRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path ".."))
             $result = Invoke-WriteFile -Path "evil.cs" -Content "evil" -RepoRoot $repoRoot
             $result | Should -Match "WRITE_FAILED"
             $result | Should -Match "RepoRoot.*outside"
        }
    }
}
