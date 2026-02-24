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

    echo "modules_selected:"
    if [[ -n "$selected_modules_csv" ]]; then
      local module
      IFS=',' read -r -a modules_array <<<"$selected_modules_csv"
      for module in "${modules_array[@]}"; do
        [[ -n "$module" ]] && printf '  - %s\n' "$module"
      done
    fi

    echo "apps_selected:"
    if [[ -n "$selected_apps_csv" ]]; then
      local app
      IFS=',' read -r -a apps_array <<<"$selected_apps_csv"
      for app in "${apps_array[@]}"; do
        [[ -n "$app" ]] && printf '  - %s\n' "$app"
      done
    fi

    echo "baseline_packages_selected:"
    if [[ -n "$selected_baseline_packages_csv" ]]; then
      local baseline_pkg
      IFS=',' read -r -a baseline_packages_array <<<"$selected_baseline_packages_csv"
      for baseline_pkg in "${baseline_packages_array[@]}"; do
        [[ -n "$baseline_pkg" ]] && printf '  - %s\n' "$baseline_pkg"
      done
    fi

    echo "fail2ban_jails_selected:"
    if [[ -n "$selected_fail2ban_jails_csv" ]]; then
      local jail
      IFS=',' read -r -a fail2ban_jails_array <<<"$selected_fail2ban_jails_csv"
      for jail in "${fail2ban_jails_array[@]}"; do
        [[ -n "$jail" ]] && printf '  - %s\n' "$jail"
      done
    fi

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
