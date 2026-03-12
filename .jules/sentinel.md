# Sentinel's Journal

## 2024-05-23 - [Weak Regex for JSON Sanitization]
**Vulnerability:** The regex `(?i)(api-key|password|secret|token)\s*[:=]\s*\S+` used to sanitize logs failed to match JSON-formatted secrets like `"api-key": "value"`, potentially leaking sensitive information in error logs.
**Learning:** Simple key-value regexes often miss structured data formats like JSON, especially when quotes and whitespace are involved.
**Prevention:** Use more robust regexes that account for quotes and different separators, or parse the structured data before sanitization if possible.

## 2024-05-23 - [Incomplete Regex Sanitization for JSON]
**Vulnerability:** The regex used to sanitize error logs failed to handle JSON values containing spaces (e.g., `"api-key": "my secret"`), truncating the redaction and exposing the suffix of the secret.
**Learning:** Regex-based sanitization of structured data (like JSON) is error-prone. It is safer to parse the structure, sanitize specific fields recursively, and re-serialize, falling back to regex only when parsing fails.
**Prevention:** Implemented `Redact-SensitiveData` which attempts `ConvertFrom-Json` first, recurses to redact sensitive keys, and falls back to an improved regex that handles quoted strings with spaces.

## 2024-05-23 - [Over-redaction in Regex Sanitization]
**Vulnerability:** The regex used to sanitize unquoted sensitive data in error logs (`[^\s,"']+`) matched everything up to the next space. When a token was embedded in a URL query string (`?token=secret&other=abc`), the regex consumed the `&` and everything after it, destroying adjacent log context and potentially masking important debugging information while only appearing to redact the token.
**Learning:** When redacting unquoted secrets, the termination boundary must account for common inline separators like URL query parameters (`&`) and connection string delimiters (`;`), not just spaces and quotes.
**Prevention:** Expanded the negated character class for unquoted values to include `&` and `;` (`[^\s,"'&;]+`), ensuring the redaction stops precisely at the end of the secret value and preserves the surrounding context.
