# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-24 - [Prefix Matching Vulnerability]
**Vulnerability:** The path validation logic in `Invoke-WriteFile` used `StartsWith` to check if a target path was within the repository root without appending a directory separator. This allowed attackers to write to sibling directories sharing a common prefix (e.g., `/repo` vs `/repo_suffix`).
**Learning:** Path matching is brittle. Standard string prefixes are insufficient for path containment checks because directory names can be partial matches of other directory names.
**Prevention:** Always normalize paths and append a directory separator to the root path before performing containment checks (e.g., check `startsWith("/root/")` instead of `startsWith("/root")`).
