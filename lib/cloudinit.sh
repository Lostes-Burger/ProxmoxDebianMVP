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

  local deadline=$((SECONDS + 15))
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

  log_error "DHCP-IP konnte nicht automatisch via qemu-guest-agent ermittelt werden."

  local manual_ip
  if ! manual_ip="$(whiptail --inputbox "Bitte DHCP-IP der VM manuell eingeben (QGA wird danach verpflichtend installiert)." 12 80 "" 3>&1 1>&2 2>&3)"; then
    die "Keine DHCP-IP verfügbar und manuelle Eingabe abgebrochen."
  fi

  [[ -n "$manual_ip" ]] || die "Manuelle DHCP-IP darf nicht leer sein."
  echo "$manual_ip"
}
