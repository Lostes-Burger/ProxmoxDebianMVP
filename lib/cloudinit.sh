#!/usr/bin/env bash

set -euo pipefail

configure_cloud_init_userdata() {
  local vmid="$1"
  local snippets_storage="$2"

  [[ -n "$snippets_storage" ]] || die "Kein Storage mit 'snippets' Content gefunden. Bitte auf einem Storage 'snippets' aktivieren."
  if ! pvesm config "$snippets_storage" 2>/dev/null | awk '/^content /{print $2}' | grep -Eq '(^|,)snippets(,|$)'; then
    die "Storage '$snippets_storage' hat keinen Content-Typ 'snippets'."
  fi

  local snippet_volid="${snippets_storage}:snippets/orchestrator-${vmid}-user.yml"
  local snippet_path
  snippet_path="$(pvesm path "$snippet_volid" 2>/dev/null || true)"
  [[ -n "$snippet_path" ]] || die "Snippet-Pfad konnte nicht aufgelöst werden: $snippet_volid"

  mkdir -p "$(dirname "$snippet_path")"
  cat >"$snippet_path" <<'EOT'
#cloud-config
package_update: true
packages:
  - python3
  - python3-apt
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOT

  qm set "$vmid" --cicustom "user=${snippet_volid}" >/dev/null
  log_info "Cloud-Init User-Data gesetzt: ${snippet_volid}"
}

configure_cloud_init() {
  local vmid="$1"
  local vm_storage="$2"
  local snippets_storage="$3"
  local ci_user="$4"
  local ssh_pubkey_path="$5"
  local ip_mode="$6"
  local ip_cidr="$7"
  local gateway="$8"
  local dns_server="$9"

  [[ -f "$ssh_pubkey_path" ]] || die "Public Key nicht gefunden: $ssh_pubkey_path"

  local ipconfig="ip=dhcp"
  if [[ "$ip_mode" == "static" ]]; then
    ipconfig="ip=${ip_cidr},gw=${gateway}"
  fi

  qm set "$vmid" --ciuser "$ci_user" >/dev/null
  qm set "$vmid" --sshkeys "$ssh_pubkey_path" >/dev/null
  qm set "$vmid" --ipconfig0 "$ipconfig" >/dev/null
  configure_cloud_init_userdata "$vmid" "$snippets_storage"

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

  local deadline=$((SECONDS + 240))
  local attempt=1
  while (( SECONDS < deadline )); do
    log_info "Warte auf DHCP-IP via qemu-guest-agent (VM ${vmid}) - Versuch ${attempt}"
    local vm_ip
    vm_ip="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
      | jq -r '.[] | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4") | .["ip-address"]' \
      | grep -Ev '^(127\\.|169\\.254\\.)' \
      | head -n1 || true)"

    if [[ -n "$vm_ip" ]]; then
      log_info "DHCP-IP gefunden: $vm_ip"
      echo "$vm_ip"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 3
  done

  die "DHCP-IP konnte nicht automatisch via qemu-guest-agent ermittelt werden. Prüfe DHCP/VLAN/Cloud-Init oder nutze statische IP."
}
