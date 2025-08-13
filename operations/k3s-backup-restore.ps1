# K3s Backup and Restore Script
# Comprehensive backup solution for K3s clusters

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("backup", "restore", "list", "schedule")]
    [string]$Operation,
    
    [string[]]$MasterIPs = @("10.0.1.10", "10.0.1.11", "10.0.1.12"),
    [string]$BackupLocation = "\\fileserver\k3s-backups",  # Or local path
    [string]$RestoreSnapshot,  # For restore operation
    [string]$SSHUser = "ubuntu",
    [string]$SSHKeyPath = "$HOME\.ssh\id_rsa",
    [switch]$IncludeNFSData,
    [switch]$IncludeWorkloads
)

Write-Host "=== K3s Backup and Restore Script ===" -ForegroundColor Green
Write-Host "Operation: $Operation" -ForegroundColor Yellow

# Helper functions
function Invoke-SSHCommand {
    param(
        [string]$Node,
        [string]$Command
    )
    ssh -i $SSHKeyPath -o StrictHostKeyChecking=no $SSHUser@$Node $Command
}

function Copy-FileFromNode {
    param(
        [string]$Node,
        [string]$RemotePath,
        [string]$LocalPath
    )
    scp -i $SSHKeyPath -o StrictHostKeyChecking=no ${SSHUser}@${Node}:${RemotePath} $LocalPath
}

function Copy-FileToNode {
    param(
        [string]$Node,
        [string]$LocalPath,
        [string]$RemotePath
    )
    scp -i $SSHKeyPath -o StrictHostKeyChecking=no $LocalPath ${SSHUser}@${Node}:${RemotePath}
}

# Create backup directory structure
$backupDate = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = Join-Path $BackupLocation "k3s-backup-$backupDate"

# Backup script for nodes
$backupScript = @'
#!/bin/bash
# K3s node backup script

BACKUP_NAME=$1
INCLUDE_NFS=$2

echo "Starting K3s backup..."

# Create backup directory
BACKUP_DIR="/tmp/k3s-backup-$$"
mkdir -p "$BACKUP_DIR"

# Backup etcd
echo "Creating etcd snapshot..."
sudo k3s etcd-snapshot save --name "$BACKUP_NAME"
sudo cp /var/lib/rancher/k3s/server/db/snapshots/"$BACKUP_NAME"* "$BACKUP_DIR/"

# Backup K3s configuration
echo "Backing up K3s configuration..."
sudo tar -czf "$BACKUP_DIR/k3s-config.tar.gz" \
    /etc/rancher/k3s/k3s.yaml \
    /etc/systemd/system/k3s.service \
    /etc/systemd/system/k3s.service.env \
    /var/lib/rancher/k3s/server/node-token \
    /var/lib/rancher/k3s/server/tls 2>/dev/null || true

# Backup NFS exports configuration
if [ -f /etc/exports ]; then
    echo "Backing up NFS configuration..."
    sudo cp /etc/exports "$BACKUP_DIR/"
fi

# Backup NFS data if requested
if [ "$INCLUDE_NFS" = "true" ] && [ -d /data/nfs ]; then
    echo "Backing up NFS data (this may take a while)..."
    sudo tar -czf "$BACKUP_DIR/nfs-data.tar.gz" /data/nfs/
fi

# Create manifest of backup contents
cat > "$BACKUP_DIR/backup-manifest.txt" << EOF
Backup Date: $(date)
Hostname: $(hostname)
K3s Version: $(k3s --version 2>&1 | head -1)
Backup Contents:
- etcd snapshot: $BACKUP_NAME
- K3s configuration
- NFS configuration
EOF

if [ "$INCLUDE_NFS" = "true" ]; then
    echo "- NFS data" >> "$BACKUP_DIR/backup-manifest.txt"
fi

# Create final archive
echo "Creating backup archive..."
cd /tmp
sudo tar -czf "k3s-backup-$$.tar.gz" "k3s-backup-$$"

echo "Backup completed: /tmp/k3s-backup-$$.tar.gz"
'@

# Restore script for nodes
$restoreScript = @'
#!/bin/bash
# K3s node restore script

RESTORE_FILE=$1
SNAPSHOT_NAME=$2

echo "Starting K3s restore..."

# Extract backup
RESTORE_DIR="/tmp/k3s-restore-$$"
mkdir -p "$RESTORE_DIR"
tar -xzf "$RESTORE_FILE" -C /tmp/

# Find extracted directory
EXTRACT_DIR=$(find /tmp -maxdepth 1 -name "k3s-backup-*" -type d | head -1)

if [ -z "$EXTRACT_DIR" ]; then
    echo "Error: Could not find extracted backup directory"
    exit 1
fi

# Stop K3s
echo "Stopping K3s service..."
sudo systemctl stop k3s

# Restore configuration
echo "Restoring K3s configuration..."
cd "$EXTRACT_DIR"
sudo tar -xzf k3s-config.tar.gz -C /

# Restore etcd snapshot
echo "Restoring etcd snapshot..."
SNAPSHOT_FILE=$(find . -name "$SNAPSHOT_NAME*" -type f | head -1)
if [ -n "$SNAPSHOT_FILE" ]; then
    sudo k3s server \
        --cluster-reset \
        --etcd-restore="$SNAPSHOT_FILE" \
        --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/etcd-old-$(date +%s)
else
    echo "Error: Snapshot file not found"
    exit 1
fi

# Restore NFS configuration
if [ -f "exports" ]; then
    echo "Restoring NFS configuration..."
    sudo cp exports /etc/exports
    sudo exportfs -ra
fi

# Start K3s
echo "Starting K3s service..."
sudo systemctl start k3s

echo "Restore completed. Please verify cluster health."
'@

# Schedule script for automated backups
$scheduleScript = @'
#!/bin/bash
# Setup automated K3s backups

cat > /etc/cron.d/k3s-backup << 'EOF'
# K3s automated backup - daily at 2 AM
0 2 * * * root /usr/local/bin/k3s etcd-snapshot save --name auto-$(date +\%Y\%m\%d-\%H\%M\%S) && find /var/lib/rancher/k3s/server/db/snapshots -name "auto-*" -mtime +7 -delete
EOF

chmod 644 /etc/cron.d/k3s-backup
echo "✓ Automated backup scheduled"
'@

# Save scripts
$backupScript | Out-File -FilePath "k3s-backup.sh" -Encoding UTF8
$restoreScript | Out-File -FilePath "k3s-restore.sh" -Encoding UTF8
$scheduleScript | Out-File -FilePath "k3s-schedule-backup.sh" -Encoding UTF8

Get-Content "*.sh" | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content $_ -NoNewline

# Operations
switch ($Operation) {
    "backup" {
        Write-Host "`n=== Creating K3s Backup ===" -ForegroundColor Green
        
        # Create backup directory
        if (-not (Test-Path $BackupLocation)) {
            New-Item -ItemType Directory -Path $BackupLocation -Force | Out-Null
        }
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
        
        # Backup from each master
        foreach ($master in $MasterIPs) {
            Write-Host "`nBacking up master $master..." -ForegroundColor Yellow
            
            $backupName = "manual-backup-$backupDate"
            $includeNFS = if ($IncludeNFSData) { "true" } else { "false" }
            
            # Copy and execute backup script
            Copy-FileToNode -Node $master -LocalPath "k3s-backup.sh" -RemotePath "/tmp/k3s-backup.sh"
            Invoke-SSHCommand -Node $master -Command "chmod +x /tmp/k3s-backup.sh && sudo /tmp/k3s-backup.sh $backupName $includeNFS"
            
            # Download backup
            $remoteBackup = Invoke-SSHCommand -Node $master -Command "ls -t /tmp/k3s-backup-*.tar.gz | head -1"
            if ($remoteBackup) {
                $localBackup = Join-Path $backupPath "master-$master-backup.tar.gz"
                Copy-FileFromNode -Node $master -RemotePath $remoteBackup -LocalPath $localBackup
                Write-Host "✓ Backup saved to $localBackup" -ForegroundColor Green
                
                # Cleanup remote backup
                Invoke-SSHCommand -Node $master -Command "sudo rm -f $remoteBackup"
            }
        }
        
        # Backup workloads if requested
        if ($IncludeWorkloads) {
            Write-Host "`nBacking up Kubernetes workloads..." -ForegroundColor Yellow
            
            $env:KUBECONFIG = "$HOME\.kube\k3s-config"
            
            # Get all namespaces
            $namespaces = kubectl get namespaces -o json | ConvertFrom-Json | 
                ForEach-Object { $_.items } | 
                Where-Object { $_.metadata.name -notmatch "^kube-|^default$" } |
                Select-Object -ExpandProperty metadata -ExpandProperty name
            
            $workloadsPath = Join-Path $backupPath "workloads"
            New-Item -ItemType Directory -Path $workloadsPath -Force | Out-Null
            
            foreach ($ns in $namespaces) {
                Write-Host "  Backing up namespace: $ns" -ForegroundColor White
                $nsPath = Join-Path $workloadsPath $ns
                New-Item -ItemType Directory -Path $nsPath -Force | Out-Null
                
                # Export all resources in namespace
                kubectl get all,pvc,configmap,secret,ingress -n $ns -o yaml | 
                    Out-File -FilePath (Join-Path $nsPath "resources.yaml") -Encoding UTF8
            }
            
            Write-Host "✓ Workloads backed up" -ForegroundColor Green
        }
        
        # Create backup summary
        $summary = @"
K3s Cluster Backup Summary
========================
Date: $(Get-Date)
Location: $backupPath
Masters Backed Up: $($MasterIPs -join ', ')
Include NFS Data: $IncludeNFSData
Include Workloads: $IncludeWorkloads

Backup Contents:
"@
        Get-ChildItem $backupPath -Recurse | ForEach-Object {
            $summary += "`n  - $($_.FullName.Replace($backupPath, '.'))"
        }
        
        $summary | Out-File -FilePath (Join-Path $backupPath "backup-summary.txt") -Encoding UTF8
        Write-Host "`n$summary" -ForegroundColor Cyan
    }
    
    "restore" {
        if ([string]::IsNullOrEmpty($RestoreSnapshot)) {
            Write-Host "Error: -RestoreSnapshot parameter is required for restore operation" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "`n=== K3s Restore Operation ===" -ForegroundColor Green
        Write-Host "WARNING: This will restore the cluster to a previous state!" -ForegroundColor Yellow
        Write-Host "Restore snapshot: $RestoreSnapshot" -ForegroundColor White
        
        $confirm = Read-Host "`nAre you sure you want to proceed? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "Restore cancelled." -ForegroundColor Yellow
            exit 0
        }
        
        # Find backup file
        $backupFile = Get-ChildItem $BackupLocation -Filter "*$RestoreSnapshot*" -Recurse | 
            Select-Object -First 1
        
        if (-not $backupFile) {
            Write-Host "Error: Backup file not found for snapshot: $RestoreSnapshot" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Found backup: $($backupFile.FullName)" -ForegroundColor Green
        
        # Restore on first master
        $primaryMaster = $MasterIPs[0]
        Write-Host "`nRestoring on primary master $primaryMaster..." -ForegroundColor Yellow
        
        # Copy backup and restore script
        Copy-FileToNode -Node $primaryMaster -LocalPath $backupFile.FullName -RemotePath "/tmp/restore-backup.tar.gz"
        Copy-FileToNode -Node $primaryMaster -LocalPath "k3s-restore.sh" -RemotePath "/tmp/k3s-restore.sh"
        
        # Execute restore
        Invoke-SSHCommand -Node $primaryMaster -Command "chmod +x /tmp/k3s-restore.sh && sudo /tmp/k3s-restore.sh /tmp/restore-backup.tar.gz $RestoreSnapshot"
        
        Write-Host "`n⚠️  Restore initiated. The cluster will restart." -ForegroundColor Yellow
        Write-Host "Monitor the cluster health and rejoin other masters if needed." -ForegroundColor Yellow
    }
    
    "list" {
        Write-Host "`n=== Available Backups ===" -ForegroundColor Green
        
        # List backups in backup location
        if (Test-Path $BackupLocation) {
            $backups = Get-ChildItem $BackupLocation -Directory | Sort-Object Name -Descending
            
            if ($backups.Count -eq 0) {
                Write-Host "No backups found in $BackupLocation" -ForegroundColor Yellow
            } else {
                foreach ($backup in $backups) {
                    Write-Host "`nBackup: $($backup.Name)" -ForegroundColor Cyan
                    
                    $summaryFile = Join-Path $backup.FullName "backup-summary.txt"
                    if (Test-Path $summaryFile) {
                        Get-Content $summaryFile | Select-Object -Skip 3 -First 5 | ForEach-Object {
                            Write-Host "  $_" -ForegroundColor White
                        }
                    }
                }
            }
        }
        
        # List snapshots on masters
        Write-Host "`n=== etcd Snapshots on Masters ===" -ForegroundColor Green
        foreach ($master in $MasterIPs) {
            Write-Host "`nMaster $master snapshots:" -ForegroundColor Yellow
            $snapshots = Invoke-SSHCommand -Node $master -Command "sudo k3s etcd-snapshot list 2>/dev/null | tail -n +2"
            if ($snapshots) {
                Write-Host $snapshots -ForegroundColor White
            } else {
                Write-Host "  No snapshots found" -ForegroundColor Gray
            }
        }
    }
    
    "schedule" {
        Write-Host "`n=== Scheduling Automated Backups ===" -ForegroundColor Green
        
        foreach ($master in $MasterIPs) {
            Write-Host "`nConfiguring automated backups on $master..." -ForegroundColor Yellow
            
            Copy-FileToNode -Node $master -LocalPath "k3s-schedule-backup.sh" -RemotePath "/tmp/k3s-schedule-backup.sh"
            Invoke-SSHCommand -Node $master -Command "chmod +x /tmp/k3s-schedule-backup.sh && sudo /tmp/k3s-schedule-backup.sh"
        }
        
        Write-Host "`n✓ Automated backups configured" -ForegroundColor Green
        Write-Host @"

Backup Schedule:
- Daily snapshots at 2 AM
- Snapshots retained for 7 days
- Location: /var/lib/rancher/k3s/server/db/snapshots/

To modify schedule, edit: /etc/cron.d/k3s-backup on each master

"@ -ForegroundColor Cyan
    }
}

# Cleanup
Remove-Item -Path "k3s-backup.sh", "k3s-restore.sh", "k3s-schedule-backup.sh" -ErrorAction SilentlyContinue

# Best practices
if ($Operation -eq "backup") {
    Write-Host "`n=== Backup Best Practices ===" -ForegroundColor Green
    Write-Host @"

1. Regular Backups:
   - Daily automated snapshots (use -Operation schedule)
   - Weekly full backups with NFS data
   - Monthly off-site backup copies

2. Backup Retention:
   - Keep daily backups for 7 days
   - Keep weekly backups for 4 weeks
   - Keep monthly backups for 6 months

3. Test Restores:
   - Regularly test restore procedures
   - Document restore time objectives (RTO)
   - Maintain restore runbooks

4. Backup Verification:
   - Check backup logs for errors
   - Verify backup file integrity
   - Monitor backup storage usage

"@ -ForegroundColor Cyan
}