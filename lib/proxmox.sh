#!/usr/bin/env bash

set -euo pipefail

DEBIAN13_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

check_vmid_available() {
  local vmid="$1"
  if qm status "$vmid" >/dev/null 2>&1; then
    die "VMID $vmid ist bereits in Benutzung."
  fi
}

check_storage_exists() {
  local storage="$1"
  if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$storage"; then
    die "Storage '$storage' wurde nicht gefunden."
  fi
}

ensure_debian13_image() {
  local base_dir="/var/lib/vz/template/iso"
  local image_file="${base_dir}/debian-13-genericcloud-amd64.qcow2"

  mkdir -p "$base_dir"
  if [[ ! -f "$image_file" ]]; then
    log_info "Lade Debian 13 Cloud Image herunter"
    curl -fsSL "$DEBIAN13_IMAGE_URL" -o "$image_file" || die "Download des Debian 13 Images fehlgeschlagen."
  else
    log_info "Nutze vorhandenes Debian 13 Image: $image_file"
  fi

  echo "$image_file"
}

create_vm() {
  local vmid="$1"
  local vm_name="$2"
  local vm_cores="$3"
  local vm_ram="$4"
  local vm_disk_gb="$5"
  local vm_storage="$6"
  local vm_bridge="$7"
  local vlan_tag="$8"
  local image_path="$9"

  check_vmid_available "$vmid"
  check_storage_exists "$vm_storage"

  if [[ ! "$vm_bridge" =~ ^vmbr[0-9]+$ ]]; then
    die "Ungültige Bridge '$vm_bridge'. Erwartet: vmbrX"
  fi

  if [[ -n "$vlan_tag" ]] && ! [[ "$vlan_tag" =~ ^[0-9]+$ ]]; then
    die "Ungültiger VLAN Tag '$vlan_tag'."
  fi

  local net0="virtio,bridge=$vm_bridge"
  if [[ -n "$vlan_tag" ]]; then
    net0+=",tag=$vlan_tag"
  fi

  log_info "Erstelle VM $vmid ($vm_name)"
  log_info "Netzwerk: bridge=$vm_bridge vlan=${vlan_tag:-untagged}"

  qm create "$vmid" \
    --name "$vm_name" \
    --memory "$vm_ram" \
    --cores "$vm_cores" \
    --net0 "$net0" \
    --scsihw virtio-scsi-pci \
    --agent enabled=1 >/dev/null

  qm importdisk "$vmid" "$image_path" "$vm_storage" >/dev/null

  local imported_disk
  imported_disk="$(qm config "$vmid" | awk -F': ' '/^unused[0-9]+:/{print $2; exit}')"
  [[ -n "$imported_disk" ]] || die "Importierte Disk wurde nicht gefunden."

  qm set "$vmid" --scsi0 "$imported_disk" >/dev/null
  qm set "$vmid" --ide2 "$vm_storage:cloudinit" >/dev/null
  qm set "$vmid" --boot order=scsi0 >/dev/null
  qm resize "$vmid" scsi0 "${vm_disk_gb}G" >/dev/null

  log_info "VM $vmid erfolgreich erstellt"
}

start_vm() {
  local vmid="$1"
  log_info "Starte VM $vmid"
  qm start "$vmid" >/dev/null
}

wait_for_ssh() {
  local ip="$1"
  local port="$2"
  local timeout="$3"
  local interval="$4"
  local user="$5"
  local auth_mode="$6"
  local key_path="$7"
  local password="$8"

  if [[ "$ip" =~ ^127\. ]]; then
    die "Ungültige Ziel-IP '$ip' (Loopback). DHCP/QGA-Ermittlung ist fehlerhaft."
  fi

  local deadline=$((SECONDS + timeout))
  local attempt=1
  while (( SECONDS < deadline )); do
    log_info "Warte auf SSH-Login (${user}@${ip}:${port}, mode=${auth_mode}) - Versuch ${attempt}"

    local rc=1
    if [[ "$auth_mode" == "key" ]]; then
      if [[ -f "$key_path" ]]; then
        if ssh -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -i "$key_path" \
          -p "$port" \
          "${user}@${ip}" "true" >/dev/null 2>&1; then
          rc=0
        else
          rc=$?
        fi
      fi
    else
      if [[ -n "$password" ]]; then
        if sshpass -p "$password" ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no \
          -p "$port" \
          "${user}@${ip}" "true" >/dev/null 2>&1; then
          rc=0
        else
          rc=$?
        fi
      fi
    fi

    if [[ $rc -eq 0 ]]; then
      log_info "SSH-Login erfolgreich: ${user}@${ip}:${port}"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep "$interval"
  done

  die "SSH Timeout nach ${timeout}s auf ${user}@${ip}:${port} (mode=${auth_mode})."
}
