## 2024-05-24 - Efficient Array Conversion in PowerShell
**Learning:** In PowerShell, when a method needs to return an array from a collection like `HashSet[T]`, there is no need to manually allocate a generic array and call `.CopyTo()`. You can directly cast the collection to the array type (e.g., `return [string[]]$hashSet`) and PowerShell will automatically unroll and convert it efficiently.
**Action:** Use type casting instead of manual array allocation and `CopyTo` when returning arrays from standard collections.

## 2024-05-24 - Scratchpad Cleanliness
**Learning:** Temporary performance test files (like `test_large.cs` or `test_perf.ps1`) left in the workspace pollute the git commit and cause PR bloat.
**Action:** Always clean up temporary files created for benchmarking before committing.
