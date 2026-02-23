#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="/var/log/proxmox-orchestrator.log"

init_logging() {
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/proxmox-orchestrator.log"
    touch "$LOG_FILE"
  fi
}

log_info() {
  local msg="$1"
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE" >/dev/null
}

log_error() {
  local msg="$1"
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE" >&2
}

die() {
  local msg="$1"
  log_error "$msg"
  whiptail --title "Fehler" --msgbox "$msg\n\nSiehe Log: $LOG_FILE" 12 78 || true
  exit 1
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Bitte als root auf dem Proxmox-Host ausführen."
  fi
}

check_dependencies() {
  local deps=(whiptail qm pvesm curl git jq ansible-playbook ssh nc ping)
  local missing=()
  local dep

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Fehlende Abhängigkeiten: ${missing[*]}\nBitte installieren und erneut starten."
  fi
}

print_header() {
  whiptail --title "Proxmox Debian VM Orchestrator" --msgbox \
    "Interaktiver Setup-Assistent\n\nDieser Wizard erstellt eine Debian-13-VM und installiert ausgewählte Apps per Ansible." \
    13 78
}

next_vmid_default() {
  local max_id
  max_id="$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -n1)"
  if [[ -z "$max_id" ]]; then
    echo "100"
  else
    echo $((max_id + 1))
  fi
}

choose_ip_mode() {
  whiptail --title "Netzwerk" --radiolist "IP-Konfiguration wählen" 15 70 2 \
    "dhcp" "DHCP" ON \
    "static" "Statische IP" OFF \
    3>&1 1>&2 2>&3
}

choose_apps() {
  local selection
  selection="$(whiptail --title "Apps" --checklist "Wähle Apps für die Installation" 15 75 5 \
    "docker" "Docker Engine + Compose Plugin" OFF \
    "nginx" "Nginx Webserver" OFF \
    3>&1 1>&2 2>&3)"

  selection="${selection//\"/}"
  selection="${selection// /,}"
  echo "$selection"
}

collect_wizard_config() {
  local output_file="$1"

  local vmid
  vmid="$(whiptail --inputbox "VM ID" 10 60 "$(next_vmid_default)" 3>&1 1>&2 2>&3)"
  [[ -n "$vmid" ]] || die "VM ID darf nicht leer sein."

  local vm_name
  vm_name="$(whiptail --inputbox "VM Name" 10 60 "debian13-vm-${vmid}" 3>&1 1>&2 2>&3)"

  local vm_cores
  vm_cores="$(whiptail --inputbox "vCPU Kerne" 10 60 "2" 3>&1 1>&2 2>&3)"

  local vm_ram
  vm_ram="$(whiptail --inputbox "RAM in MB" 10 60 "2048" 3>&1 1>&2 2>&3)"

  local vm_disk
  vm_disk="$(whiptail --inputbox "Disk in GB" 10 60 "20" 3>&1 1>&2 2>&3)"

  local vm_storage
  vm_storage="$(whiptail --inputbox "Proxmox Storage Name" 10 60 "local-lvm" 3>&1 1>&2 2>&3)"

  local image_storage
  image_storage="$(whiptail --inputbox "Storage für Debian Cloud Image" 10 60 "local" 3>&1 1>&2 2>&3)"

  local vm_bridge
  vm_bridge="$(whiptail --inputbox "Bridge Interface (z.B. vmbr0)" 10 60 "vmbr0" 3>&1 1>&2 2>&3)"

  local ip_mode
  ip_mode="$(choose_ip_mode)"

  local ip_cidr=""
  local gateway=""
  local dns_server=""
  if [[ "$ip_mode" == "static" ]]; then
    ip_cidr="$(whiptail --inputbox "Statische IP mit CIDR (z.B. 192.168.1.50/24)" 10 70 "" 3>&1 1>&2 2>&3)"
    gateway="$(whiptail --inputbox "Gateway (z.B. 192.168.1.1)" 10 70 "" 3>&1 1>&2 2>&3)"
    dns_server="$(whiptail --inputbox "DNS Server" 10 70 "1.1.1.1" 3>&1 1>&2 2>&3)"
    [[ -n "$ip_cidr" && -n "$gateway" ]] || die "Für statische IP sind IP/CIDR und Gateway Pflicht."
  else
    dns_server="$(whiptail --inputbox "DNS Server (optional)" 10 70 "1.1.1.1" 3>&1 1>&2 2>&3)"
  fi

  local ci_user
  ci_user="$(whiptail --inputbox "Cloud-Init Benutzer" 10 60 "debian" 3>&1 1>&2 2>&3)"

  local ssh_pub
  ssh_pub="$(whiptail --inputbox "Pfad zum Public Key" 10 70 "$HOME/.ssh/id_rsa.pub" 3>&1 1>&2 2>&3)"

  local ssh_priv
  ssh_priv="$(whiptail --inputbox "Pfad zum Private Key" 10 70 "$HOME/.ssh/id_rsa" 3>&1 1>&2 2>&3)"

  local ssh_port="22"

  local apps
  apps="$(choose_apps)"

  local repo_url
  repo_url="$(whiptail --inputbox "Optional: Git URL für externen App-Catalog (leer = lokal)" 12 90 "" 3>&1 1>&2 2>&3 || true)"
  local repo_branch="main"
  if [[ -n "$repo_url" ]]; then
    repo_branch="$(whiptail --inputbox "Catalog Branch" 10 60 "main" 3>&1 1>&2 2>&3)"
  fi

  local summary
  summary=$(cat <<EOT
VMID: $vmid
Name: $vm_name
CPU/RAM: $vm_cores / ${vm_ram}MB
Disk: ${vm_disk}GB
Storage: $vm_storage
Bridge: $vm_bridge
IP-Modus: $ip_mode
User: $ci_user
SSH Key: $ssh_pub
Apps: ${apps:-keine}
Catalog Repo: ${repo_url:-lokal}
EOT
)

  if ! whiptail --title "Bestätigung" --yesno "$summary\n\nWeiter mit Erstellung?" 22 80; then
    die "Vom Benutzer abgebrochen."
  fi

  cat >"$output_file" <<EOT
VMID="$vmid"
VM_NAME="$vm_name"
VM_CORES="$vm_cores"
VM_RAM="$vm_ram"
VM_DISK_GB="$vm_disk"
VM_STORAGE="$vm_storage"
IMAGE_STORAGE="$image_storage"
VM_BRIDGE="$vm_bridge"
IP_MODE="$ip_mode"
IP_CIDR="$ip_cidr"
GATEWAY="$gateway"
DNS_SERVER="$dns_server"
CI_USER="$ci_user"
SSH_PUBKEY_PATH="$ssh_pub"
SSH_PRIVATE_KEY_PATH="$ssh_priv"
SSH_PORT="$ssh_port"
SELECTED_APPS="$apps"
CATALOG_REPO_URL="$repo_url"
CATALOG_BRANCH="$repo_branch"
EOT
}
