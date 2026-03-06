
## 2024-05-24 - Optimizing Get-ConstructorDependencies
**Learning:** PowerShell pipeline cmdlets (`Select-String`, `Select-Object -Unique`) and array reallocation (`+=`) create significant performance bottlenecks in loops compared to native .NET string methods (`[regex]::Matches`, `.Split()`) and Collections (`HashSet`).
**Action:** Always prefer native .NET methods and `HashSet[string]` with `OrdinalIgnoreCase` over pipeline-heavy cmdlets for data extraction and uniqueness deduplication in hot paths.
