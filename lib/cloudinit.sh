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
  local ansible_auth_mode="$3"
  local ci_user="$4"
  local ansible_ssh_key_path="$5"
  local ansible_ssh_key_text="$6"
  local ansible_password="$7"
  local root_auth_mode="$8"
  local root_ssh_key_path="$9"
  local root_ssh_key_text="${10}"
  local root_password="${11}"

  [[ -n "$snippets_storage" ]] || die "Kein Storage mit 'snippets' Content gefunden. Bitte auf einem Storage 'snippets' aktivieren."
  if ! storage_has_content_type "$snippets_storage" "snippets"; then
    die "Storage '$snippets_storage' hat keinen Content-Typ 'snippets'."
  fi

  local snippet_volid="${snippets_storage}:snippets/orchestrator-${vmid}-user.yml"
  local snippet_path
  snippet_path="$(pvesm path "$snippet_volid" 2>/dev/null || true)"
  [[ -n "$snippet_path" ]] || die "Snippet-Pfad konnte nicht aufgelöst werden: $snippet_volid"

  local user_block=""
  local root_block=""
  local auth_block=""
  local root_ssh_cfg=""
  local ci_ssh_pwauth="false"

  if [[ "$ansible_auth_mode" == "password" ]]; then
    ci_ssh_pwauth="true"
  fi

  local root_key=""
  case "$root_auth_mode" in
    key_path)
      [[ -s "$root_ssh_key_path" ]] || die "Root Public Key nicht gefunden oder leer: $root_ssh_key_path"
      root_key="$(tr -d '\r\n' <"$root_ssh_key_path")"
      [[ "$root_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || die "Ungültiger Root Public Key in Datei."
      root_block=$(cat <<EOT
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ${root_key}
EOT
)
      root_ssh_cfg="PermitRootLogin prohibit-password"
      ;;
    key_manual)
      root_key="$(printf '%s' "$root_ssh_key_text" | tr -d '\r\n')"
      [[ "$root_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || die "Ungültiger manueller Root Public Key."
      root_block=$(cat <<EOT
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ${root_key}
EOT
)
      root_ssh_cfg="PermitRootLogin prohibit-password"
      ;;
    password)
      [[ -n "$root_password" ]] || die "Root Passwortmodus aktiv, aber kein Root Passwort gesetzt."
      root_block=$(cat <<EOT
  - name: root
    lock_passwd: false
EOT
)
      root_ssh_cfg="PermitRootLogin yes"
      ci_ssh_pwauth="true"
      ;;
    *)
      die "Ungültige Root Auth Auswahl: $root_auth_mode"
      ;;
  esac
  local ansible_ssh_key=""
  case "$ansible_auth_mode" in
    key_path)
      [[ -s "$ansible_ssh_key_path" ]] || die "Public Key nicht gefunden oder leer: $ansible_ssh_key_path"
      ansible_ssh_key="$(tr -d '\r\n' <"$ansible_ssh_key_path")"
      [[ "$ansible_ssh_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || die "Ungültiger Public Key für $ci_user."
      user_block=$(cat <<EOT
  - name: ${ci_user}
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ansible_ssh_key}
EOT
)
      ;;
    key_manual)
      ansible_ssh_key="$(printf '%s' "$ansible_ssh_key_text" | tr -d '\r\n')"
      [[ "$ansible_ssh_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || die "Ungültiger manueller Public Key für $ci_user."
      user_block=$(cat <<EOT
  - name: ${ci_user}
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ansible_ssh_key}
EOT
)
      ;;
    password)
      [[ -n "$ansible_password" ]] || die "Passwortmodus aktiv, aber kein Passwort gesetzt."
      user_block=$(cat <<EOT
  - name: ${ci_user}
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
EOT
)
      ;;
    *)
      die "Ungültige Auth Auswahl für $ci_user: $ansible_auth_mode"
      ;;
  esac

  local chpasswd_block=""
  if [[ "$ansible_auth_mode" == "password" ]]; then
    chpasswd_block+="${ci_user}:${ansible_password}"$'\n'
  fi
  if [[ "$root_auth_mode" == "password" ]]; then
    chpasswd_block+="root:${root_password}"$'\n'
  fi

  if [[ "$ci_ssh_pwauth" == "true" ]]; then
    auth_block="ssh_pwauth: true"
    local ssh_password_auth_value="yes"
  else
    auth_block="ssh_pwauth: false"
    local ssh_password_auth_value="no"
  fi

  mkdir -p "$(dirname "$snippet_path")"
  cat >"$snippet_path" <<EOT
#cloud-config
package_update: true
${auth_block}
disable_root: false
packages:
  - python3
  - python3-apt
  - qemu-guest-agent
write_files:
  - path: /etc/ssh/sshd_config.d/99-root-access.conf
    owner: root:root
    permissions: '0644'
    content: |
      ${root_ssh_cfg}
      PasswordAuthentication ${ssh_password_auth_value}
users:
${root_block}
${user_block}
$(if [[ -n "$chpasswd_block" ]]; then cat <<EOF
chpasswd:
  list: |
$(printf '%s' "$chpasswd_block" | sed 's/^/    /')
  expire: false
EOF
fi)
runcmd:
  - systemctl restart ssh || systemctl restart sshd || true
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
  local ansible_auth_mode="$5"
  local ansible_ssh_key_path="$6"
  local ansible_ssh_key_text="$7"
  local ansible_password="$8"
  local root_auth_mode="$9"
  local root_ssh_key_path="${10}"
  local root_ssh_key_text="${11}"
  local root_password="${12}"
  local ip_mode="${13}"
  local ip_cidr="${14}"
  local gateway="${15}"
  local dns_server="${16}"

  local ipconfig="ip=dhcp"
  if [[ "$ip_mode" == "static" ]]; then
    ipconfig="ip=${ip_cidr},gw=${gateway}"
  fi

  qm set "$vmid" --ipconfig0 "$ipconfig" >/dev/null
  configure_cloud_init_userdata "$vmid" "$snippets_storage" "$ansible_auth_mode" "$ci_user" "$ansible_ssh_key_path" "$ansible_ssh_key_text" "$ansible_password" "$root_auth_mode" "$root_ssh_key_path" "$root_ssh_key_text" "$root_password"

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
      | jq -r '.[] 
        | select(((.name // "") | test("^lo") | not))
        | .["ip-addresses"][]? 
        | select(.["ip-address-type"]=="ipv4") 
        | .["ip-address"]' \
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
