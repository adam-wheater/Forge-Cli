# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.
