# K3s Cluster Upgrade Script
# Performs rolling upgrade of K3s cluster to maintain availability

param(
    [Parameter(Mandatory=$true)]
    [string]$NewK3sVersion,  # e.g., "v1.31.2+k3s1"
    
    [string]$ProxyIP = "10.0.1.100",
    [string[]]$MasterIPs = @("10.0.1.10", "10.0.1.11", "10.0.1.12"),
    [string[]]$WorkerIPs = @("10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25"),
    [string]$SSHUser = "ubuntu",
    [string]$SSHKeyPath = "$HOME\.ssh\id_rsa",
    [switch]$DryRun,
    [switch]$SkipBackup,
    [int]$DrainTimeout = 300  # seconds
)

Write-Host "=== K3s Cluster Upgrade Script ===" -ForegroundColor Green
Write-Host "Target Version: $NewK3sVersion" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "DRY RUN MODE - No changes will be made" -ForegroundColor Cyan
}

# Helper functions
function Invoke-SSHCommand {
    param(
        [string]$Node,
        [string]$Command
    )
    ssh -i $SSHKeyPath -o StrictHostKeyChecking=no $SSHUser@$Node $Command
}

# Pre-upgrade checks
Write-Host "`n=== Pre-Upgrade Checks ===" -ForegroundColor Green

# Check kubectl access
$env:KUBECONFIG = "$HOME\.kube\k3s-config"
Write-Host "Checking cluster access..." -ForegroundColor Yellow
$clusterInfo = kubectl cluster-info
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Cannot access cluster. Check kubeconfig." -ForegroundColor Red
    exit 1
}

# Get current version
Write-Host "`nCurrent cluster status:" -ForegroundColor Yellow
kubectl get nodes -o wide

$currentVersion = Invoke-SSHCommand -Node $MasterIPs[0] -Command "k3s --version | grep -oP 'k3s version \K[^\s]+'"
Write-Host "`nCurrent K3s version: $currentVersion" -ForegroundColor Cyan
Write-Host "Target K3s version: $NewK3sVersion" -ForegroundColor Cyan

# Backup etcd if not skipped
if (-not $SkipBackup -and -not $DryRun) {
    Write-Host "`n=== Backing up etcd ===" -ForegroundColor Green
    $backupDate = Get-Date -Format "yyyyMMdd_HHmmss"
    
    foreach ($master in $MasterIPs) {
        Write-Host "Backing up etcd on $master..." -ForegroundColor Yellow
        $backupCmd = "sudo k3s etcd-snapshot save --name pre-upgrade-$backupDate"
        Invoke-SSHCommand -Node $master -Command $backupCmd
        
        # Verify backup
        $verifyCmd = "sudo k3s etcd-snapshot list | grep pre-upgrade-$backupDate"
        $backupVerify = Invoke-SSHCommand -Node $master -Command $verifyCmd
        if ($backupVerify) {
            Write-Host "✓ Backup successful on $master" -ForegroundColor Green
        } else {
            Write-Host "✗ Backup failed on $master" -ForegroundColor Red
            exit 1
        }
    }
}

# Create upgrade script
$upgradeScript = @'
#!/bin/bash
# K3s node upgrade script

NEW_VERSION=$1
NODE_TYPE=$2

echo "Upgrading K3s to version $NEW_VERSION"

# Stop K3s service
echo "Stopping K3s service..."
sudo systemctl stop k3s

# Download and install new version
echo "Installing K3s $NEW_VERSION..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$NEW_VERSION sh -s - $NODE_TYPE --skip-start

# Start K3s service
echo "Starting K3s service..."
sudo systemctl start k3s

# Wait for service to be ready
sleep 10

# Verify service status
if sudo systemctl is-active --quiet k3s; then
    echo "✓ K3s upgrade successful"
    k3s --version
else
    echo "✗ K3s service failed to start"
    sudo journalctl -u k3s -n 50
    exit 1
fi
'@

$upgradeScript | Out-File -FilePath "k3s-upgrade-node.sh" -Encoding UTF8
Get-Content "k3s-upgrade-node.sh" -Raw | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content "k3s-upgrade-node.sh" -NoNewline

# Function to upgrade a node
function Upgrade-Node {
    param(
        [string]$NodeIP,
        [string]$NodeType,
        [string]$NodeName
    )
    
    Write-Host "`nUpgrading $NodeType node: $NodeIP ($NodeName)" -ForegroundColor Yellow
    
    if ($NodeType -eq "worker") {
        # Cordon and drain node
        Write-Host "Cordoning node..." -ForegroundColor Cyan
        if (-not $DryRun) {
            kubectl cordon $NodeName
        }
        
        Write-Host "Draining node..." -ForegroundColor Cyan
        if (-not $DryRun) {
            kubectl drain $NodeName --ignore-daemonsets --delete-emptydir-data --force --timeout="${DrainTimeout}s"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Warning: Drain operation had issues, but continuing..." -ForegroundColor Yellow
            }
        }
    }
    
    # Copy and execute upgrade script
    Write-Host "Deploying upgrade script..." -ForegroundColor Cyan
    if (-not $DryRun) {
        scp -i $SSHKeyPath -o StrictHostKeyChecking=no "k3s-upgrade-node.sh" ${SSHUser}@${NodeIP}:/tmp/
        
        $nodeTypeParam = if ($NodeType -eq "master") { "server" } else { "agent" }
        Invoke-SSHCommand -Node $NodeIP -Command "chmod +x /tmp/k3s-upgrade-node.sh && sudo /tmp/k3s-upgrade-node.sh $NewK3sVersion $nodeTypeParam"
    }
    
    # Wait for node to be ready
    Write-Host "Waiting for node to be ready..." -ForegroundColor Cyan
    if (-not $DryRun) {
        $attempts = 0
        $maxAttempts = 30
        
        while ($attempts -lt $maxAttempts) {
            Start-Sleep -Seconds 10
            $nodeReady = kubectl get node $NodeName --no-headers | Select-String "Ready"
            if ($nodeReady -and $nodeReady -notmatch "NotReady") {
                Write-Host "✓ Node $NodeName is ready" -ForegroundColor Green
                break
            }
            $attempts++
            Write-Host "." -NoNewline
        }
        
        if ($attempts -eq $maxAttempts) {
            Write-Host "`n✗ Node $NodeName failed to become ready" -ForegroundColor Red
            exit 1
        }
    }
    
    if ($NodeType -eq "worker") {
        # Uncordon node
        Write-Host "Uncordoning node..." -ForegroundColor Cyan
        if (-not $DryRun) {
            kubectl uncordon $NodeName
        }
    }
    
    # Verify upgrade
    Write-Host "Verifying upgrade..." -ForegroundColor Cyan
    if (-not $DryRun) {
        $newVersion = Invoke-SSHCommand -Node $NodeIP -Command "k3s --version | grep -oP 'k3s version \K[^\s]+'"
        if ($newVersion -match $NewK3sVersion) {
            Write-Host "✓ Node upgraded successfully to $newVersion" -ForegroundColor Green
        } else {
            Write-Host "✗ Node version mismatch. Expected: $NewK3sVersion, Got: $newVersion" -ForegroundColor Red
        }
    }
}

# Upgrade process
Write-Host "`n=== Starting Upgrade Process ===" -ForegroundColor Green

# Step 1: Upgrade masters one by one
Write-Host "`n--- Upgrading Master Nodes ---" -ForegroundColor Cyan
foreach ($master in $MasterIPs) {
    $nodeName = kubectl get nodes -o json | ConvertFrom-Json | 
        Where-Object { $_.status.addresses | Where-Object { $_.type -eq "InternalIP" -and $_.address -eq $master } } | 
        Select-Object -ExpandProperty metadata | Select-Object -ExpandProperty name
    
    Upgrade-Node -NodeIP $master -NodeType "master" -NodeName $nodeName
    
    if (-not $DryRun) {
        Write-Host "Waiting for cluster to stabilize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        
        # Check cluster health
        $healthCheck = kubectl get nodes --no-headers | Where-Object { $_ -match "NotReady" }
        if ($healthCheck) {
            Write-Host "Warning: Some nodes are not ready. Pausing upgrade..." -ForegroundColor Yellow
            kubectl get nodes
            $continue = Read-Host "Continue with upgrade? (yes/no)"
            if ($continue -ne "yes") {
                exit 1
            }
        }
    }
}

# Step 2: Upgrade workers in batches
Write-Host "`n--- Upgrading Worker Nodes ---" -ForegroundColor Cyan
$batchSize = 2  # Upgrade 2 workers at a time

for ($i = 0; $i -lt $WorkerIPs.Count; $i += $batchSize) {
    $batch = $WorkerIPs[$i..[Math]::Min($i + $batchSize - 1, $WorkerIPs.Count - 1)]
    Write-Host "`nUpgrading worker batch: $($batch -join ', ')" -ForegroundColor Yellow
    
    foreach ($worker in $batch) {
        $nodeName = kubectl get nodes -o json | ConvertFrom-Json | 
            Where-Object { $_.status.addresses | Where-Object { $_.type -eq "InternalIP" -and $_.address -eq $worker } } | 
            Select-Object -ExpandProperty metadata | Select-Object -ExpandProperty name
        
        Upgrade-Node -NodeIP $worker -NodeType "worker" -NodeName $nodeName
    }
    
    if (-not $DryRun -and $i + $batchSize -lt $WorkerIPs.Count) {
        Write-Host "Waiting before next batch..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}

# Post-upgrade verification
Write-Host "`n=== Post-Upgrade Verification ===" -ForegroundColor Green

if (-not $DryRun) {
    Write-Host "`nCluster node status:" -ForegroundColor Yellow
    kubectl get nodes -o wide
    
    Write-Host "`nK3s versions:" -ForegroundColor Yellow
    foreach ($node in ($MasterIPs + $WorkerIPs)) {
        $version = Invoke-SSHCommand -Node $node -Command "k3s --version 2>&1 | head -1"
        Write-Host "$node : $version" -ForegroundColor White
    }
    
    Write-Host "`nSystem pod status:" -ForegroundColor Yellow
    kubectl get pods -n kube-system
    
    # Run cluster health check
    Write-Host "`nRunning cluster health check..." -ForegroundColor Yellow
    $unhealthyPods = kubectl get pods -A --no-headers | Where-Object { $_ -notmatch "Running|Completed" }
    if ($unhealthyPods) {
        Write-Host "Warning: Some pods are not healthy:" -ForegroundColor Yellow
        $unhealthyPods
    } else {
        Write-Host "✓ All system pods are healthy" -ForegroundColor Green
    }
}

# Cleanup
Remove-Item -Path "k3s-upgrade-node.sh" -ErrorAction SilentlyContinue

# Summary
Write-Host "`n=== Upgrade Summary ===" -ForegroundColor Green
if ($DryRun) {
    Write-Host "DRY RUN completed. No changes were made." -ForegroundColor Cyan
    Write-Host "To perform the actual upgrade, run without -DryRun flag" -ForegroundColor Yellow
} else {
    Write-Host "✓ Cluster upgrade completed!" -ForegroundColor Green
    Write-Host @"

Post-Upgrade Checklist:
1. ✓ All nodes upgraded to $NewK3sVersion
2. □ Test application functionality
3. □ Verify storage system (NFS) is working
4. □ Check monitoring and alerting
5. □ Update documentation with new version
6. □ Plan rollback procedure if issues arise

Rollback Instructions:
If you need to rollback, use the etcd snapshots created:
  - Snapshots are stored on each master in /var/lib/rancher/k3s/server/db/snapshots/
  - Restore with: k3s server --cluster-reset --etcd-restore=<snapshot-name>

"@ -ForegroundColor Cyan
}