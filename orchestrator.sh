#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/proxmox.sh
source "$SCRIPT_DIR/lib/proxmox.sh"
# shellcheck source=lib/cloudinit.sh
source "$SCRIPT_DIR/lib/cloudinit.sh"
# shellcheck source=lib/ansible.sh
source "$SCRIPT_DIR/lib/ansible.sh"

main() {
  init_logging
  require_root
  check_dependencies

  print_header

  local config_file
  config_file="$(mktemp /tmp/proxmox-orchestrator-config-XXXX.env)"
  trap '[[ -n "${config_file:-}" ]] && rm -f "$config_file"' EXIT

  collect_wizard_config "$config_file"
  # shellcheck disable=SC1090
  source "$config_file"

  log_info "Nutze lokale Rollen unter ansible/roles/apps"

  local image_path
  image_path="$(ensure_debian13_image)"

  create_vm \
    "$VMID" "$VM_NAME" "$VM_CORES" "$VM_RAM" "$VM_DISK_GB" "$VM_STORAGE" "$VM_BRIDGE" "$VLAN_TAG" "$image_path"

  configure_cloud_init \
    "$VMID" "$VM_STORAGE" "$SNIPPETS_STORAGE" "$CI_USER" "$ANSIBLE_AUTH_MODE" "$ANSIBLE_SSH_KEY_PATH" "$ANSIBLE_SSH_KEY_TEXT" "$ANSIBLE_PASSWORD" "$ROOT_AUTH_MODE" "$ROOT_SSH_KEY_PATH" "$ROOT_SSH_KEY_TEXT" "$ROOT_PASSWORD" "$IP_MODE" "$IP_CIDR" "$GATEWAY" "$DNS_SERVER"

  start_vm "$VMID"

  local target_ip
  target_ip="$(resolve_vm_ip "$VMID" "$IP_MODE" "$IP_CIDR")"
  wait_for_ssh "$target_ip" "$SSH_PORT" 300 3 "$CI_USER" "$ANSIBLE_AUTH_MODE" "$ANSIBLE_PRIVATE_KEY_PATH" "$ANSIBLE_PASSWORD"

  bootstrap_vm "$target_ip" "$SSH_PORT" "$CI_USER" "$ANSIBLE_AUTH_MODE" "$ANSIBLE_PRIVATE_KEY_PATH" "$ANSIBLE_PASSWORD"

  run_ansible "$SCRIPT_DIR/ansible" "$target_ip" "$SSH_PORT" "$CI_USER" "$ANSIBLE_AUTH_MODE" "$ANSIBLE_PRIVATE_KEY_PATH" "$ANSIBLE_PASSWORD" "$SELECTED_MODULES" "$SELECTED_APPS"

  whiptail --title "Fertig" --msgbox "Provisionierung abgeschlossen.\n\nVM: ${VM_NAME} (${VMID})\nIP: ${target_ip}" 12 70
  log_info "Provisionierung erfolgreich abgeschlossen"
}

main "$@"
