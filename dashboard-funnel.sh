#!/usr/bin/env bash
set -Eeuo pipefail

NS="${NS:-kubernetes-dashboard}"
RELEASE_NAME="${RELEASE_NAME:-kubernetes-dashboard}"
SERVICE="${SERVICE:-}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
HTTPS_PORT="${HTTPS_PORT:-443}"
PF_LOG="${PF_LOG:-/tmp/kdash-portforward.log}"
PF_PID="${PF_PID:-/tmp/kdash-portforward.pid}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
DASHBOARD_MANIFEST_URL="${DASHBOARD_MANIFEST_URL:-https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml}"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

sudo_cmd() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup_on_error() {
  echo
  echo "Last known port-forward log:"
  tail -n 80 "${PF_LOG}" 2>/dev/null || true
}
trap cleanup_on_error ERR

install_base_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v ca-certificates >/dev/null 2>&1 || true

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "Installing base dependencies: ${missing[*]}"
    sudo_cmd apt-get update -y
    sudo_cmd apt-get install -y curl ca-certificates
  fi

  need_cmd curl
  need_cmd kubectl
}

install_tailscale_if_missing() {
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale already installed: $(tailscale version 2>/dev/null || true)"
    return 0
  fi

  log "tailscale not found, installing..."
  curl -fsSL https://tailscale.com/install.sh | sudo_cmd sh
  need_cmd tailscale
}

connect_tailscale_if_needed() {
  if tailscale status >/dev/null 2>&1; then
    log "tailscale already connected."
    return 0
  fi

  [[ -n "${TS_AUTHKEY}" ]] || fail "Tailscale is not connected. Export TS_AUTHKEY first."

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
  need_cmd helm
}

dashboard_installed() {
  kubectl get ns "${NS}" >/dev/null 2>&1 || return 1
  kubectl -n "${NS}" get svc >/dev/null 2>&1 || return 1
  return 0
}

install_dashboard_if_missing() {
  if dashboard_installed; then
    log "Kubernetes Dashboard namespace/services already exist."
    return 0
  fi

  log "Trying Helm installation first..."
  if helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ --force-update \
      && helm repo update \
      && helm upgrade --install "${RELEASE_NAME}" kubernetes-dashboard/kubernetes-dashboard \
           --create-namespace --namespace "${NS}"; then
    log "Dashboard installed via Helm."
  else
    log "Helm repo path failed, falling back to manifest install..."
    kubectl apply -f "${DASHBOARD_MANIFEST_URL}"
  fi

  log "Waiting for dashboard resources..."
  for _ in $(seq 1 "${WAIT_SECONDS}"); do
    if kubectl get ns "${NS}" >/dev/null 2>&1 && kubectl -n "${NS}" get svc >/dev/null 2>&1; then
      log "Dashboard resources detected."
      return 0
    fi
    sleep 1
  done

  kubectl get ns || true
  kubectl -n "${NS}" get all || true
  fail "Dashboard installation did not complete in time."
}

detect_dashboard_service() {
  if [[ -n "${SERVICE}" ]] && kubectl -n "${NS}" get svc "${SERVICE}" >/dev/null 2>&1; then
    log "Using provided dashboard service: ${SERVICE}"
    return 0
  fi

  for s in \
    kubernetes-dashboard-kong-proxy \
    kubernetes-dashboard \
    dashboard-kong-proxy
  do
    if kubectl -n "${NS}" get svc "$s" >/dev/null 2>&1; then
      SERVICE="$s"
      log "Detected dashboard service: ${SERVICE}"
      return 0
    fi
  done

  echo "Services found in namespace ${NS}:" >&2
  kubectl -n "${NS}" get svc >&2 || true
  fail "Could not detect a dashboard service automatically."
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
  detect_dashboard_service

  log "Starting port-forward from svc/${SERVICE} to 127.0.0.1:${LOCAL_PORT}"
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

  tail -n 100 "${PF_LOG}" >&2 || true
  fail "Port-forward failed."
}

start_funnel() {
  log "Resetting old funnel config on https port ${HTTPS_PORT}"
  sudo_cmd tailscale funnel --https="${HTTPS_PORT}" off >/dev/null 2>&1 || true

  log "Starting Funnel in background -> https+insecure://127.0.0.1:${LOCAL_PORT}"
  sudo_cmd tailscale funnel --bg --https="${HTTPS_PORT}" "https+insecure://127.0.0.1:${LOCAL_PORT}"
}

show_status() {
  echo
  echo "===== Tailscale status ====="
  tailscale status || true

  echo
  echo "===== Dashboard service ====="
  if kubectl get ns "${NS}" >/dev/null 2>&1; then
    kubectl -n "${NS}" get svc || true
  else
    echo "Namespace ${NS} not found"
  fi

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

  if [[ -n "${SERVICE}" ]]; then
    pkill -f "kubectl .*port-forward .*svc/${SERVICE} ${LOCAL_PORT}:443" >/dev/null 2>&1 || true
  else
    pkill -f "kubectl .*port-forward .* ${LOCAL_PORT}:443" >/dev/null 2>&1 || true
  fi

  log "Done"
}

start_all() {
  install_base_deps
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