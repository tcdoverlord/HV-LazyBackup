# =========================================================
# HV-LazyBackup Bootstrap Installer
# Builds the complete generated runtime system.
# =========================================================

$ErrorActionPreference = "Stop"

function Stop-Bootstrap {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Write-FileUtf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    try {
        $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
    catch {
        Stop-Bootstrap "Failed to write $Path. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Bootstrap "Generation failed. Missing file: $Path"
    }

    if ((Get-Item -LiteralPath $Path).Length -eq 0) {
        Stop-Bootstrap "Generation failed. Empty file: $Path"
    }
}

function Test-PowerShellScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join "; "
        Stop-Bootstrap "Generated PowerShell has syntax errors: $Path. $details"
    }
}

function Assert-GeneratedSystem {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles
    )

    foreach ($folder in @("logs", "scripts", "modules", "reports")) {
        $folderPath = Join-Path $InstallRoot $folder
        if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
            Stop-Bootstrap "Generation validation failed. Missing folder: $folderPath"
        }
    }

    foreach ($file in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Stop-Bootstrap "Generation validation failed. Missing required file: $file"
        }

        if ((Get-Item -LiteralPath $file).Length -eq 0) {
            Stop-Bootstrap "Generation validation failed. Required file is empty: $file"
        }
    }

    $configPath = Join-Path $InstallRoot "config.json"
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }
    catch {
        Stop-Bootstrap "Generated config.json is invalid JSON. $($_.Exception.Message)"
    }

    foreach ($property in @("SystemName", "Version", "VMName", "BackupPath", "InstallPath", "Created", "ScriptsPath", "ModulesPath", "LogsPath", "ReportsPath")) {
        if (-not $config.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$config.$property)) {
            Stop-Bootstrap "Generated config.json is missing required property: $property"
        }
    }

    foreach ($file in $RequiredFiles | Where-Object { $_ -match "\.ps1$|\.psm1$" }) {
        Test-PowerShellScript -Path $file
    }
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ("{0,-48}" -f $Label) -NoNewline
    try {
        & $Action
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Write-Host "FAILED" -ForegroundColor Red
        Stop-Bootstrap "$Label failed. $($_.Exception.Message)"
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "HV-LazyBackup Bootloader Builder v1.2" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# -----------------------------------------
# INSTALL LOCATION
# -----------------------------------------
Write-Host ""
Write-Host "INSTALL LOCATION SETUP" -ForegroundColor Yellow

$defaultInstall = "C:\HV-LazyBackup"
$installRoot = Read-Host "Enter install path (ENTER for default: $defaultInstall)"

if ([string]::IsNullOrWhiteSpace($installRoot)) {
    $installRoot = $defaultInstall
}

$installRoot = [System.IO.Path]::GetFullPath($installRoot)

if ($installRoot -match "^(?i)c:\\windows(\\|$)" -or $installRoot -match "^(?i)c:\\windows\\system32(\\|$)") {
    Stop-Bootstrap "Invalid install location: $installRoot"
}

$configPath = Join-Path $installRoot "config.json"
$scriptPath = Join-Path $installRoot "scripts"
$modulePath = Join-Path $installRoot "modules"
$logPath = Join-Path $installRoot "logs"
$reportPath = Join-Path $installRoot "reports"
$logFile = Join-Path $logPath "log.txt"

Write-Host "Installing to: $installRoot" -ForegroundColor Green

# -----------------------------------------
# CREATE CORE STRUCTURE
# -----------------------------------------
Write-Step "Creating folder structure" {
    foreach ($folder in @($installRoot, $scriptPath, $modulePath, $logPath, $reportPath)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
}

# -----------------------------------------
# HYPER-V DISCOVERY
# -----------------------------------------
Write-Host ""
Write-Host "AVAILABLE VMs:" -ForegroundColor Yellow

Write-Step "Detecting Hyper-V environment" {
    $script:availableVms = @(Get-VM)
}

if ($availableVms.Count -eq 0) {
    Stop-Bootstrap "No Hyper-V VMs were found."
}

$availableVms | Select-Object Name, State | Format-Table -AutoSize

Write-Host ""
$vmName = Read-Host "Enter VM name (ENTER = first VM)"

if ([string]::IsNullOrWhiteSpace($vmName)) {
    $vmName = $availableVms[0].Name
}

$vm = $availableVms | Where-Object { $_.Name -eq $vmName } | Select-Object -First 1
if (-not $vm) {
    Stop-Bootstrap "VM not found: $vmName"
}

Write-Host "VM selected: $vmName" -ForegroundColor Green

# -----------------------------------------
# BACKUP DRIVE
# -----------------------------------------
Write-Host ""
Write-Host "AVAILABLE DRIVES:" -ForegroundColor Yellow
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    Write-Host "$($_.Name): $($_.Root)"
}

Write-Host ""
$drive = (Read-Host "Select backup drive letter (e.g. X)").Trim().TrimEnd(":").ToUpperInvariant()

if ([string]::IsNullOrWhiteSpace($drive)) {
    Stop-Bootstrap "Backup drive is required."
}

if ($drive -eq "C") {
    Stop-Bootstrap "C: drive is blocked for backups."
}

if ($drive -notmatch "^[A-Z]$") {
    Stop-Bootstrap "Backup drive must be a single drive letter."
}

$driveRoot = "$drive`:\"
if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
    Stop-Bootstrap "Drive not found: $driveRoot"
}

$backupRoot = Join-Path $driveRoot "VM_MASTER_BACKUP"
Write-Step "Creating backup root" {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
}

# -----------------------------------------
# CONFIG
# -----------------------------------------
$config = [ordered]@{
    SystemName       = "HV-LazyBackup"
    Version          = "1.2"
    VMName           = $vmName
    BackupPath       = $backupRoot
    InstallPath      = $installRoot
    ScriptsPath      = $scriptPath
    ModulesPath      = $modulePath
    LogsPath         = $logPath
    ReportsPath      = $reportPath
    LogFile          = $logFile
    Created          = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    BlockedDrive     = "C"
    BackupFolderName = "VM_MASTER_BACKUP"
}

Write-Step "Writing system configuration" {
    Write-FileUtf8 -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)
}

# -----------------------------------------
# GENERATED MODULE AND HELPER CONTENT
# -----------------------------------------
$vmHelpersModulePath = Join-Path $modulePath "VM-Helpers.psm1"
$helpersScriptPath = Join-Path $scriptPath "Helpers.ps1"
$checkStatePath = Join-Path $scriptPath "Check-VMState.ps1"
$exportStatePath = Join-Path $scriptPath "Export-VMState.ps1"
$verifyScriptPath = Join-Path $scriptPath "Verify-Backup.ps1"
$backupScriptPath = Join-Path $scriptPath "Backup-VM.ps1"
$runtimeReadmePath = Join-Path $installRoot "README.md"

$vmHelpersModule = @'
function Get-HVLazyConfig {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config.json"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Missing config.json at $ConfigPath"
    }

    return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

function Write-HVLazyLog {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $logFile = $Config.LogFile
    if ([string]::IsNullOrWhiteSpace($logFile)) {
        $logFile = Join-Path $Config.LogsPath "log.txt"
    }

    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $logFile -Value $entry
}

function Stop-HVLazy {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [pscustomobject]$Config
    )

    if ($Config) {
        Write-HVLazyLog -Config $Config -Level "ERROR" -Message $Message
    }

    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Resolve-HVLazyBackupRoot {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BackupDrive
    )

    if ([string]::IsNullOrWhiteSpace($BackupDrive)) {
        return $Config.BackupPath
    }

    $drive = $BackupDrive.Trim().TrimEnd(":").ToUpperInvariant()
    if ($drive -eq $Config.BlockedDrive) {
        Stop-HVLazy -Config $Config -Message "$($Config.BlockedDrive): drive is blocked for backups."
    }

    if ($drive -notmatch "^[A-Z]$") {
        Stop-HVLazy -Config $Config -Message "Backup drive override must be a single drive letter."
    }

    $driveRoot = "$drive`:\"
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
        Stop-HVLazy -Config $Config -Message "Backup drive not found: $driveRoot"
    }

    return (Join-Path $driveRoot $Config.BackupFolderName)
}

function Get-HVLazyVM {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    try {
        return Get-VM -Name $Config.VMName -ErrorAction Stop
    }
    catch {
        Stop-HVLazy -Config $Config -Message "Unable to find VM '$($Config.VMName)'. $($_.Exception.Message)"
    }
}

function Get-HVLazyVMState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    return (Get-HVLazyVM -Config $Config).State
}

function Export-HVLazyVMStateReport {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    $vm = Get-HVLazyVM -Config $Config
    New-Item -ItemType Directory -Force -Path $Config.ReportsPath | Out-Null

    $reportPath = Join-Path $Config.ReportsPath ("VM-State-{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    $content = @(
        "HV-LazyBackup VM State Report",
        "Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")",
        "VMName: $($vm.Name)",
        "State: $($vm.State)",
        "Status: $($vm.Status)",
        "CPUUsage: $($vm.CPUUsage)",
        "MemoryAssigned: $($vm.MemoryAssigned)",
        "Uptime: $($vm.Uptime)"
    )

    $content | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    Write-HVLazyLog -Config $Config -Message "Exported VM state report: $reportPath"
    return $reportPath
}

function Invoke-HVLazyBackup {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BackupDrive
    )

    $backupRoot = Resolve-HVLazyBackupRoot -Config $Config -BackupDrive $BackupDrive
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    $vm = Get-HVLazyVM -Config $Config
    $destination = Join-Path $backupRoot ("{0}-MASTER-{1}" -f $vm.Name, (Get-Date -Format "yyyy-MM-dd_HH-mm"))

    Write-HVLazyLog -Config $Config -Message "Starting backup for VM '$($vm.Name)' to $destination"
    Write-Host "Checking VM state..." -ForegroundColor Cyan

    if ($vm.State -ne "Off") {
        Write-Host "VM is $($vm.State). Shutting down before export..." -ForegroundColor Yellow
        Write-HVLazyLog -Config $Config -Level "WARN" -Message "VM '$($vm.Name)' was $($vm.State); stopping before export."
        Stop-VM -Name $vm.Name -TurnOff -Force
        Start-Sleep -Seconds 5
    }

    Write-Host "Exporting VM to $destination..." -ForegroundColor Cyan
    Export-VM -Name $vm.Name -Path $destination

    $vhdx = @(Get-ChildItem -LiteralPath $destination -Recurse -Filter *.vhdx -File -ErrorAction SilentlyContinue)
    if ($vhdx.Count -eq 0) {
        Stop-HVLazy -Config $Config -Message "Export completed but no .vhdx was found in $destination"
    }

    Write-HVLazyLog -Config $Config -Message "Backup complete: $destination"
    Write-Host "BACKUP COMPLETE: $destination" -ForegroundColor Green
    return $destination
}

function Test-HVLazyBackup {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BackupDrive
    )

    $backupRoot = Resolve-HVLazyBackupRoot -Config $Config -BackupDrive $BackupDrive
    Write-Host "Checking backup root: $backupRoot"

    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        Write-HVLazyLog -Config $Config -Level "ERROR" -Message "Backup root does not exist: $backupRoot"
        return $false
    }

    $vhdx = @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter *.vhdx -File -ErrorAction SilentlyContinue)
    if ($vhdx.Count -eq 0) {
        Write-HVLazyLog -Config $Config -Level "ERROR" -Message "No .vhdx files found under $backupRoot"
        return $false
    }

    Write-HVLazyLog -Config $Config -Message "Verified backup root $backupRoot with $($vhdx.Count) .vhdx file(s)."
    return $true
}

function Get-HVLazyBackupVhdx {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BackupDrive
    )

    $backupRoot = Resolve-HVLazyBackupRoot -Config $Config -BackupDrive $BackupDrive
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter *.vhdx -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

function Get-HVLazyBackupHistory {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BackupDrive
    )

    $backupRoot = Resolve-HVLazyBackupRoot -Config $Config -BackupDrive $BackupDrive
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

Export-ModuleMember -Function Get-HVLazyConfig, Write-HVLazyLog, Stop-HVLazy, Resolve-HVLazyBackupRoot, Get-HVLazyVM, Get-HVLazyVMState, Export-HVLazyVMStateReport, Invoke-HVLazyBackup, Test-HVLazyBackup, Get-HVLazyBackupVhdx, Get-HVLazyBackupHistory
'@

$helpersScript = @'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "modules\VM-Helpers.psm1"
Import-Module $modulePath -Force
'@

$checkStateScript = @'
param([string]$ConfigPath)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "modules\VM-Helpers.psm1"
Import-Module $modulePath -Force

$config = Get-HVLazyConfig -ConfigPath $ConfigPath
$state = Get-HVLazyVMState -Config $config
Write-HVLazyLog -Config $config -Message "VM '$($config.VMName)' state checked: $state"
Write-Host "VM: $($config.VMName)"
Write-Host "State: $state"
'@

$exportStateScript = @'
param([string]$ConfigPath)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "modules\VM-Helpers.psm1"
Import-Module $modulePath -Force

$config = Get-HVLazyConfig -ConfigPath $ConfigPath
$report = Export-HVLazyVMStateReport -Config $config
Write-Host "VM state report written: $report" -ForegroundColor Green
'@

$verifyScript = @'
param(
    [string]$BackupDrive,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "modules\VM-Helpers.psm1"
Import-Module $modulePath -Force

$config = Get-HVLazyConfig -ConfigPath $ConfigPath

Write-Host "--------------------------------"
$result = Test-HVLazyBackup -Config $config -BackupDrive $BackupDrive

if ($result -eq $true) {
    Write-Host "BACKUP VALID" -ForegroundColor Green
    Get-HVLazyBackupVhdx -Config $config -BackupDrive $BackupDrive | Select-Object -First 5 FullName, Length, LastWriteTime | Format-Table -AutoSize
    Write-Host "--------------------------------"
    exit 0
}

Write-Host "BACKUP FAILED" -ForegroundColor Red
Write-Host "No .vhdx files found in the selected backup root."
Write-Host "--------------------------------"
exit 1
'@

$backupScript = @'
param(
    [string]$BackupDrive,
    [string]$ConfigPath,
    [switch]$RunBackup,
    [switch]$VerifyOnly,
    [switch]$CheckState,
    [switch]$ExportState
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "modules\VM-Helpers.psm1"
Import-Module $modulePath -Force

$config = Get-HVLazyConfig -ConfigPath $ConfigPath

function Show-HVLazyMenu {
    Write-Host ""
    Write-Host "======= HV-LAZYBACKUP - MAIN MENU =======" -ForegroundColor Cyan
    Write-Host "1. Run Backup Now"
    Write-Host "2. Verify Last Backup"
    Write-Host "3. View Backup History"
    Write-Host "4. Check VM State"
    Write-Host "5. Export VM State Report"
    Write-Host "6. Open Logs"
    Write-Host "7. Settings / Configuration"
    Write-Host "8. Exit"
    Write-Host ""
}

function Show-BackupHistory {
    $history = Get-HVLazyBackupHistory -Config $config -BackupDrive $BackupDrive
    if ($history.Count -eq 0) {
        Write-Host "No backup folders found." -ForegroundColor Yellow
        return
    }

    $history | Select-Object -First 10 Name, FullName, LastWriteTime | Format-Table -AutoSize
}

function Show-Settings {
    $config | Format-List
}

function Open-Logs {
    if (-not (Test-Path -LiteralPath $config.LogFile -PathType Leaf)) {
        Write-Host "No log file yet: $($config.LogFile)" -ForegroundColor Yellow
        return
    }

    Get-Content -LiteralPath $config.LogFile -Tail 50
}

if ($RunBackup) {
    Invoke-HVLazyBackup -Config $config -BackupDrive $BackupDrive | Out-Null
    exit 0
}

if ($VerifyOnly) {
    $verified = Test-HVLazyBackup -Config $config -BackupDrive $BackupDrive
    if ($verified -eq $true) {
        Write-Host "BACKUP VALID" -ForegroundColor Green
        exit 0
    }

    Write-Host "BACKUP FAILED" -ForegroundColor Red
    exit 1
}

if ($CheckState) {
    Write-Host "VM: $($config.VMName)"
    Write-Host "State: $(Get-HVLazyVMState -Config $config)"
    exit 0
}

if ($ExportState) {
    $report = Export-HVLazyVMStateReport -Config $config
    Write-Host "VM state report written: $report" -ForegroundColor Green
    exit 0
}

do {
    Show-HVLazyMenu
    $choice = Read-Host "Select an option [1-8]"

    switch ($choice) {
        "1" { Invoke-HVLazyBackup -Config $config -BackupDrive $BackupDrive | Out-Null }
        "2" {
            $verified = Test-HVLazyBackup -Config $config -BackupDrive $BackupDrive
            if ($verified -eq $true) {
                Write-Host "BACKUP VALID" -ForegroundColor Green
            }
            else {
                Write-Host "BACKUP FAILED" -ForegroundColor Red
            }
        }
        "3" { Show-BackupHistory }
        "4" {
            Write-Host "VM: $($config.VMName)"
            Write-Host "State: $(Get-HVLazyVMState -Config $config)"
        }
        "5" {
            $report = Export-HVLazyVMStateReport -Config $config
            Write-Host "VM state report written: $report" -ForegroundColor Green
        }
        "6" { Open-Logs }
        "7" { Show-Settings }
        "8" { break }
        default { Write-Host "Invalid option." -ForegroundColor Yellow }
    }

    if ($choice -ne "8") {
        Write-Host ""
        Read-Host "Press ENTER to continue" | Out-Null
    }
} while ($choice -ne "8")
'@

$runtimeReadme = @'
# HV-LazyBackup Generated Runtime

This folder was generated by `HV_LazyBackup_Bootstrap_Setup.ps1`.

## Daily use

Open PowerShell as Administrator, then run:

```powershell
cd C:\HV-LazyBackup
.\scripts\Backup-VM.ps1
```

The menu can run backups, verify backups, show backup history, check VM state, export VM state reports, view logs, and show settings.

## Direct commands

```powershell
.\scripts\Backup-VM.ps1 -RunBackup
.\scripts\Backup-VM.ps1 -VerifyOnly
.\scripts\Backup-VM.ps1 -CheckState
.\scripts\Backup-VM.ps1 -ExportState
.\scripts\Verify-Backup.ps1
.\scripts\Check-VMState.ps1
.\scripts\Export-VMState.ps1
```

Use `-BackupDrive X` on backup or verify commands to temporarily use `X:\VM_MASTER_BACKUP` instead of the configured backup path.
'@

# -----------------------------------------
# WRITE GENERATED SYSTEM
# -----------------------------------------
Write-Step "Writing VM helper module" {
    Write-FileUtf8 -Path $vmHelpersModulePath -Content $vmHelpersModule
}

Write-Step "Writing shared helper loader" {
    Write-FileUtf8 -Path $helpersScriptPath -Content $helpersScript
}

Write-Step "Writing backup menu engine" {
    Write-FileUtf8 -Path $backupScriptPath -Content $backupScript
}

Write-Step "Writing backup verification script" {
    Write-FileUtf8 -Path $verifyScriptPath -Content $verifyScript
}

Write-Step "Writing VM state checker" {
    Write-FileUtf8 -Path $checkStatePath -Content $checkStateScript
}

Write-Step "Writing VM state exporter" {
    Write-FileUtf8 -Path $exportStatePath -Content $exportStateScript
}

Write-Step "Writing runtime README" {
    Write-FileUtf8 -Path $runtimeReadmePath -Content $runtimeReadme
}

Write-Step "Initializing log file" {
    $firstLog = "[{0}] [INFO] HV-LazyBackup runtime generated for VM '{1}'." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $vmName
    Write-FileUtf8 -Path $logFile -Content $firstLog
}

# -----------------------------------------
# VALIDATE GENERATED SYSTEM
# -----------------------------------------
$requiredFiles = @(
    $configPath,
    $backupScriptPath,
    $verifyScriptPath,
    $checkStatePath,
    $exportStatePath,
    $helpersScriptPath,
    $vmHelpersModulePath,
    $runtimeReadmePath,
    $logFile
)

Write-Step "Running generated system validation" {
    Assert-GeneratedSystem -InstallRoot $installRoot -RequiredFiles $requiredFiles
}

# -----------------------------------------
# COMPLETE
# -----------------------------------------
Write-Host ""
Write-Host "BOOTLOADER COMPLETE" -ForegroundColor Green
Write-Host "System installed at: $installRoot"
Write-Host "Backup root:         $backupRoot"
Write-Host ""
Write-Host "Generated:"
Write-Host "  config.json"
Write-Host "  logs\log.txt"
Write-Host "  reports\"
Write-Host "  modules\VM-Helpers.psm1"
Write-Host "  scripts\Backup-VM.ps1"
Write-Host "  scripts\Verify-Backup.ps1"
Write-Host "  scripts\Check-VMState.ps1"
Write-Host "  scripts\Export-VMState.ps1"
Write-Host "  scripts\Helpers.ps1"
Write-Host ""
Write-Host "Daily use:"
Write-Host "  cd $installRoot"
Write-Host "  .\scripts\Backup-VM.ps1"
Write-Host ""
Write-Host "HV-LazyBackup is ready." -ForegroundColor Cyan
