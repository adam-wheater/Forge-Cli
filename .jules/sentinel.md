# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-23 - [Incomplete Regex Sanitization for JSON]
**Vulnerability:** The regex used to sanitize error logs failed to handle JSON values containing spaces (e.g., `"api-key": "my secret"`), truncating the redaction and exposing the suffix of the secret.
**Learning:** Regex-based sanitization of structured data (like JSON) is error-prone. It is safer to parse the structure, sanitize specific fields recursively, and re-serialize, falling back to regex only when parsing fails.
**Prevention:** Implemented `Redact-SensitiveData` which attempts `ConvertFrom-Json` first, recurses to redact sensitive keys, and falls back to an improved regex that handles quoted strings with spaces.

## 2024-05-24 - Sibling Directory Traversal in StartsWith Path Checks
**Vulnerability:** A path check using `String.StartsWith` (e.g., `if (-not $path.StartsWith($repoRoot))`) is vulnerable to sibling directory traversal. If the repo root is `/app`, the check will allow writes to sibling directories like `/app-backup/secret.txt` because `/app-backup` starts with `/app`.
**Learning:** Checking that a directory path is a prefix of another using string manipulation is insufficient and leads to unauthorized access to sibling directories outside the intended root.
**Prevention:** Always ensure the prefix directory ends with a directory separator (e.g., `/`) before calling `StartsWith` to force an exact directory match. For example, check if `$path` starts with `/app/` instead of `/app`.
