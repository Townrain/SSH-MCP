# SSH-MCP

Give any AI agent secure, persistent SSH access to your infrastructure.

[![Go Version](https://img.shields.io/badge/go-1.25+-blue.svg)](https://golang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## The Problem

AI agents are stateless. Every tool call is a fresh execution — no working directory, no connection reuse, no session memory. When an agent needs to debug a production server, it can't `cd` into a directory, run a command, read the output, and then run another command in the same context. Traditional approaches spin up a new SSH connection per command, losing all state.

## The Solution

SSH-MCP sits between AI agents and remote infrastructure as a **persistent SSH session manager** that speaks the [Model Context Protocol](https://modelcontextprotocol.io/). It maintains long-lived SSH connections with working directory tracking, so agents interact with remote servers the same way a human does in a terminal.

```
┌──────────────┐                         ┌──────────────────────────────────┐
│              │    MCP Protocol         │          SSH-MCP Server          │
│   AI Agent   │◄──────────────────────► │                                  │
│              │    stdio / HTTP+SSE     │  ┌────────────────────────────┐  │
│  Claude      │                         │  │       Session Pool         │  │
│  Cursor      │                         │  │                            │  │
│  Any MCP     │                         │  │  Session A ─► SSH Manager  │──┼──► Server 1
│  Client      │                         │  │  Session B ─► SSH Manager  │──┼──► Server 2
│              │                         │  │  Session C ─► SSH Manager  │──┼──► Bastion ─► Server 3
└──────────────┘                         │  └────────────────────────────┘  │
                                         └──────────────────────────────────┘
```

Each session gets its own isolated SSH connection manager. Connections persist across tool calls. Working directories track between commands. Files stream over SFTP. One binary, zero runtime dependencies.

## Quick Start

### Docker (recommended)

```bash
docker run -v ssh-keys:/data -p 8000:8000 firstfinger/ssh-mcp:latest
```

### From Source

```bash
go build -o ssh-mcp ./cmd/server
./ssh-mcp
```

### macOS LaunchAgent (dev)

See [scripts/macos/README.md](scripts/macos/README.md) for persistent background service setup.

Then point your MCP client at the configured endpoint (default `http://127.0.0.1:8000/mcp`).

## Configuration

| Flag | Env | Default | Description |
|------|-----|---------|-------------|
| `-mode` | `SSH_MCP_MODE` | `http` | Transport: `stdio` or `http` |
| `-port` | `PORT` | `8000` | HTTP listen port |
| `-global` | `SSH_MCP_GLOBAL` | `false` | Share one SSH manager across all sessions |

**SSH keys** are auto-generated Ed25519 at first connection:
- Development: `./data/id_ed25519`
- Production (Docker): `/data/id_ed25519` (mount a volume)

## How It Works

### Session Isolation

Every MCP client gets an isolated SSH connection pool. Three modes, depending on deployment:

```
┌─ Session Pool ────────────────────────────────────────────────┐
│                                                               │
│  Per-session (default)                                        │
│  Each MCP session gets a UUIDv7 ID and its own SSH manager    │
│                                                               │
│  Header-based (X-Session-Key)                                 │
│  Sticky routing for load balancers — sessions survive         │
│  MCP reconnects as long as the header stays the same          │
│                                                               │
│  Global (-global flag)                                        │
│  Single shared manager — for single-user / local use          │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

Header-based sessions expire after 5 minutes of inactivity. Per-session pools are destroyed when the MCP session ends.

### Connection Lifecycle

```
connect(host, user)          Creates SSH client, tracks as "primary"
connect(host2, user, alias)  Creates second client with alias
run(command)                 Executes on primary, tracks CWD
run(command, target=alias)   Executes on aliased connection
read/write/edit(path)        SFTP operations on target
disconnect()                 Closes all connections in session
```

Working directory persists across `run` calls — `cd /tmp && pwd` followed by `ls` will list `/tmp`. This is the key difference from stateless execution.

### Jump Host Tunneling

```
Agent ──► SSH-MCP ──► Bastion ──► Internal Server
                      (via)

connect(bastion, admin, alias="jump")
connect(internal-host, admin, via="jump")
```

The second connection tunnels through the first. The agent doesn't need to know about the network topology.

## Tools

43 tools organized by domain. The five **core tools** (`connect`, `disconnect`, `run`, `read`, `write`) are the foundation — everything else is a higher-level wrapper that constructs shell commands and calls the same SSH execution path.

### Core

| Tool | What it does |
|------|-------------|
| `connect` | Open SSH connection (password, key, or auto-generated key) |
| `disconnect` | Close one or all connections |
| `run` | Execute command with CWD tracking and configurable timeout |
| `identity` | Get server's public key for `authorized_keys` |
| `info` | Remote OS, kernel, hostname |

### Files

| Tool | What it does |
|------|-------------|
| `read` | Read file via SFTP (10MB cap) |
| `write` | Write file via SFTP — validates syntax before writing |
| `edit` | Sed-like operations: replace, regex, insert, append, delete |
| `validate` | Server-side syntax check (JSON, YAML, TOML, XML, INI, Dockerfile, ENV) |
| `list_dir` | Directory listing with metadata |
| `sync` | Stream file between two remote hosts |

Validation runs in Go on the MCP server — no `jq`, `python3`, or `xmllint` needed on remote hosts.

### System Monitoring

`usage` `ps` `logs` `journal_read` `dmesg_read` `diagnose_system` `list_services`

### Docker

`docker_ps` `docker_logs` `docker_op` `docker_ip` `docker_find_by_ip` `docker_networks` `docker_cp_from` `docker_cp_to`

### Database

`db_query` `db_schema` `list_db_containers`

### Network & Search

`net_stat` `search_files` `search_text` `package_manage`

### VoIP / SIP / RTP

`voip_discover_containers` `voip_sip_capture` `voip_call_flow` `voip_registrations` `voip_call_stats` `voip_extract_sdp` `voip_packet_check` `voip_network_capture` `voip_rtp_capture` `voip_network_diagnostics`

## Examples

**Connect and run commands:**
```json
{"tool": "connect", "arguments": {"host": "10.0.0.1", "username": "admin"}}
{"tool": "run", "arguments": {"command": "hostname && uptime"}}
{"tool": "read", "arguments": {"path": "/etc/hostname"}}
```

**Jump host:**
```json
{"tool": "connect", "arguments": {"host": "bastion.example.com", "username": "admin", "alias": "bastion"}}
{"tool": "connect", "arguments": {"host": "10.0.0.50", "username": "admin", "via": "bastion"}}
```

**Edit a config file:**
```json
{"tool": "edit", "arguments": {"path": "/etc/nginx/nginx.conf", "old_text": "worker_connections 512", "new_text": "worker_connections 1024"}}
```

**Sync between hosts:**
```json
{"tool": "connect", "arguments": {"host": "server-a", "username": "admin", "alias": "A"}}
{"tool": "connect", "arguments": {"host": "server-b", "username": "admin", "alias": "B"}}
{"tool": "sync", "arguments": {"source_node": "A", "source_path": "/data/dump.sql", "dest_node": "B", "dest_path": "/data/dump.sql"}}
```

## Architecture

```
cmd/server/main.go          Entry point, HTTP/stdio transport, session hooks
internal/ssh/
  ├── pool.go                Session pool — isolation, cleanup, header routing
  ├── manager.go             Per-session connection manager — connect, execute, SFTP
  ├── client.go              SSH client — CWD tracking, output caps, reconnection
  └── keys.go                Ed25519 key generation and loading
internal/tools/
  ├── core.go                connect, disconnect, run, identity, info
  ├── files.go               read, write, edit, validate, list_dir, sync
  ├── monitoring.go          usage, ps, logs, journal, dmesg, diagnose, services
  ├── docker.go              Container management tools
  ├── network.go             net_stat, search, packages
  ├── voip.go                SIP/RTP capture and analysis
  └── utils.go               Shell quoting, sed escaping, input sanitization
```

### Design Decisions

- **POSIX-compliant commands** — all shell commands work on Linux, macOS, and BSD. GNU-specific flags (`sed -i`, `ps --sort`, `/proc/*`) replaced with portable alternatives.
- **Shell quoting everywhere** — all user input goes through `shellQuote()` before reaching a shell. Sed operations use separate escape functions for patterns, literals, and replacements.
- **No path restrictions** — file access follows the SSH user's OS permissions. No artificial sandboxing that breaks real-world DevOps workflows.
- **Server-side validation** — file syntax is validated in Go on the MCP server, not by shelling out to tools on remote hosts.
- **Output caps** — stdout capped at 10MB, stderr at 1MB, file reads at 10MB. Prevents memory exhaustion from runaway commands.
- **Reconnection with backoff** — lost SSH connections auto-reconnect with a 5-second cooldown to avoid hammering a down host.

## Deployment

### Production Checklist

- TLS: run behind a reverse proxy or use HTTPS termination
- Network: restrict access to private network or VPN
- Auth: validate `X-Session-Key` against authorized keys
- Volume: mount persistent storage at `/data` for SSH keys

### Endpoint

```
POST/GET http://host:port/mcp
Header:   X-Session-Key: <your-session-key>
```

### Load Balancing

Use consistent hashing on `X-Session-Key` for sticky routing across multiple instances.

## License

MIT
