# HV-LazyBackup (Bootloader System)

<p align="center">
  <img src="assets/hv-lazybackup-architecture-image.png" alt="HV-LazyBackup Architecture Demo" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-Bootloader-blue?style=for-the-badge&logo=powershell" />
  <img src="https://img.shields.io/badge/Hyper--V-Automation-purple?style=for-the-badge" />
  <img src="https://img.shields.io/badge/System-Unpacker-orange?style=for-the-badge" />
  <img src="https://img.shields.io/badge/Status-Release--Safe-green?style=for-the-badge" />
</p>

---

# Important Concept

HV-LazyBackup is a bootloader / unpacker engine. You run one setup script, and it generates the complete Hyper-V backup runtime system.

The bootloader is for installation. The generated runtime scripts are for daily use.

---

# Only Entry File

```powershell
.\HV_LazyBackup_Bootstrap_Setup.ps1
```

The bootloader:

- Detects Hyper-V and lists available VMs.
- Lets you choose the target VM.
- Lets you choose a backup drive.
- Blocks `C:\` as a backup target.
- Generates config, folders, scripts, helper module, logs, reports, and runtime docs.
- Validates every generated PowerShell file before finishing.
- Fails clearly if generation fails.

---

# Generated System

Default install path:

```text
C:\HV-LazyBackup\
|-- config.json
|-- README.md
|-- logs\
|   `-- log.txt
|-- reports\
|-- modules\
|   `-- VM-Helpers.psm1
`-- scripts\
    |-- Backup-VM.ps1
    |-- Verify-Backup.ps1
    |-- Check-VMState.ps1
    |-- Export-VMState.ps1
    `-- Helpers.ps1
```

---

# Installation

Open PowerShell as Administrator on a Hyper-V host:

```powershell
cd <REPO_FOLDER>
.\HV_LazyBackup_Bootstrap_Setup.ps1
```

Follow the prompts for install path, VM selection, and backup drive.

---

# Daily Operation

Open PowerShell as Administrator:

```powershell
cd C:\HV-LazyBackup
.\scripts\Backup-VM.ps1
```

That opens the daily operation menu:

```text
1. Run Backup Now
2. Verify Last Backup
3. View Backup History
4. Check VM State
5. Export VM State Report
6. Open Logs
7. Settings / Configuration
8. Exit
```

---

# Direct Commands

Run backup without the menu:

```powershell
.\scripts\Backup-VM.ps1 -RunBackup
```

Verify backups:

```powershell
.\scripts\Verify-Backup.ps1
```

Check VM state:

```powershell
.\scripts\Check-VMState.ps1
```

Export a VM state report:

```powershell
.\scripts\Export-VMState.ps1
```

---

# Backup Drive Override

The configured backup root comes from `config.json`.

To temporarily use another selected drive:

```powershell
.\scripts\Backup-VM.ps1 -RunBackup -BackupDrive X
.\scripts\Verify-Backup.ps1 -BackupDrive X
```

That uses:

```text
X:\VM_MASTER_BACKUP
```

---

# Backup Output

```text
<SELECTED_DRIVE>:\VM_MASTER_BACKUP\VM-NAME-MASTER-TIMESTAMP\
```

Example:

```text
X:\VM_MASTER_BACKUP\GrizTechW-MASTER-2026-06-16_12-03\
    .vhdx
    .vmcx
    .vmrs
```

---

# Safety Layer

- Admin expected.
- Hyper-V discovery and VM validation.
- `C:\` backup drive blocked.
- Safe VM stop before export.
- Generated file validation.
- Runtime logging.
- Backup verification checks for `.vhdx`.
- VM state reports.

---

# Status

Release-Safe Bootloader System v1.2

---

# Author

TCDOverLord
