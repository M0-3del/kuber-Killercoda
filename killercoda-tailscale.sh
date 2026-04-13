#!/usr/bin/env bash
set -Eeuo pipefail

TS_AUTHKEY="${1:-${TS_AUTHKEY:-}}"
ROUTE_CIDR="${2:-${ROUTE_CIDR:-}}"
WORKDIR="${WORKDIR:-$HOME/ts-k8s-bootstrap}"

sudo_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1
}

if [[ -z "${TS_AUTHKEY}" ]]; then
  echo "Usage: $0 <TS_AUTHKEY> [ROUTE_CIDR]"
  echo "Example: $0 tskey-auth-xxxxx 172.30.1.2/32"
  exit 1
fi

if ! need kubectl; then
  echo "[-] kubectl is required but not installed."
  exit 1
fi

mkdir -p "$WORKDIR"

if ! need tailscale; then
  echo "[*] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sudo_cmd sh
fi

if [[ -z "${ROUTE_CIDR}" ]]; then
  API_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
  API_HOST="$(printf '%s' "$API_SERVER" | sed -E 's#https?://([^:/]+).*#\1#')"

  if [[ "$API_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ROUTE_CIDR="${API_HOST}/32"
  else
    echo "[-] Could not auto-detect IPv4 API host from kubeconfig: $API_SERVER"
    echo "[*] Pass ROUTE_CIDR manually, e.g.:"
    echo "    $0 \"$TS_AUTHKEY\" 172.30.1.2/32"
    exit 1
  fi
fi

echo "[*] Enabling IP forwarding..."
sudo_cmd mkdir -p /etc/sysctl.d

if ! grep -q '^net.ipv4.ip_forward = 1$' /etc/sysctl.d/99-tailscale.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward = 1' | sudo_cmd tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
fi

if ! grep -q '^net.ipv6.conf.all.forwarding = 1$' /etc/sysctl.d/99-tailscale.conf 2>/dev/null; then
  echo 'net.ipv6.conf.all.forwarding = 1' | sudo_cmd tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
fi

sudo_cmd sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null

echo "[*] Connecting this lab to Tailscale..."
sudo_cmd tailscale up --auth-key="${TS_AUTHKEY}"

echo "[*] Advertising route: ${ROUTE_CIDR}"
sudo_cmd tailscale set --advertise-routes="${ROUTE_CIDR}"

echo "[*] Tailscale status:"
tailscale status || true

echo "[*] Tailscale IPv4:"
tailscale ip -4 || true

echo "[*] Exporting kubeconfig..."
kubectl config view --raw --minify --flatten > "${WORKDIR}/kubeconfig.yaml"

echo "[*] Encoding kubeconfig to base64..."
base64 -w 0 "${WORKDIR}/kubeconfig.yaml" > "${WORKDIR}/kubeconfig.b64"

echo
echo "========================================"
echo "Tailscale + Kubernetes setup complete"
echo "========================================"
echo "ROUTE_CIDR=${ROUTE_CIDR}"
echo "TAILSCALE_IP=$(tailscale ip -4 | head -n1)"
echo "KUBECONFIG_FILE=${WORKDIR}/kubeconfig.yaml"
echo "KUBECONFIG_B64_FILE=${WORKDIR}/kubeconfig.b64"
echo
echo "===== Put this value into GitHub Secret: KUBECONFIG ====="
cat "${WORKDIR}/kubeconfig.b64"
echo
echo "========================================================="
echo "IMPORTANT:"
echo "1) Approve the route ${ROUTE_CIDR} from the Tailscale admin console if it is pending."
echo "2) Put the printed base64 value into GitHub Secret named KUBECONFIG."
echo "3) Do not share kubeconfig.yaml or kubeconfig.b64 publicly."