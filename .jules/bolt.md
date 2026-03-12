## $(date +%Y-%m-%d) - Optimize IntegrationTestGen.ps1 Endpoint Parsing
**Learning:** Re-allocating arrays with `+=` inside loops (such as endpoint scanning and DTO parameter tokenization) causes measurable performance degradation in PowerShell due to $O(N^2)$ complexity. Similarly, the `-split` operator is significantly slower than native .NET `.Split()`.
**Action:** Default to `[System.Collections.Generic.List[type]]` for collection building during code generation. Prefer native `.Split()` over the `-split` operator when simple string delimitation is sufficient.
