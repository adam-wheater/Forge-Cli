# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.
## 2024-03-04 - [Directory Traversal in Invoke-WriteFile]
**Vulnerability:** The `Invoke-WriteFile` function used `.StartsWith($repoRoot)` to validate that the requested path to write was within the repository. Because `$repoRoot` might not end in a directory separator, an attacker could write to a sibling directory (e.g., if `$repoRoot` is `C:\repo`, it would allow paths starting with `C:\repo-backup\`).
**Learning:** `StartsWith` string comparisons for path validation are dangerous if the reference path doesn't end with a directory separator. This is a common path traversal pattern.
**Prevention:** Always ensure the reference path ends with `[System.IO.Path]::DirectorySeparatorChar` or `[System.IO.Path]::AltDirectorySeparatorChar` before using `StartsWith()`, or use `.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar)` logic, to securely jail file operations.
