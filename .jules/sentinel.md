# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-23 - [Incomplete Regex Sanitization for JSON]
**Vulnerability:** The regex used to sanitize error logs failed to handle JSON values containing spaces (e.g., `"api-key": "my secret"`), truncating the redaction and exposing the suffix of the secret.
**Learning:** Regex-based sanitization of structured data (like JSON) is error-prone. It is safer to parse the structure, sanitize specific fields recursively, and re-serialize, falling back to regex only when parsing fails.
**Prevention:** Implemented `Redact-SensitiveData` which attempts `ConvertFrom-Json` first, recurses to redact sensitive keys, and falls back to an improved regex that handles quoted strings with spaces.
## 2024-05-24 - [Path Traversal Sibling Directory Vulnerability]
**Vulnerability:** In `Invoke-WriteFile`, the path validation logic used `$fullPath.StartsWith($resolvedRepo)` to check if a file path was inside the repository root. This allowed path traversal to sibling directories. For example, if the repo root is `C:\myrepo` and a path resolves to `C:\myrepo-backup\file.cs`, `StartsWith` evaluates to true, bypassing the check.
**Learning:** Checking for directory containment requires more than just string `StartsWith`. The reference path (repo root) must be guaranteed to end with a directory separator to ensure it matches a full directory segment, not just a partial string prefix.
**Prevention:** Normalize both paths to use consistent directory separators (e.g., forward slashes). Ensure the base directory string ends with a separator before calling `StartsWith` (e.g., `if (-not $normalizedRepo.EndsWith('/')) { $normalizedRepo += '/' }`).
