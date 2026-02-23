#!/usr/bin/env bash

set -euo pipefail

storage_has_content_type() {
  local storage="$1"
  local wanted="$2"

  awk -v s="$storage" -v w="$wanted" '
    BEGIN { found=0 }
    $1 ~ /^(dir|zfspool|lvm|lvmthin|nfs|cifs|rbd|pbs):$/ && $2 == s { in_block=1; next }
    $1 ~ /^(dir|zfspool|lvm|lvmthin|nfs|cifs|rbd|pbs):$/ { in_block=0 }
    in_block && $1 == "content" {
      content=$2
      for (i=3; i<=NF; i++) content=content $i
      gsub(/[[:space:]]/, "", content)
      gsub(/,/, " ", content)
      n=split(content, a, " ")
      for (i=1; i<=n; i++) {
        if (a[i] == w) {
          found=1
          exit
        }
      }
      exit
    }
    END {
      if (found) exit 0
      exit 1
    }
  ' /etc/pve/storage.cfg >/dev/null 2>&1
}

configure_cloud_init_userdata() {
  local vmid="$1"
  local snippets_storage="$2"
  local ssh_auth_mode="$3"

  [[ -n "$snippets_storage" ]] || die "Kein Storage mit 'snippets' Content gefunden. Bitte auf einem Storage 'snippets' aktivieren."
  if ! storage_has_content_type "$snippets_storage" "snippets"; then
    die "Storage '$snippets_storage' hat keinen Content-Typ 'snippets'."
  fi

  local snippet_volid="${snippets_storage}:snippets/orchestrator-${vmid}-user.yml"
  local snippet_path
  snippet_path="$(pvesm path "$snippet_volid" 2>/dev/null || true)"
  [[ -n "$snippet_path" ]] || die "Snippet-Pfad konnte nicht aufgelöst werden: $snippet_volid"

  mkdir -p "$(dirname "$snippet_path")"
  cat >"$snippet_path" <<EOT
#cloud-config
package_update: true
packages:
  - python3
  - python3-apt
  - qemu-guest-agent
$( [[ "$ssh_auth_mode" == "password" ]] && echo "ssh_pwauth: true" )
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
  local ssh_auth_mode="$5"
  local ssh_pubkey_path="$6"
  local ci_password="$7"
  local ip_mode="$8"
  local ip_cidr="$9"
  local gateway="${10}"
  local dns_server="${11}"

  local ipconfig="ip=dhcp"
  if [[ "$ip_mode" == "static" ]]; then
    ipconfig="ip=${ip_cidr},gw=${gateway}"
  fi

  qm set "$vmid" --ciuser "$ci_user" >/dev/null
  if [[ "$ssh_auth_mode" == "key" ]]; then
    [[ -s "$ssh_pubkey_path" ]] || die "Public Key nicht gefunden oder leer: $ssh_pubkey_path"
    qm set "$vmid" --sshkeys "$ssh_pubkey_path" >/dev/null
  else
    [[ -n "$ci_password" ]] || die "Passwortmodus aktiv, aber kein Passwort gesetzt."
    qm set "$vmid" --cipassword "$ci_password" >/dev/null
  fi
  qm set "$vmid" --ipconfig0 "$ipconfig" >/dev/null
  configure_cloud_init_userdata "$vmid" "$snippets_storage" "$ssh_auth_mode"

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
      | sed 's/[[:space:]]//g' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | grep -Ev '^(127\\.|169\\.254\\.|0\\.|255\\.)' \
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
