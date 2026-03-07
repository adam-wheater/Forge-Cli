# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-23 - [Incomplete Regex Sanitization for JSON]
**Vulnerability:** The regex used to sanitize error logs failed to handle JSON values containing spaces (e.g., `"api-key": "my secret"`), truncating the redaction and exposing the suffix of the secret.
**Learning:** Regex-based sanitization of structured data (like JSON) is error-prone. It is safer to parse the structure, sanitize specific fields recursively, and re-serialize, falling back to regex only when parsing fails.
**Prevention:** Implemented `Redact-SensitiveData` which attempts `ConvertFrom-Json` first, recurses to redact sensitive keys, and falls back to an improved regex that handles quoted strings with spaces.

## 2024-05-24 - [Sibling Directory Path Traversal via StartsWith]
**Vulnerability:** In `Invoke-WriteFile`, `String.StartsWith` was used to validate path boundaries: `if (-not $fullPath.StartsWith($resolvedRepo))`. This allowed a malicious path like `/repo-backup/file.cs` to pass if `$resolvedRepo` was `/repo`.
**Learning:** Using `.StartsWith()` for path traversal checks without ensuring the prefix path ends with a directory separator creates a vulnerability to "sibling directory" attacks.
**Prevention:** Normalize paths to a common directory separator (e.g. `/`), and always append a trailing directory separator to the root path before performing a `.StartsWith()` check.
