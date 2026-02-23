# Proxmox Debian VM Orchestrator (MVP)

Interaktives CLI-Tool für Proxmox 8 zur Erstellung einer Debian-13-VM und optionalen Installation von Modulen/Apps via Ansible.

## Wizard starten

Vom Repo-Root auf dem Proxmox-Host:

```bash
chmod +x orchestrator.sh
./orchestrator.sh
```

## Was der Wizard abfragt

- VM-Ressourcen: `VMID`, `Name`, `vCPU`, `RAM`, `Disk`
- Storage-Auswahl per Menü aus `pvesm status`:
  - Storage-Name
  - Typ (`zfs`, `lvmthin`, `ceph`, ...)
  - Used/Free/Total in `GB`/`TB` + Auslastung in `%`
- Netzwerk:
  - nur echte Bridge-Interfaces (`vmbr*`) in der Auswahl
  - optionaler VLAN-Tag
  - DHCP oder statische IP
- SSH key-only (`Public/Private Key Pfad`)
- Optionale Module (auch leer möglich)
- Optionale Apps `docker` und `nginx` (auch leer möglich)
- `qemu-guest-agent` wird immer installiert (nicht mehr als optionales Modul)

## Benötigte Dateien im Repo

- `orchestrator.sh`
- `lib/`
- `ansible/site.yml`
- `ansible/roles/apps/`

## Benötigte Pakete auf dem Proxmox-Host

- `whiptail`
- `qm`
- `pvesm`
- `curl`
- `git`
- `jq`
- `ansible-playbook`
- `ssh`
- `nc`
- `ping`
- `ip`

Wenn installierbare Pakete fehlen, fragt der Wizard, ob sie automatisch installiert werden sollen oder ob abgebrochen wird.

## Hinweise

- Während der Provisionierung gibt es laufend Konsolen-Feedback (z. B. Warten auf DHCP-IP, Ping/SSH-Checks).
- Bei DHCP wird die IP automatisch über `qemu-guest-agent` ermittelt (kein manueller IP-Prompt mehr).
- Voraussetzung: mindestens ein Proxmox-Storage mit Content-Typ `snippets` für Cloud-Init User-Data.
- Logs liegen unter `/var/log/proxmox-orchestrator.log` (Fallback: `/tmp/proxmox-orchestrator.log`).
