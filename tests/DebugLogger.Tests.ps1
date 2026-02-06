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
    Context 'Path sanitization' {
        It 'Sanitizes category with path traversal characters' {
            $Global:DebugMode = $true
            $Global:LogRoot = "$PSScriptRoot/tmp-logs"
            if (-not (Test-Path $Global:LogRoot)) { New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null }
            $fileCountBefore = (Get-ChildItem $Global:LogRoot | Measure-Object).Count
            Write-DebugLog '../../../tmp/traversal-test' 'malicious'
            $fileCountAfter = (Get-ChildItem $Global:LogRoot | Measure-Object).Count
            # File should be created inside LogRoot with sanitized name
            ($fileCountAfter - $fileCountBefore) | Should -BeGreaterThan 0
            # Verify the file was created with sanitized characters (dots and slashes replaced)
            $latest = Get-ChildItem $Global:LogRoot | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $latest.Name | Should -Not -Match '\.\.'
        }
        It 'Replaces special characters in category name' {
            $Global:DebugMode = $true
            $Global:LogRoot = "$PSScriptRoot/tmp-logs"
            if (-not (Test-Path $Global:LogRoot)) { New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null }
            Write-DebugLog 'test/../../bad' 'content'
            $latest = Get-ChildItem $Global:LogRoot | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $latest.Name | Should -Match 'test_+bad'
        }
    }
}
