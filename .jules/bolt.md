## 2026-02-23 - PowerShell Regex Overhead
**Learning:** `switch -Regex` in PowerShell introduces significant overhead compared to native .NET string methods (`EndsWith`, `IndexOf`) when scoring thousands of files.
**Action:** Replace `switch -Regex` with `if`/`elseif` blocks using `[System.StringComparison]::OrdinalIgnoreCase` for hot paths (e.g., file loops).
