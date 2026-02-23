# Proxmox Debian VM Orchestrator – Plan

## Ziel

Ein interaktives CLI-Tool auf dem Proxmox-Host, das:

1. Eine Debian 13 VM via Cloud-Init erstellt
2. Die VM minimal bootstrapped (SSH + Python + Netzwerk)
3. Anschließend automatisch via Ansible:

   * Module (Baseline, Security, Systemkonfiguration)
   * Apps (aus dynamischem Git-Repository)
     installiert
4. Vollständig reproduzierbar, robust und erweiterbar ist

---

# Architekturübersicht

## Komponenten

### 1. Proxmox Orchestrator Script (Host)

* Sprache: Bash
* Aufgabe:

  * Menü (whiptail)
  * VM erstellen (qm create/importdisk/cloud-init)
  * App Catalog syncen (Git)
  * Auswahl → Variablen generieren
  * Ansible starten

---

### 2. Cloud-Init (VM Bootstrap)

Minimal halten:

* User + SSH Keys
* Netzwerk (DHCP oder statisch)
* Hostname
* Installation von:

  * python3
  * qemu-guest-agent (optional)

Ziel: VM ist SSH + Ansible ready

---

### 3. Ansible (Provisioning Engine)

* Führt ALLE Konfigurationen aus:

  * Module
  * Apps
* Idempotent
* Struktur:

  * roles/modules/*
  * roles/apps/*
  * playbook: site.yml

---

### 4. App Catalog Repository (Git)

Externes Repo:

* index.json (App Definitionen)
* roles/apps/<app_name>/

Host cached dieses Repo lokal.

---

# Verzeichnisstruktur (Host)

```
/opt/proxmox-orchestrator/
│
├── orchestrator.sh
├── lib/
│   ├── ui.sh
│   ├── proxmox.sh
│   ├── cloudinit.sh
│   ├── ansible.sh
│   └── catalog.sh
│
├── ansible/
│   ├── site.yml
│   ├── inventory.tpl
│   ├── roles/
│   │   ├── modules/
│   │   └── apps/ (optional fallback)
│
└── catalog/
    └── (git clone)
```

---

# Ablauf (End-to-End)

## 1. Catalog Sync

* Git Repo unter `/opt/proxmox-orchestrator/catalog/`
* Befehl:

  * git fetch --depth=1
  * git reset --hard origin/<branch>

Failsafe:

* Wenn Git fehlschlägt → letzter funktionierender Stand verwenden

---

## 2. UI (whiptail)

### Eingaben:

#### VM Config

* VM ID
* Name
* CPU
* RAM
* Disk
* Storage
* Network (bridge)
* IP (DHCP oder statisch)
* Gateway
* DNS

---

### SSH Settings

* SSH aktiv: ja/nein
* Auth:

  * key only
  * key + password
* Root login:

  * no
  * prohibit-password
  * yes
* SSH Port

---

### Module Auswahl (flat, keine Gruppen)

Jedes Modul:

* Toggle + optional Sub-Dialog

#### Module:

* baseline_tools
* unattended_upgrades
* ufw
* fail2ban
* qemu_guest_agent
* sysctl_hardening

---

### Module Subsettings

#### UFW

* preset:

  * server-minimal
  * web
  * lan-only
  * custom
* auto-allow app ports: yes/no

#### unattended-upgrades

* security only / full
* auto reboot yes/no

---

### App Auswahl (aus index.json)

* dynamisch geladen
* Multi-select

---

## 3. VM Erstellung

### Schritte:

1. Image laden (Debian 13 cloud image)
2. qm create
3. importdisk
4. Cloud-Init Drive anhängen
5. set:

   * ciuser
   * sshkeys
   * ipconfig
   * nameserver
6. qm start

Failsafe:

* VMID collision check
* Storage check
* Netzwerk validieren

---

## 4. Wait for SSH

Loop:

* ping + nc/ssh check
* timeout: 120s
* retry interval: 3s

Failsafe:

* Timeout → Fehler + Abbruch

---

## 5. Ansible Execution

### Inventory (dynamisch erzeugt)

```
[targets]
<ip> ansible_user=<user> ansible_ssh_private_key_file=...
```

---

### Übergabe Variablen

```
modules:
  ufw: true
  fail2ban: false

apps:
  - nginx
  - docker

ssh:
  root_login: prohibit-password
  port: 22

ufw:
  preset: web
  allow_app_ports: true
```

---

### Aufruf

```
ansible-playbook -i inventory site.yml --extra-vars @vars.json
```

Failsafe:

* Exit code prüfen
* Fehler loggen

---

# App Catalog Design

## index.json

```
{
  "apps": [
    {
      "name": "nginx",
      "role": "nginx",
      "ports": [
        {"port": 80, "proto": "tcp", "scope": "public"},
        {"port": 443, "proto": "tcp", "scope": "public"}
      ],
      "depends": []
    }
  ]
}
```

---

## Regeln

* role entspricht Ansible Role
* ports werden für UFW genutzt
* depends optional

---

# Ansible Struktur

## site.yml

```
- hosts: targets
  become: true

  roles:
    - role: modules/baseline_tools
      when: modules.baseline_tools

    - role: modules/ufw
      when: modules.ufw

    - role: modules/unattended_upgrades
      when: modules.unattended_upgrades

    - role: modules/fail2ban
      when: modules.fail2ban

    - role: modules/qemu_guest_agent
      when: modules.qemu_guest_agent

    - role: modules/sysctl
      when: modules.sysctl_hardening

    # Apps dynamisch
    - role: "{{ item }}"
      loop: "{{ apps }}"
```

---

# UFW Logik

* Default:

  * deny incoming
  * allow outgoing

* SSH:

  * automatisch erlauben wenn aktiv

* Apps:

  * Ports aus index.json
  * abhängig von scope:

    * public → allow
    * lan → allow from RFC1918
    * local → skip

Failsafe:

* SSH immer freigeben bevor UFW aktiviert wird

---

# Logging

## Host

* `/var/log/proxmox-orchestrator.log`

## VM

* `/var/log/ansible.log`

---

# Fehlerbehandlung

## Git

* fallback auf letzten Stand

## VM

* create fail → cleanup optional

## SSH

* timeout → abort

## Ansible

* Fehler → stop + log

---

# Sicherheit

* SSH key bevorzugt
* optional root login deaktivieren
* keine blind curl | bash
* Git:

  * optional branch = stable
  * optional commit pinning

---

# Erweiterbarkeit

* neue Apps = nur Repo ändern
* neue Module = neue Rolle hinzufügen
* UI automatisch aus index generierbar

---

# MVP Scope

MUSS:

* VM erstellen
* SSH Zugriff
* Ansible läuft
* 2–3 Apps
* UFW + SSH korrekt

SPÄTER:

* commit pinning
* advanced params pro App
* multiple networks

---

# Ende
