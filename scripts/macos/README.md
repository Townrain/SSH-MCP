# macOS LaunchAgent Quick Commands

Use a single script:

- `bash scripts/macos/launch-agent.sh install` — build + install + start
- `bash scripts/macos/launch-agent.sh start` — start service
- `bash scripts/macos/launch-agent.sh stop` — stop service
- `bash scripts/macos/launch-agent.sh restart` — restart service
- `bash scripts/macos/launch-agent.sh update` — rebuild binary + restart
- `bash scripts/macos/launch-agent.sh status` — full launchd status
- `bash scripts/macos/launch-agent.sh health` — launchd + HTTP `/mcp` check
- `bash scripts/macos/launch-agent.sh logs` — tail stdout/stderr logs
- `bash scripts/macos/launch-agent.sh uninstall` — remove service plist

Default local port is `8000`.
Set a custom port with env: `PORT=11760 bash scripts/macos/launch-agent.sh install`.

## Quick Analysis / Troubleshooting

- Check process + config: `bash scripts/macos/launch-agent.sh status`
- Check endpoint: `bash scripts/macos/launch-agent.sh health`
- Check runtime logs: `bash scripts/macos/launch-agent.sh logs`

## Storage Locations

- Binary: `~/Library/Application Support/ssh-mcp/bin/ssh-mcp`
- Data + SSH keys: `~/Library/Application Support/ssh-mcp/data/`
- Logs: `~/Library/Application Support/ssh-mcp/logs/stdout.log` and `stderr.log`
- LaunchAgent plist: `~/Library/LaunchAgents/com.sshmcp.server.plist`
