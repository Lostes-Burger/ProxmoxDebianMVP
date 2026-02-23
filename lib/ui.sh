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
  printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE" >&2
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

ask_yes_no() {
  local title="$1"
  local message="$2"

  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "$title" --yesno "$message" 14 80
    return $?
  fi

  printf "%s\n" "$message"
  printf "Fortfahren? [y/N]: "
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

install_missing_packages() {
  local packages=("$@")

  log_info "Installiere fehlende Pakete: ${packages[*]}"
  if ! apt-get update -y; then
    die "apt-get update ist fehlgeschlagen."
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; then
    die "Automatische Paketinstallation ist fehlgeschlagen."
  fi
}

check_dependencies() {
  local required_core=(qm pvesm apt-get)
  local installable_cmds=(whiptail curl git jq ansible-playbook ssh nc ping ip)
  local missing_core=()
  local missing_installable_cmds=()
  local install_packages=()
  local dep
  local pkg

  for dep in "${required_core[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_core+=("$dep")
    fi
  done

  if [[ ${#missing_core[@]} -gt 0 ]]; then
    die "Proxmox/System-Kommandos fehlen: ${missing_core[*]}\nBitte Host-Setup prüfen und erneut starten."
  fi

  for dep in "${installable_cmds[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_installable_cmds+=("$dep")
      case "$dep" in
        whiptail) pkg="whiptail" ;;
        curl) pkg="curl" ;;
        git) pkg="git" ;;
        jq) pkg="jq" ;;
        ansible-playbook) pkg="ansible" ;;
        ssh) pkg="openssh-client" ;;
        nc) pkg="netcat-openbsd" ;;
        ping) pkg="iputils-ping" ;;
        ip) pkg="iproute2" ;;
        *) pkg="" ;;
      esac
      if [[ -n "$pkg" ]]; then
        install_packages+=("$pkg")
      fi
    fi
  done

  if [[ ${#missing_installable_cmds[@]} -gt 0 ]]; then
    if ask_yes_no "Fehlende Pakete" \
      "Folgende Abhängigkeiten fehlen:\n\n${missing_installable_cmds[*]}\n\nSollen diese jetzt automatisch installiert werden?"; then
      install_missing_packages "${install_packages[@]}"
      log_info "Fehlende Pakete wurden installiert."
    else
      die "Abgebrochen, weil notwendige Pakete fehlen: ${missing_installable_cmds[*]}"
    fi
  fi

  for dep in "${installable_cmds[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      die "Abhängigkeit '$dep' ist weiterhin nicht verfügbar. Bitte manuell prüfen."
    fi
  done
}

print_header() {
  whiptail --title "Proxmox Debian VM Orchestrator" --msgbox \
    "Interaktiver Setup-Assistent\n\nDieser Wizard erstellt eine Debian-13-VM und installiert ausgewählte Module/Apps per Ansible." \
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

format_kib_human() {
  local kib="$1"
  if [[ ! "$kib" =~ ^[0-9]+$ ]]; then
    echo "${kib}KiB"
    return 0
  fi

  # 1 TiB = 1073741824 KiB, 1 GiB = 1048576 KiB
  if (( kib >= 1073741824 )); then
    awk -v v="$kib" 'BEGIN { printf "%.2fTB", v/1073741824 }'
  else
    awk -v v="$kib" 'BEGIN { printf "%.2fGB", v/1048576 }'
  fi
}

choose_storage() {
  local title="$1"
  local prompt="$2"
  local preferred="$3"

  local menu_items=()
  while read -r name type status total used avail _pct; do
    [[ -z "$name" ]] && continue

    local used_h free_h total_h used_pct
    used_h="$(format_kib_human "$used")"
    free_h="$(format_kib_human "$avail")"
    total_h="$(format_kib_human "$total")"

    if [[ "$used" =~ ^[0-9]+$ ]] && [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
      used_pct="$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.1f%%", (u/t)*100 }')"
    else
      used_pct="n/a"
    fi

    local desc
    desc="type=${type} | status=${status} | used=${used_h} (${used_pct}) | free=${free_h} | total=${total_h}"
    menu_items+=("$name" "$desc")
  done < <(pvesm status | awk 'NR>1 {print $1, $2, $3, $4, $5, $6, $7}')

  [[ ${#menu_items[@]} -gt 0 ]] || die "Keine Storages via pvesm gefunden."

  local default="$preferred"
  if [[ -z "$default" ]]; then
    default="${menu_items[0]}"
  fi

  local selected
  if ! selected=$(whiptail --title "$title" --menu "$prompt" 22 110 12 \
    --default-item "$default" "${menu_items[@]}" 3>&1 1>&2 2>&3); then
    die "Vom Benutzer abgebrochen."
  fi

  echo "$selected"
}

choose_bridge() {
  local bridges=()
  local br

  while read -r br; do
    br="${br%%@*}"
    [[ -n "$br" ]] && bridges+=("$br" "$br")
  done < <(ip -d -o link show type bridge | awk -F': ' '{print $2}' | sed 's/@.*$//' | grep '^vmbr' | awk '!seen[$0]++' || true)

  if [[ ${#bridges[@]} -eq 0 ]]; then
    if ! br=$(whiptail --inputbox "Keine vmbr automatisch gefunden. Bridge manuell eingeben" 11 70 "vmbr0" 3>&1 1>&2 2>&3); then
      die "Vom Benutzer abgebrochen."
    fi
    echo "$br"
    return 0
  fi

  if ! br=$(whiptail --title "Netzwerk" --menu "Bridge auswählen" 18 70 8 "${bridges[@]}" 3>&1 1>&2 2>&3); then
    die "Vom Benutzer abgebrochen."
  fi

  echo "$br"
}

choose_ip_mode() {
  whiptail --title "Netzwerk" --radiolist "IP-Konfiguration wählen" 15 70 2 \
    "dhcp" "DHCP" ON \
    "static" "Statische IP" OFF \
    3>&1 1>&2 2>&3
}

choose_modules() {
  local selection
  if ! selection=$(whiptail --title "Module" --checklist "Optionale Module (leer möglich)" 20 85 8 \
    "baseline_tools" "Basiswerkzeuge" OFF \
    "unattended_upgrades" "Automatische Updates" OFF \
    "ufw" "Firewall" OFF \
    "fail2ban" "Bruteforce-Schutz" OFF \
    "qemu_guest_agent" "QEMU Guest Agent" OFF \
    "sysctl_hardening" "Kernel Hardening" OFF \
    3>&1 1>&2 2>&3); then
    die "Vom Benutzer abgebrochen."
  fi

  selection="${selection//\"/}"
  selection="${selection// /,}"
  echo "$selection"
}

choose_apps() {
  local selection
  if ! selection=$(whiptail --title "Apps" --checklist "Wähle Apps (leer möglich)" 15 75 5 \
    "docker" "Docker Engine + Compose Plugin" OFF \
    "nginx" "Nginx Webserver" OFF \
    3>&1 1>&2 2>&3); then
    die "Vom Benutzer abgebrochen."
  fi

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
  vm_storage="$(choose_storage "Storage" "Storage für VM-Disk auswählen" "local-lvm")"

  local vm_bridge
  vm_bridge="$(choose_bridge)"

  local vlan_tag
  vlan_tag="$(whiptail --inputbox "Optional VLAN Tag (1-4094, leer = untagged)" 11 70 "" 3>&1 1>&2 2>&3)"
  if [[ -n "$vlan_tag" ]]; then
    if ! [[ "$vlan_tag" =~ ^[0-9]+$ ]] || (( vlan_tag < 1 || vlan_tag > 4094 )); then
      die "VLAN Tag muss leer oder eine Zahl von 1 bis 4094 sein."
    fi
  fi

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

  local modules
  modules="$(choose_modules)"

  local apps
  apps="$(choose_apps)"

  local summary
  summary=$(cat <<EOT
VMID: $vmid
Name: $vm_name
CPU/RAM: $vm_cores / ${vm_ram}MB
Disk: ${vm_disk}GB
Storage: $vm_storage
Bridge: $vm_bridge
VLAN: ${vlan_tag:-untagged}
IP-Modus: $ip_mode
User: $ci_user
SSH Key: $ssh_pub
Module: ${modules:-keine}
Apps: ${apps:-keine}
EOT
)

  if ! whiptail --title "Bestätigung" --yesno "$summary\n\nWeiter mit Erstellung?" 22 85; then
    die "Vom Benutzer abgebrochen."
  fi

  cat >"$output_file" <<EOT
VMID="$vmid"
VM_NAME="$vm_name"
VM_CORES="$vm_cores"
VM_RAM="$vm_ram"
VM_DISK_GB="$vm_disk"
VM_STORAGE="$vm_storage"
VM_BRIDGE="$vm_bridge"
VLAN_TAG="$vlan_tag"
IP_MODE="$ip_mode"
IP_CIDR="$ip_cidr"
GATEWAY="$gateway"
DNS_SERVER="$dns_server"
CI_USER="$ci_user"
SSH_PUBKEY_PATH="$ssh_pub"
SSH_PRIVATE_KEY_PATH="$ssh_priv"
SSH_PORT="$ssh_port"
SELECTED_MODULES="$modules"
SELECTED_APPS="$apps"
EOT
}
