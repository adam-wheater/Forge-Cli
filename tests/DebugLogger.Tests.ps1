BeforeAll {
    . "$PSScriptRoot/../lib/DebugLogger.ps1"
}

Describe 'Write-DebugLog' {
    Context 'When DebugMode is enabled' {
        It 'Writes log file' {
            $Global:DebugMode = $true
            $Global:LogRoot = "$PSScriptRoot/tmp-logs"
            if (-not (Test-Path $Global:LogRoot)) { New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null }
            $fileCountBefore = (Get-ChildItem $Global:LogRoot | Measure-Object).Count
            Write-DebugLog 'test' 'content'
            $fileCountAfter = (Get-ChildItem $Global:LogRoot | Measure-Object).Count
            ($fileCountAfter - $fileCountBefore) | Should -BeGreaterThan 0
        }
    }
    Context 'When DebugMode is disabled' {
        It 'Does not write log file' {
            $Global:DebugMode = $false
            $Global:LogRoot = "$PSScriptRoot/tmp-logs"
            $fileCountBefore = (Test-Path $Global:LogRoot) ? (Get-ChildItem $Global:LogRoot | Measure-Object).Count : 0
            Write-DebugLog 'test' 'content'
            $fileCountAfter = (Test-Path $Global:LogRoot) ? (Get-ChildItem $Global:LogRoot | Measure-Object).Count : 0
            ($fileCountAfter - $fileCountBefore) | Should -Be 0
        }
    }
}
