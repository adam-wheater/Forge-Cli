# Bolt's Journal

## 2024-05-31 - Optimized Array Building in TestStyleDetector.ps1
**Learning:** In PowerShell, using `+=` to add elements to an array results in an O(N^2) operation because a new array must be created and the contents copied for every addition. Using a strongly-typed generic List such as `[System.Collections.Generic.List[hashtable]]` changes this to O(N) and can dramatically improve performance for large sets of items. Additionally, consolidating multiple separate `[regex]::Matches` calls for keywords into single alternation pattern regexes (e.g., `\[Fact\]|\[Theory\]|\[InlineData\b`) significantly speeds up analysis, passing over the source string fewer times.
**Action:** When working with collections of unpredictable sizes within loops, use generic Lists and `.Add()` over array concatenation `+=`. Convert back to an array at the end if necessary. In text scanning tasks, combine patterns into alternation regexes to reduce the number of matches run.
