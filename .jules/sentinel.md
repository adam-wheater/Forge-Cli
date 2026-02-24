# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-24 - [Authorization Header Redaction Conflict]
**Vulnerability:** A generic key-value redaction regex matched `Authorization: Bearer <token>` as Key=`Authorization` and Value=`Bearer`, causing the scheme to be redacted and the token to be exposed if a previous pattern had already redacted the token to `***`.
**Learning:** Generic key-value patterns must carefully exclude standard headers that use space as a separator (like `Authorization`) to avoid misinterpreting the scheme as the value.
**Prevention:** Use negative lookahead `(?!Authorization\s*:)` in generic patterns to exclude specific headers that require specialized handling.
