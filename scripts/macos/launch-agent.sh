#!/usr/bin/env bash
set -euo pipefail

LABEL="com.sshmcp.server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/com.sshmcp.server.plist.template"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

APP_SUPPORT_DIR="${SSH_MCP_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/ssh-mcp}"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
WORK_DIR="${SSH_MCP_WORK_DIR:-${APP_SUPPORT_DIR}}"
BINARY_PATH="${SSH_MCP_BINARY_PATH:-${APP_SUPPORT_DIR}/bin/ssh-mcp}"
PORT="${PORT:-11760}"
GLOBAL="${SSH_MCP_GLOBAL:-false}"

launch_target() {
  printf "gui/%s/%s" "$(id -u)" "${LABEL}"
}

ensure_dirs() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${APP_SUPPORT_DIR}" "${LOG_DIR}" "${WORK_DIR}" "$(dirname "${BINARY_PATH}")"
}

render_plist() {
  ensure_dirs

  sed \
    -e "s|__LABEL__|${LABEL}|g" \
    -e "s|__BINARY__|${BINARY_PATH}|g" \
    -e "s|__PORT__|${PORT}|g" \
    -e "s|__WORKDIR__|${WORK_DIR}|g" \
    -e "s|__GLOBAL__|${GLOBAL}|g" \
    -e "s|__STDOUT__|${LOG_DIR}/stdout.log|g" \
    -e "s|__STDERR__|${LOG_DIR}/stderr.log|g" \
    "${TEMPLATE_PATH}" > "${PLIST_PATH}"
}

build_binary() {
  ensure_dirs
  (cd "${PROJECT_ROOT}" && go build -o "${BINARY_PATH}" ./cmd/server)
}

is_loaded() {
  launchctl print "$(launch_target)" >/dev/null 2>&1
}

bootstrap_service() {
  launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
  launchctl enable "$(launch_target)"
}

start_service() {
  if ! is_loaded; then
    bootstrap_service
  fi
  launchctl kickstart -k "$(launch_target)"
  echo "Started ${LABEL}"
}

stop_service() {
  launchctl bootout "$(launch_target)" >/dev/null 2>&1 || true
  echo "Stopped ${LABEL}"
}

install_service() {
  echo "Building binary at: ${BINARY_PATH}"
  build_binary

  echo "Generating LaunchAgent plist at: ${PLIST_PATH}"
  render_plist

  stop_service >/dev/null 2>&1 || true
  bootstrap_service
  start_service

  echo "Installed and started ${LABEL}"
  echo "MCP endpoint: http://127.0.0.1:${PORT}/mcp"
  echo "Logs: ${LOG_DIR}/stdout.log and ${LOG_DIR}/stderr.log"
}

update_service() {
  echo "Updating binary and reloading service"
  install_service
}

restart_service() {
  if ! is_loaded; then
    echo "Service is not loaded; installing and starting it"
    install_service
    return
  fi
  launchctl kickstart -k "$(launch_target)"
  echo "Restarted ${LABEL}"
}

status_service() {
  launchctl print "$(launch_target)"
}

logs_service() {
  ensure_dirs
  touch "${LOG_DIR}/stdout.log" "${LOG_DIR}/stderr.log"
  echo "== stdout.log =="
  tail -n 80 "${LOG_DIR}/stdout.log" || true
  echo
  echo "== stderr.log =="
  tail -n 80 "${LOG_DIR}/stderr.log" || true
}

health_service() {
  if ! is_loaded; then
    echo "launchd status: NOT LOADED"
    exit 1
  fi

  local status_code
  status_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${PORT}/mcp" || true)"

  if [[ "${status_code}" == "200" ]]; then
    echo "health: OK (HTTP ${status_code}, SSE endpoint reachable)"
    exit 0
  fi

  echo "health: FAIL (HTTP ${status_code:-n/a})"
  exit 1
}

uninstall_service() {
  stop_service >/dev/null 2>&1 || true
  # Re-enable before removing so next install doesn't hit "disabled" state
  launchctl enable "$(launch_target)" >/dev/null 2>&1 || true
  rm -f "${PLIST_PATH}"
  echo "Removed ${LABEL} and deleted ${PLIST_PATH}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <install|start|stop|restart|status|logs|health|update|uninstall>

Commands:
  install   Build binary, write plist, load service, and start it
  start     Start service (bootstrap if needed)
  stop      Stop service
  restart   Restart running service
  status    Show full launchd status
  logs      Tail stdout/stderr logs
  health    Check launchd + HTTP /mcp endpoint health
  update    Rebuild binary and restart service
  uninstall Stop service and remove plist

Environment overrides:
  PORT                    HTTP port (default: 11760)
  SSH_MCP_APP_SUPPORT_DIR Runtime base dir (default: ~/Library/Application Support/ssh-mcp)
  SSH_MCP_WORK_DIR        Working directory for process (default: APP_SUPPORT_DIR)
  SSH_MCP_BINARY_PATH     Binary location (default: APP_SUPPORT_DIR/bin/ssh-mcp)
  SSH_MCP_GLOBAL          true/false (default: false)
EOF
}

main() {
  local command="${1:-}"

  case "${command}" in
    install)
      install_service
      ;;
    start)
      start_service
      ;;
    stop)
      stop_service
      ;;
    restart)
      restart_service
      ;;
    status)
      status_service
      ;;
    logs)
      logs_service
      ;;
    health)
      health_service
      ;;
    update)
      update_service
      ;;
    uninstall)
      uninstall_service
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
