## 2025-05-15 - Array Concatenation Bottlenecks in PowerShell

**Learning:** When building arrays dynamically in PowerShell loops (e.g., parsing `dotnet test` results or code coverage data), using the `+=` operator results in O(N^2) complexity because PowerShell creates a new array and copies all elements on every iteration. This creates noticeable bottlenecks on larger repositories.

**Action:** Replace `$array += $item` with `[System.Collections.Generic.List[T]]::new()` and `$array.Add($item)`. This provides O(1) amortized insertion time and is ~3-4x faster for medium-sized lists (and exponentially faster for large lists).
