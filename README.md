# Proxmox Debian VM Orchestrator (MVP)

Interaktives CLI-Tool für Proxmox 8 zur Erstellung einer Debian-13-VM und optionalen App-Installation via Ansible.

## Enthalten (MVP)

- Interaktiver Wizard (`whiptail`)
- VM-Erstellung (`qm create`, `qm importdisk`, Cloud-Init)
- VM-Ressourcen im Wizard:
  - VMID, Name
  - vCPU, RAM
  - Disk-Größe
  - VM-Storage (z. B. `local-lvm`)
  - Storage für Cloud-Image
  - Netzwerk: DHCP oder statisch, Bridge auswählbar
  - SSH key-only Setup
  - SSH Wait + VM Bootstrap (Python + qemu-guest-agent)
  - Ansible Provisionierung mit optionalen Apps:
  - `docker`
  - `nginx`

## Wizard starten

Vom Repo-Root auf dem Proxmox-Host:

```bash
chmod +x orchestrator.sh
./orchestrator.sh
```

## Welche Dateien aus dem Repo werden benötigt?

Für den Start des Wizards und den MVP-Flow werden diese Dateien/Ordner benötigt:

- `orchestrator.sh`
- `lib/`
- `ansible/site.yml`
- `ansible/roles/apps/`

Optional:

- `catalog/` (nur wenn externer App-Catalog genutzt wird)

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

Wenn etwas fehlt, bricht das Tool mit klarer Meldung ab.

## Hinweise

- Externer App-Catalog ist optional; für den MVP werden lokale Rollen genutzt.
- Logs liegen unter `/var/log/proxmox-orchestrator.log` (Fallback: `/tmp/proxmox-orchestrator.log`).
