BeforeAll {
    . "$PSScriptRoot/../lib/RepoTools.ps1"
}

Describe 'Search-Files' {
    Context 'With pattern' {
        It 'Returns array of file paths' {
            Mock -CommandName git -MockWith { 'file1.ps1'; 'file2.ps1' }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }
            $result = Search-Files 'ps1'
            $result | Should -Contain 'file1.ps1'
            $result | Should -Contain 'file2.ps1'
        }
    }
}

Describe 'Open-File' {
    Context 'With existing file' {
        It 'Returns file content' {
            Mock -CommandName Test-Path -MockWith { $true }
            Mock -CommandName Get-Content -MockWith { 'line1'; 'line2' }
            Mock -CommandName Mark-Relevant -MockWith { }
            $result = Open-File 'file.ps1' 10
            $result | Should -Be "line1`nline2"
        }
    }
    Context 'With missing file' {
        It 'Returns FILE_NOT_FOUND' {
            Mock -CommandName Test-Path -MockWith { $false }
            $result = Open-File 'nofile.ps1'
            $result | Should -Be 'FILE_NOT_FOUND'
        }
    }
}
