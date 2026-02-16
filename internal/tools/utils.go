package tools

import (
	"fmt"
	"strings"
)

// shellQuote quotes a string for safe shell use.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	// Simple single-quote escaping
	escaped := strings.ReplaceAll(s, "'", "'\"'\"'")
	return "'" + escaped + "'"
}

// containsString checks if s contains substr.
func containsString(s, substr string) bool {
	return strings.Contains(s, substr)
}

// trimOutput trims whitespace from output.
func trimOutput(s string) string {
	return strings.TrimSpace(s)
}

// sedEscapeLiteral escapes a literal string for use in a sed s/pattern/ context.
// Escapes: / \ & . * [ ] ^ $ and newlines.
func sedEscapeLiteral(s string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`,
		`/`, `\/`,
		`&`, `\&`,
		`.`, `\.`,
		`*`, `\*`,
		`[`, `\[`,
		`]`, `\]`,
		`^`, `\^`,
		`$`, `\$`,
		"\n", `\n`,
	)
	return replacer.Replace(s)
}

// sedEscapePattern escapes a regex pattern for use in sed, only escaping the delimiter.
// The pattern is passed as-is for regex matching, only / and newlines are escaped.
func sedEscapePattern(s string) string {
	replacer := strings.NewReplacer(
		`/`, `\/`,
		"\n", `\n`,
	)
	return replacer.Replace(s)
}

// sedEscapeReplacement escapes a replacement string for sed s//replacement/ context.
// Only escapes: / \ & and newlines (these have special meaning in sed replacements).
func sedEscapeReplacement(s string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`,
		`/`, `\/`,
		`&`, `\&`,
		"\n", `\n`,
	)
	return replacer.Replace(s)
}

// sedEscapeInsertText escapes text for sed i\ or a\ commands.
// Newlines need to be escaped with backslash continuation for multi-line inserts.
func sedEscapeInsertText(s string) string {
	return strings.ReplaceAll(s, "\n", `\n`)
}

// sedInPlace builds a portable sed in-place edit command that works on
// GNU sed (Linux), BSD sed (macOS/FreeBSD), and BusyBox sed (Alpine).
// Uses sed -i.bak + rm for universal portability.
//
// Parameters:
//   - flags: extra sed flags like "-E", or "" for none
//   - expr: the sed expression including single-quote wrapping (e.g., "'s/foo/bar/g'")
//   - path: the raw file path (will be shell-quoted internally)
func sedInPlace(flags, expr, path string) string {
	quotedPath := shellQuote(path)
	quotedBak := shellQuote(path + ".bak")
	if flags != "" {
		flags = " " + flags
	}
	return fmt.Sprintf("sed -i.bak%s %s %s 2>&1 && rm -f %s",
		flags, expr, quotedPath, quotedBak)
}

// sanitizeTsharkValue removes characters that could break tshark display filters.
// Allows alphanumeric, dash, dot, @, underscore, plus, colon, and space.
func sanitizeTsharkValue(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == '-' || r == '.' || r == '@' || r == '_' || r == '+' || r == ':' || r == ' ' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// sanitizeAlphanumeric validates that a string contains only safe characters.
// Allows alphanumeric, dash, dot, and underscore. Used for network interface names,
// grep keywords, and other values embedded inside sh -c strings.
func sanitizeAlphanumeric(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == '-' || r == '.' || r == '_' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// sanitizeShellInnerPath validates a file path used inside sh -c '...' strings.
// Rejects characters that could break out of single-quoted shell context or
// enable command injection. Returns error for unsafe paths.
func sanitizeShellInnerPath(s string) (string, error) {
	if s == "" {
		return "", fmt.Errorf("path cannot be empty")
	}
	for _, r := range s {
		if r == '\'' || r == '`' || r == ';' || r == '&' || r == '|' ||
			r == '$' || r == '!' || r == '\n' || r == '\r' || r < 32 {
			return "", fmt.Errorf("invalid characters in path")
		}
	}
	return s, nil
}
