#!/usr/bin/env bash

set -euo pipefail

bootstrap_vm() {
  local ip="$1"
  local port="$2"
  local user="$3"
  local auth_mode="$4"
  local key_path="$5"
  local password="$6"

  log_info "Bootstrappe VM (python3 + qemu-guest-agent)"

  local remote_cmd
  remote_cmd="if command -v sudo >/dev/null 2>&1; then SUDO='sudo'; else SUDO=''; fi; \
\$SUDO apt-get update -y; \
\$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-apt qemu-guest-agent; \
\$SUDO systemctl enable --now qemu-guest-agent; \
\$SUDO systemctl is-active --quiet qemu-guest-agent"

  local rc=0
  if [[ "$auth_mode" == "key_path" || "$auth_mode" == "key_manual" ]]; then
    [[ -f "$key_path" ]] || die "Private Key nicht gefunden: $key_path"
    ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=8 \
      -i "$key_path" \
      -p "$port" \
      "${user}@${ip}" "$remote_cmd" || rc=$?
  else
    [[ -n "$password" ]] || die "Passwortmodus aktiv, aber kein Passwort gesetzt."
    sshpass -p "$password" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=8 \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -p "$port" \
      "${user}@${ip}" "$remote_cmd" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    die "Bootstrap der VM fehlgeschlagen (python3/qemu-guest-agent konnte nicht eingerichtet werden)."
  fi

  log_info "qemu-guest-agent ist installiert und aktiv."
}

yaml_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

emit_csv_as_yaml_list() {
  local key="$1"
  local csv="$2"
  local item

  if [[ -z "$csv" ]]; then
    printf "%s: []\n" "$key"
    return 0
  fi

  printf "%s:\n" "$key"
  IFS=',' read -r -a _arr <<<"$csv"
  for item in "${_arr[@]}"; do
    [[ -n "$item" ]] && printf "  - %s\n" "$item"
  done
}

run_ansible() {
  local ansible_dir="$1"
  local ip="$2"
  local port="$3"
  local user="$4"
  local auth_mode="$5"
  local key_path="$6"
  local password="$7"
  local selected_modules_csv="$8"
  local selected_baseline_packages_csv="$9"
  local selected_fail2ban_jails_csv="${10}"
  local selected_apps_csv="${11}"
  local ufw_open_app_ports="${12}"
  local ip_mode="${13}"
  local ip_cidr="${14}"
  local gateway="${15}"
  local dns_server="${16}"

  local work_dir
  work_dir="$(mktemp -d /tmp/proxmox-orchestrator-ansible-XXXX)"

  local inventory_file="$work_dir/inventory.ini"
  cat >"$inventory_file" <<EOT
[targets]
${ip} ansible_user=${user} ansible_port=${port} ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOT

  if [[ "$auth_mode" == "key_path" || "$auth_mode" == "key_manual" ]]; then
    [[ -f "$key_path" ]] || die "Private Key nicht gefunden: $key_path"
    sed -i "2s|\$| ansible_ssh_private_key_file=${key_path}|" "$inventory_file"
  else
    [[ -n "$password" ]] || die "Passwortmodus aktiv, aber kein Passwort gesetzt."
  fi

  local vars_file="$work_dir/vars.yml"
  {
    if [[ "$auth_mode" == "password" ]]; then
      printf "ansible_password: %s\n" "$(yaml_quote "$password")"
    fi

    emit_csv_as_yaml_list "modules_selected" "$selected_modules_csv"
    emit_csv_as_yaml_list "apps_selected" "$selected_apps_csv"
    emit_csv_as_yaml_list "baseline_packages_selected" "$selected_baseline_packages_csv"
    emit_csv_as_yaml_list "fail2ban_jails_selected" "$selected_fail2ban_jails_csv"

    printf "ufw_open_app_ports: %s\n" "$ufw_open_app_ports"
    printf "vm_ip_mode: %s\n" "$(yaml_quote "$ip_mode")"
    printf "vm_ip_cidr: %s\n" "$(yaml_quote "$ip_cidr")"
    printf "vm_gateway: %s\n" "$(yaml_quote "$gateway")"
    printf "vm_dns_server: %s\n" "$(yaml_quote "$dns_server")"
  } >"$vars_file"

  log_info "Starte Ansible Provisionierung"

  if ! ansible-playbook -i "$inventory_file" "$ansible_dir/site.yml" --extra-vars "@$vars_file"; then
    die "Ansible Provisionierung fehlgeschlagen."
  fi

  log_info "Ansible Provisionierung abgeschlossen"
}
