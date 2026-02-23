#!/usr/bin/env bash

set -euo pipefail

configure_cloud_init() {
  local vmid="$1"
  local vm_storage="$2"
  local ci_user="$3"
  local ssh_pubkey_path="$4"
  local ip_mode="$5"
  local ip_cidr="$6"
  local gateway="$7"
  local dns_server="$8"

  [[ -f "$ssh_pubkey_path" ]] || die "Public Key nicht gefunden: $ssh_pubkey_path"

  local ipconfig="ip=dhcp"
  if [[ "$ip_mode" == "static" ]]; then
    ipconfig="ip=${ip_cidr},gw=${gateway}"
  fi

  qm set "$vmid" --ciuser "$ci_user" >/dev/null
  qm set "$vmid" --sshkeys "$ssh_pubkey_path" >/dev/null
  qm set "$vmid" --ipconfig0 "$ipconfig" >/dev/null

  if [[ -n "$dns_server" ]]; then
    qm set "$vmid" --nameserver "$dns_server" >/dev/null
  fi

  log_info "Cloud-Init konfiguriert für VM $vmid"
}

resolve_vm_ip() {
  local vmid="$1"
  local ip_mode="$2"
  local ip_cidr="$3"

  if [[ "$ip_mode" == "static" ]]; then
    echo "${ip_cidr%%/*}"
    return 0
  fi

  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    local vm_ip
    vm_ip="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
      | jq -r '.[] | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4") | .["ip-address"]' \
      | grep -Ev '^(127\\.|169\\.254\\.)' \
      | head -n1 || true)"

    if [[ -n "$vm_ip" ]]; then
      echo "$vm_ip"
      return 0
    fi

    sleep 3
  done

  die "DHCP-IP konnte nicht automatisch ermittelt werden (qemu-guest-agent nicht bereit)."
}
