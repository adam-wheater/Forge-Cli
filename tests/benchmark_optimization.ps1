Describe 'Search-Files Performance' {
    BeforeAll {
        . "$PSScriptRoot/../lib/RepoTools.ps1"
    }

    It 'Executes Search-Files efficiently' {
        $start = Get-Date
        Search-Files -Pattern "Service" | Out-Null
        $end = Get-Date
        ($end - $start).TotalMilliseconds | Should -BeLessThan 1000
    }
}
