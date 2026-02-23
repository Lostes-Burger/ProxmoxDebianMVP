#!/usr/bin/env bash

set -euo pipefail

bootstrap_vm() {
  local ip="$1"
  local port="$2"
  local user="$3"
  local key_path="$4"

  [[ -f "$key_path" ]] || die "Private Key nicht gefunden: $key_path"

  local ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
    -i "$key_path"
    -p "$port"
  )

  log_info "Bootstrappe VM (python3 + qemu-guest-agent)"

  local remote_cmd
  remote_cmd="if command -v sudo >/dev/null 2>&1; then SUDO='sudo'; else SUDO=''; fi; \
\$SUDO apt-get update -y; \
\$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-apt qemu-guest-agent; \
\$SUDO systemctl enable --now qemu-guest-agent || true"

  if ! ssh "${ssh_opts[@]}" "${user}@${ip}" "$remote_cmd"; then
    die "Bootstrap der VM fehlgeschlagen."
  fi
}

run_ansible() {
  local ansible_dir="$1"
  local ip="$2"
  local port="$3"
  local user="$4"
  local key_path="$5"
  local selected_apps_csv="$6"

  local work_dir
  work_dir="$(mktemp -d /tmp/proxmox-orchestrator-ansible-XXXX)"

  local inventory_file="$work_dir/inventory.ini"
  cat >"$inventory_file" <<EOT
[targets]
${ip} ansible_user=${user} ansible_ssh_private_key_file=${key_path} ansible_port=${port} ansible_python_interpreter=/usr/bin/python3
EOT

  local vars_file="$work_dir/vars.yml"
  {
    echo "apps_selected:"
    if [[ -n "$selected_apps_csv" ]]; then
      local app
      IFS=',' read -r -a apps_array <<<"$selected_apps_csv"
      for app in "${apps_array[@]}"; do
        [[ -n "$app" ]] && printf '  - %s\n' "$app"
      done
    fi
  } >"$vars_file"

  log_info "Starte Ansible Provisionierung"

  if ! ansible-playbook -i "$inventory_file" "$ansible_dir/site.yml" --extra-vars "@$vars_file"; then
    die "Ansible Provisionierung fehlgeschlagen."
  fi

  log_info "Ansible Provisionierung abgeschlossen"
}
