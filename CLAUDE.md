# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
go build -o ssh-mcp ./cmd/server    # build
go vet ./...                         # lint
./ssh-mcp                            # HTTP mode on :8000
./ssh-mcp -mode stdio                # stdio mode
./ssh-mcp -global                    # single shared session
docker build -t ssh-mcp .            # container build
```

No tests exist yet. CI (`.github/workflows/workflow.yaml`) builds and pushes Docker images only.

**Configuration**: flags > env vars > defaults.

| Flag | Env | Default |
|------|-----|---------|
| `-mode` | `SSH_MCP_MODE` | `http` |
| `-port` | `PORT` | `8000` |
| `-global` | `SSH_MCP_GLOBAL` | `false` |

**Module**: `ssh-mcp`, Go 1.25+. Key deps: `mcp-go` (MCP protocol), `golang.org/x/crypto` (SSH), `pkg/sftp` (SFTP), `BurntSushi/toml` + `yaml.v3` (validation).

---

## Architecture

```
MCP Client ──► cmd/server/main.go (HTTP/stdio, session hooks, graceful shutdown)
                      │
                      ▼
               internal/ssh/pool.go (session isolation, 3 modes, cleanup goroutine)
                      │
                      ▼
               internal/ssh/manager.go (per-session connection manager, reconnect, SFTP)
                      │
                      ▼
               internal/ssh/client.go (SSH exec with CWD tracking, output caps)
                      │
                      ▼
               Remote Hosts (via SSH/SFTP, optional jump host tunneling)
```

### Session Pool (pool.go)

Three isolation modes:

1. **Per-session** (default) — one `Manager` per MCP session ID (UUIDv7). Created/destroyed by session hooks in main.go.
2. **Header-based** — keyed by `X-Session-Key` header. Survives MCP reconnects. 5-minute idle timeout. Cleanup goroutine reaps every 60s with two-pass strategy (RLock to identify, Lock to delete, Close outside lock).
3. **Global** (`-global`) — single shared Manager. No cleanup goroutine.

Pool.Close() is safe to call multiple times (select on channel prevents double-close panic). Waits for cleanup goroutine via `cleanupDone sync.WaitGroup` before closing managers.

### Manager (manager.go)

Each Manager holds multiple SSH clients keyed by alias. Key behaviors:

- **Per-alias mutex** — serializes SSH operations on same connection via `aliasLocks map[string]*sync.Mutex`
- **Reconnect backoff** — `reconnectFails map[string]time.Time`, 5-second cooldown per alias. Cleared on success, recorded on failure.
- **Docker cache** — `dockerCache map[string]*bool`, lazily populated, cleared on disconnect
- **Connection reservation** — `Connect()` stores nil in map to reserve alias, replaces with client on success, deletes on failure
- **Path resolution** — `resolvePath()` joins relative paths with client CWD. No artificial restrictions, OS permissions are the boundary.
- **Output truncation** — `Execute()` truncates at 50KB with `"... [Output truncated]"` marker
- **ReadFile cap** — rejects files >10MB via `file.Stat()` before `io.ReadAll`
- **isConnectionError()** — uses `errors.Is(err, io.EOF)` and `errors.As(err, &net.OpError{})` plus string matching for reset/broken pipe/refused

Cleanup: `Disconnect()` and `Close()` clear `aliasLocks`, `reconnectFails`, `dockerCache`.

### Client (client.go)

Wraps `golang.org/x/crypto/ssh` + `pkg/sftp`.

**CWD tracking** — each `Run()` wraps the command:
```
cd '<cwd>' && <cmd>; __EXIT__=$?; echo ""; echo "<delimiter>"; pwd; exit $__EXIT__
```
Delimiter is parsed from stdout to extract new CWD. Exit code preserved.

**Output caps** — `io.LimitReader`: stdout 10MB, stderr 1MB.

**Context cancellation** — on timeout: SIGKILL → session.Close() (unblocks io.ReadAll) → drain resultChan with 2s timeout. Prevents goroutine leaks.

**SFTP invalidation** — `connect()` closes stale SFTP client (`c.sftp.Close(); c.sftp = nil`) before closing SSH connection. SFTP is lazy-initialized on first use.

**Auth order**: private key → password → system-generated Ed25519 key.

### Keys (keys.go)

- Production: `/data/id_ed25519` (Docker, fails if `/data` doesn't exist)
- Development: `./data/id_ed25519` (auto-creates directory)
- Ed25519, OpenSSH PEM format, private key 0600, public key 0644

---

## Tools Layer

Registered in `registry.go` via `RegisterAll()`. Each file exports `register*Tools(s, pool)`.

| File | Tools |
|------|-------|
| `core.go` | connect, disconnect, run, identity, info |
| `files.go` | read, write, edit, validate, list_dir, sync |
| `validate.go` | Server-side syntax validators (JSON, YAML, TOML, XML, INI, ENV, Dockerfile) |
| `docker.go` | docker_ps, docker_logs, docker_op, docker_ip, docker_find_by_ip, docker_networks, docker_cp_from, docker_cp_to |
| `monitoring.go` | usage, ps, logs, journal_read, dmesg_read, diagnose_system, list_services |
| `network.go` | net_stat, search_files, search_text, package_manage |
| `db.go` | db_query, db_schema, list_db_containers |
| `voip.go` | 10 VoIP/SIP/RTP tools |
| `utils.go` | Shell quoting, sed escaping, input sanitization helpers |

### Handler Pattern

Every tool handler follows this structure:

```go
mgr := getManager(ctx, pool)   // checks X-Session-Key header first, then MCP session ID
if mgr == nil {
    return mcp.NewToolResultError("No active session"), nil
}
// ... extract params, call mgr.Execute() or mgr.ReadFile()/WriteFile()
```

Errors return `mcp.NewToolResultError(msg)`, never panic. Success returns `mcp.NewToolResultText(output)`.

### Edit Tool (files.go)

7 operations, all use `sedInPlace()` from utils.go:

| Operation | Sed escaping used |
|-----------|-------------------|
| `replace` | `sedEscapeLiteral(oldText)` + `sedEscapeReplacement(newText)` |
| `regex` | `sedEscapePattern(pattern)` + `sedEscapeReplacement(replacement)`, `-E` flag |
| `insert` | `sedEscapeInsertText(content)`, line number addressing |
| `append` | `sedEscapePattern(pattern)` + `sedEscapeInsertText(content)`, or `printf >> file` if no pattern |
| `prepend` | Same as append but with `i\` instead of `a\` |
| `delete` | `sedEscapePattern(pattern)` or line range |
| `replace_line` | `sedEscapePattern(pattern)` + `sedEscapeReplacement(replacement)`, `-E` flag |

`write` and `edit` run server-side validation before/after unless `skip_validate=true`.

---

## Safety & Security Patterns

### Shell Quoting (CRITICAL)

**Every** user-provided string that enters a shell command MUST go through one of these:

| Function | Use case | Allowed through |
|----------|----------|-----------------|
| `shellQuote(s)` | File paths, container names, any value in outer shell context | Everything (single-quote escaped) |
| `sanitizeAlphanumeric(s)` | Network interface names, grep keywords | `[a-zA-Z0-9._-]` |
| `sanitizeShellInnerPath(s)` | File paths inside `sh -c '...'` strings | Rejects `' \` ; & \| $ ! \n` and control chars |
| `sanitizeTsharkValue(s)` | tshark display filter values (Call-ID, phone) | `[a-zA-Z0-9._@+:- ]` |
| `strconv.Atoi()` + range check | Port numbers, numeric params | Integers only |

**When to use which**:
- Outer shell context (e.g., `docker exec %s`, `cat %s`): `shellQuote()`
- Inside `sh -c '...'` single-quoted strings: `sanitizeShellInnerPath()` for paths, `sanitizeAlphanumeric()` for names
- tshark `-Y` filters: `sanitizeTsharkValue()`
- Numeric values embedded in commands: validate with `strconv.Atoi()`

### Sed Portability (POSIX)

`sedInPlace(flags, expr, path)` builds: `sed -i.bak <flags> <expr> '<path>' && rm -f '<path>.bak'`

Why: `sed -i` differs between GNU (no suffix), BSD (requires suffix), BusyBox. The `.bak + rm` pattern works on all three.

Four separate escape functions exist because sed has different special characters in different contexts:
- `sedEscapeLiteral` — pattern side of `s/pat/repl/`: escapes `\ / & . * [ ] ^ $ \n`
- `sedEscapePattern` — regex pattern: escapes only `/ \n` (delimiter)
- `sedEscapeReplacement` — replacement side: escapes `\ / & \n`
- `sedEscapeInsertText` — `i\` and `a\` commands: escapes `\n`

### POSIX Compliance

All shell commands target Linux, macOS, and BSD. Specific portability patterns:

- `ps -eo ... | awk 'NR==1{print} NR>1{print | "sort -k3 -rn"}'` — replaces GNU `ps --sort` (preserves header)
- `uptime | awk -F'load average[s]?: '` — replaces `cat /proc/loadavg` (handles both Linux "load average:" and macOS "load averages:")
- `nproc || sysctl -n hw.ncpu || getconf _NPROCESSORS_ONLN || echo 1` — CPU count cascade
- `free -h || top -l 1 -s 0 | grep -i phys || cat /proc/meminfo` — memory cascade
- `awk '{if ($1 > $2 * 2) exit 0; else exit 1}'` — replaces `bc` for float comparison
- `netstat -an | grep -i listen` — replaces Linux-only `netstat -tlnp` flags
- `if command -v systemctl; ... elif command -v launchctl; ... elif [ -x /usr/sbin/service ]; ...` — init system detection
- `cat /var/log/syslog /var/log/messages /var/log/system.log 2>/dev/null` — syslog path cascade (Linux + macOS)

### Memory Safety

| Layer | Cap | Mechanism |
|-------|-----|-----------|
| Command stdout | 10MB | `io.LimitReader` in client.go |
| Command stderr | 1MB | `io.LimitReader` in client.go |
| Tool output | 50KB | String truncation in manager.go `Execute()` |
| File read (SFTP) | 10MB | `file.Stat()` check in manager.go `ReadFile()` |

### Graceful Shutdown (main.go)

```
SIGTERM/SIGINT received
  → httpServer.Shutdown(10s deadline)     // drain in-flight requests
  → sessionMgr.Close()                    // stop UUIDv7 cleanup goroutine
  → pool.Close()                          // wait for cleanup goroutine, close all managers
  → exit
```

### Connection Error Handling

`isConnectionError(err)` checks: `io.EOF` (via `errors.Is`), `*net.OpError` (via `errors.As`), plus string match for "connection reset", "broken pipe", "connection refused", "use of closed network connection".

On connection error during `Run()`: check backoff → reconnect → clear backoff → retry command. On reconnect failure: record timestamp, return error.

---

## Anti-patterns to Avoid

1. **Never** `fmt.Sprintf("cmd %s", userInput)` without `shellQuote(userInput)` — command injection
2. **Never** use `sed -i 'expr' file` directly — breaks on BSD. Always use `sedInPlace()`
3. **Never** mix up sed escape functions — `sedEscapeLiteral` for literal text, `sedEscapePattern` for regex, `sedEscapeReplacement` for replacement side
4. **Never** read files without size check — always go through `manager.ReadFile()` which enforces the 10MB cap
5. **Never** reuse SFTP client reference after reconnect — it's invalidated. Call `client.SFTP()` again
6. **Never** add `log.Printf` for per-tool-call logging — logs are kept to lifecycle events only (session start/end, connections, shutdown)
7. **Never** add GNU-only flags to shell commands — must work on Linux + macOS + BSD
8. **Never** embed user-provided paths in `sh -c '...'` without `sanitizeShellInnerPath()` validation
