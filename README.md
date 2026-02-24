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
- Separate Auswahl für Cloud-Init Snippet-Storage (mit `snippets` Content), z. B. `local`
- Netzwerk:
  - nur echte Bridge-Interfaces (`vmbr*`) in der Auswahl
  - optionaler VLAN-Tag
  - DHCP oder statische IP
- SSH-Login:
  - Feld für Ansible-Benutzername (Default `debian`)
  - Danach Auth-Auswahl für den Ansible-Benutzer: `SSH Key Path` / `manueller SSH Key` / `Passwort`
  - Dieser Benutzer wird für SSH, Bootstrap und Ansible genutzt
- Root-Login:
  - Auswahl: `SSH Key Path` / `manueller SSH Key` / `Passwort`
  - Root-Zugang wird direkt via Cloud-Init konfiguriert
- Optionale Module (auch leer möglich)
- Optionale Apps `docker`, `nginx`, `unifi_os_server` (auch leer möglich)
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
- `sshpass`
- `nc`
- `ping`
- `ip`

Wenn installierbare Pakete fehlen, fragt der Wizard, ob sie automatisch installiert werden sollen oder ob abgebrochen wird.

## Hinweise

- Während der Provisionierung gibt es laufend Konsolen-Feedback (z. B. Warten auf DHCP-IP, Ping/SSH-Checks).
- Der SSH-Wait prüft den echten Login mit dem gewählten Cloud-Init-Benutzer (nicht `root`).
- Bei DHCP wird die IP automatisch über `qemu-guest-agent` ermittelt (kein manueller IP-Prompt mehr).
- VM-Disk und Cloud-Init-Snippets können auf unterschiedlichen Storages liegen (z. B. VM auf `bigdata`, Snippets auf `local`).
- Neue VMs werden ohne erzwungenen Serial-Display-Modus erstellt.
- `unifi_os_server` zieht bei Auswahl die aktuelle Linux-x64-`.deb` von `ui.com/download/releases/unifi-os-server`.
- Logs liegen unter `/var/log/proxmox-orchestrator.log` (Fallback: `/tmp/proxmox-orchestrator.log`).
