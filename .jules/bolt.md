## 2025-03-05 - Get-ConstructorDependencies array concatenation removal
**Learning:** `Select-String` with `AllMatches` wrapping and array concatenation (`+=`) is very slow for high-frequency regex matches in PowerShell. Using string manipulation (`IndexOf`, `-split`) alongside `[System.Collections.Generic.HashSet[string]]` is much faster (e.g. 5x+ speedup) and avoids O(N^2) performance hits from resizing arrays.
**Action:** Prefer `[regex]::Matches` and `HashSet[type]` for collecting unique tokens in frequently accessed parsing functions.
