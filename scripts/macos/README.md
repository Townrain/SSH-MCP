# macOS LaunchAgent

Run SSH-MCP as a persistent background service on macOS using `launchd`.

## Install

```bash
bash scripts/macos/launch-agent.sh install
```

This builds the binary, writes the LaunchAgent plist, and starts the service. The MCP endpoint will be available at `http://127.0.0.1:11760/mcp`.

## Commands

| Command | Description |
|---------|-------------|
| `install` | Build binary, write plist, load and start service |
| `start` | Start service (bootstrap if not loaded) |
| `stop` | Stop service |
| `restart` | Restart running service |
| `update` | Rebuild binary and restart service |
| `status` | Full `launchd` status output |
| `health` | Check launchd state + HTTP `/mcp` endpoint |
| `logs` | Tail stdout/stderr logs |
| `uninstall` | Stop service and remove plist |

```bash
bash scripts/macos/launch-agent.sh <command>
```

## Environment Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `11760` | HTTP listen port |
| `SSH_MCP_GLOBAL` | `false` | Share one SSH manager across all sessions |
| `SSH_MCP_APP_SUPPORT_DIR` | `~/Library/Application Support/ssh-mcp` | Runtime base directory |
| `SSH_MCP_WORK_DIR` | Same as `APP_SUPPORT_DIR` | Working directory for the process |
| `SSH_MCP_BINARY_PATH` | `APP_SUPPORT_DIR/bin/ssh-mcp` | Binary install location |

Example with custom port:

```bash
PORT=9000 bash scripts/macos/launch-agent.sh install
```

## File Locations

| What | Path |
|------|------|
| Binary | `~/Library/Application Support/ssh-mcp/bin/ssh-mcp` |
| SSH keys | `~/Library/Application Support/ssh-mcp/data/id_ed25519` |
| Logs (stdout) | `~/Library/Application Support/ssh-mcp/logs/stdout.log` |
| Logs (stderr) | `~/Library/Application Support/ssh-mcp/logs/stderr.log` |
| LaunchAgent plist | `~/Library/LaunchAgents/com.sshmcp.server.plist` |

## Troubleshooting

```bash
# Check if service is loaded and process is running
bash scripts/macos/launch-agent.sh status

# Check if HTTP endpoint responds
bash scripts/macos/launch-agent.sh health

# View recent logs
bash scripts/macos/launch-agent.sh logs
```

If the service fails to start after an uninstall/reinstall, the launchd domain may retain a disabled state. The script handles this automatically by re-enabling before removal.
