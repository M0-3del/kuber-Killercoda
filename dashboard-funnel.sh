#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kubernetes-dashboard}"
SERVICE="${SERVICE:-kubernetes-dashboard-kong-proxy}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
HTTPS_PORT="${HTTPS_PORT:-443}"
PF_LOG="${PF_LOG:-/tmp/kdash-portforward.log}"
PF_PID="${PF_PID:-/tmp/kdash-portforward.pid}"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

check_local_backend() {
  curl -kfsS "https://127.0.0.1:${LOCAL_PORT}/" >/dev/null 2>&1
}

start_port_forward() {
  log "Starting port-forward on 127.0.0.1:${LOCAL_PORT}"
  pkill -f "kubectl .*port-forward .*svc/${SERVICE} ${LOCAL_PORT}:443" >/dev/null 2>&1 || true
  sleep 1

  nohup kubectl -n "${NS}" port-forward --address 127.0.0.1 "svc/${SERVICE}" "${LOCAL_PORT}:443" \
    > "${PF_LOG}" 2>&1 &
  echo $! > "${PF_PID}"

  for _ in $(seq 1 60); do
    if check_local_backend; then
      log "Local backend is ready."
      return 0
    fi
    sleep 1
  done

  echo "Port-forward failed. Log:" >&2
  tail -n 100 "${PF_LOG}" >&2 || true
  exit 1
}

start_funnel() {
  log "Resetting old funnel config on https port ${HTTPS_PORT}"
  sudo tailscale funnel --https="${HTTPS_PORT}" off >/dev/null 2>&1 || true

  log "Starting Funnel in background -> https+insecure://127.0.0.1:${LOCAL_PORT}"
  sudo tailscale funnel --bg --https="${HTTPS_PORT}" "https+insecure://127.0.0.1:${LOCAL_PORT}"
}

show_status() {
  echo
  echo "===== Local backend test ====="
  if check_local_backend; then
    echo "OK: https://127.0.0.1:${LOCAL_PORT}"
  else
    echo "FAIL: local backend is not responding"
  fi

  echo
  echo "===== Funnel status ====="
  sudo tailscale funnel status || true

  echo
  echo "===== Port-forward PID ====="
  if [[ -f "${PF_PID}" ]]; then
    cat "${PF_PID}"
  else
    echo "No PID file"
  fi

  echo
  echo "===== Port-forward log tail ====="
  tail -n 30 "${PF_LOG}" 2>/dev/null || true
}

stop_all() {
  log "Stopping Funnel"
  sudo tailscale funnel --https="${HTTPS_PORT}" off >/dev/null 2>&1 || true

  log "Stopping port-forward"
  if [[ -f "${PF_PID}" ]]; then
    kill "$(cat "${PF_PID}")" >/dev/null 2>&1 || true
    rm -f "${PF_PID}"
  fi
  pkill -f "kubectl .*port-forward .*svc/${SERVICE} ${LOCAL_PORT}:443" >/dev/null 2>&1 || true

  log "Done"
}

start_all() {
  need_cmd kubectl
  need_cmd curl
  need_cmd tailscale

  start_port_forward
  start_funnel
  show_status
}

case "${1:-start}" in
  start)
    start_all
    ;;
  status)
    show_status
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    start_all
    ;;
  *)
    echo "Usage: $0 {start|status|stop|restart}"
    exit 1
    ;;
esac