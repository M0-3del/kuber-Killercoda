#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kubernetes-dashboard}"
RELEASE_NAME="${RELEASE_NAME:-kubernetes-dashboard}"
SERVICE="${SERVICE:-kubernetes-dashboard-kong-proxy}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
HTTPS_PORT="${HTTPS_PORT:-443}"
PF_LOG="${PF_LOG:-/tmp/kdash-portforward.log}"
PF_PID="${PF_PID:-/tmp/kdash-portforward.pid}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

sudo_cmd() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_pkg_deps_if_needed() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v kubectl >/dev/null 2>&1 || missing+=(kubectl)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "Installing package dependencies: ${missing[*]}"
    sudo_cmd apt-get update -y
    sudo_cmd apt-get install -y curl ca-certificates
  fi

  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl is required in this lab but was not found." >&2
    exit 1
  }
}

install_tailscale_if_missing() {
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale already installed: $(tailscale version 2>/dev/null || true)"
    return 0
  fi

  log "tailscale not found, installing..."
  curl -fsSL https://tailscale.com/install.sh | sudo_cmd sh
}

connect_tailscale_if_needed() {
  if tailscale status >/dev/null 2>&1; then
    log "tailscale already connected."
    return 0
  fi

  if [[ -z "${TS_AUTHKEY}" ]]; then
    echo "Tailscale is not connected. Export TS_AUTHKEY first." >&2
    exit 1
  fi

  log "Connecting to tailscale..."
  sudo_cmd tailscale up --auth-key="${TS_AUTHKEY}"
}

install_helm_if_missing() {
  if command -v helm >/dev/null 2>&1; then
    log "helm already installed: $(helm version --short 2>/dev/null || true)"
    return 0
  fi

  log "helm not found, installing..."
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  sudo_cmd /tmp/get_helm.sh
}

dashboard_installed() {
  kubectl get ns "${NS}" >/dev/null 2>&1 && \
  kubectl -n "${NS}" get svc "${SERVICE}" >/dev/null 2>&1
}

install_dashboard_if_missing() {
  if dashboard_installed; then
    log "Kubernetes Dashboard already installed."
    return 0
  fi

  log "Installing Kubernetes Dashboard..."
  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install "${RELEASE_NAME}" kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace --namespace "${NS}"

  log "Waiting for dashboard service..."
  for _ in $(seq 1 "${WAIT_SECONDS}"); do
    if kubectl -n "${NS}" get svc "${SERVICE}" >/dev/null 2>&1; then
      log "Dashboard service is ready."
      return 0
    fi
    sleep 1
  done

  echo "Dashboard service was not created in time." >&2
  kubectl -n "${NS}" get all || true
  exit 1
}

create_admin_user_if_missing() {
  log "Ensuring admin-user exists..."
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: ${NS}
YAML
}

print_admin_token() {
  log "Admin token:"
  kubectl -n "${NS}" create token admin-user || true
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
  sudo_cmd tailscale funnel --https="${HTTPS_PORT}" off >/dev/null 2>&1 || true

  log "Starting Funnel in background -> https+insecure://127.0.0.1:${LOCAL_PORT}"
  sudo_cmd tailscale funnel --bg --https="${HTTPS_PORT}" "https+insecure://127.0.0.1:${LOCAL_PORT}"
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
  sudo_cmd tailscale funnel status || true

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
  sudo_cmd tailscale funnel --https="${HTTPS_PORT}" off >/dev/null 2>&1 || true

  log "Stopping port-forward"
  if [[ -f "${PF_PID}" ]]; then
    kill "$(cat "${PF_PID}")" >/dev/null 2>&1 || true
    rm -f "${PF_PID}"
  fi
  pkill -f "kubectl .*port-forward .*svc/${SERVICE} ${LOCAL_PORT}:443" >/dev/null 2>&1 || true

  log "Done"
}

start_all() {
  install_pkg_deps_if_needed
  install_tailscale_if_missing
  connect_tailscale_if_needed
  install_helm_if_missing
  install_dashboard_if_missing
  create_admin_user_if_missing
  start_port_forward
  start_funnel
  show_status
  print_admin_token
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
  token)
    print_admin_token
    ;;
  *)
    echo "Usage: $0 {start|status|stop|restart|token}"
    exit 1
    ;;
esac