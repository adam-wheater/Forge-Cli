
## 2025-02-12 - Consolidate Regex and Array Append Optimizations in PowerShell
**Learning:** In PowerShell, using array concatenation (`+=`) within a loop triggers an $O(N^2)$ array reallocation, which severely degrades performance for large iterations (e.g., test file accumulation). Similarly, using multiple sequential `[regex]::Matches` calls for related patterns causes repeated, expensive passes over the entire text body, leading to double counting and compounding execution time.
**Action:** When scanning text for multiple test-related patterns, combine regexes into a single alternation group (e.g., `(PatternA|PatternB)`). When accumulating objects in a loop, replace `+=` array concatenation with a generic `[System.Collections.Generic.List[type]]` to achieve $O(N)$ execution.
