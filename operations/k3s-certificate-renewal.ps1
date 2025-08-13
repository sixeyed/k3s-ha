# K3s Certificate Renewal Script
# Handles certificate rotation for K3s cluster

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "../cluster.json",
    
    [switch]$CheckOnly,
    [switch]$Force
)

Write-Host "=== K3s Certificate Renewal Script ===" -ForegroundColor Green

#########################################
# CONFIGURATION LOADING
#########################################

# Import configuration module
Import-Module "$PSScriptRoot\..\lib\K3sCluster.psm1" -Force

# Load configuration
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$Config = Load-ClusterConfig -ConfigPath $ConfigFile

# Certificate check script
$certCheckScript = @'
#!/bin/bash
# Check K3s certificate expiration dates

echo "=== K3s Certificate Status ==="

# Function to check certificate
check_cert() {
    local cert_file=$1
    local cert_name=$2
    
    if [ -f "$cert_file" ]; then
        expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
        expiry_epoch=$(date -d "$expiry_date" +%s)
        current_epoch=$(date +%s)
        days_left=$(( ($expiry_epoch - $current_epoch) / 86400 ))
        
        if [ $days_left -lt 30 ]; then
            echo "⚠️  $cert_name: Expires in $days_left days ($expiry_date)"
        elif [ $days_left -lt 90 ]; then
            echo "⚡ $cert_name: Expires in $days_left days ($expiry_date)"
        else
            echo "✓  $cert_name: Valid for $days_left days ($expiry_date)"
        fi
    else
        echo "✗  $cert_name: Certificate not found at $cert_file"
    fi
}

# K3s certificate locations
K3S_DATA="/var/lib/rancher/k3s"

# Server certificates
if [ -d "$K3S_DATA/server" ]; then
    echo -e "\nServer Certificates:"
    check_cert "$K3S_DATA/server/tls/serving-kube-apiserver.crt" "API Server"
    check_cert "$K3S_DATA/server/tls/client-kube-apiserver.crt" "API Server Client"
    check_cert "$K3S_DATA/server/tls/client-controller.crt" "Controller Client"
    check_cert "$K3S_DATA/server/tls/client-scheduler.crt" "Scheduler Client"
    check_cert "$K3S_DATA/server/tls/client-kube-proxy.crt" "Kube Proxy Client"
    check_cert "$K3S_DATA/server/tls/client-k3s-controller.crt" "K3s Controller"
    check_cert "$K3S_DATA/server/tls/serving-kubelet.crt" "Kubelet Server"
    check_cert "$K3S_DATA/server/tls/client-kubelet.crt" "Kubelet Client"
    check_cert "$K3S_DATA/server/tls/etcd/server-ca.crt" "etcd CA"
    check_cert "$K3S_DATA/server/tls/etcd/server.crt" "etcd Server"
fi

# Agent certificates
echo -e "\nAgent Certificates:"
check_cert "$K3S_DATA/agent/client-ca.crt" "Client CA"
check_cert "$K3S_DATA/agent/client-kubelet.crt" "Kubelet Client"
check_cert "$K3S_DATA/agent/serving-kubelet.crt" "Kubelet Serving"

# Get certificate rotation status
echo -e "\nCertificate Rotation Configuration:"
if systemctl is-active --quiet k3s; then
    k3s_args=$(systemctl show -p ExecStart k3s | grep -oP 'ExecStart=.*')
    if echo "$k3s_args" | grep -q "certificate-rotation"; then
        echo "✓ Automatic certificate rotation is enabled"
    else
        echo "✗ Automatic certificate rotation is NOT enabled"
        echo "  To enable, add '--certificate-rotation=true' to K3s server args"
    fi
else
    echo "⚠️  K3s service is not running"
fi
'@

# Certificate renewal script
$certRenewalScript = @'
#!/bin/bash
# Renew K3s certificates

echo "=== K3s Certificate Renewal ==="

# Backup current certificates
BACKUP_DIR="/var/lib/rancher/k3s/server/tls-backup-$(date +%Y%m%d-%H%M%S)"
K3S_DIR="/var/lib/rancher/k3s"

echo "Creating backup of current certificates..."
if [ -d "$K3S_DIR/server/tls" ]; then
    sudo mkdir -p "$BACKUP_DIR"
    sudo cp -r "$K3S_DIR/server/tls" "$BACKUP_DIR/"
    echo "✓ Certificates backed up to $BACKUP_DIR"
fi

# Method 1: Restart K3s to trigger certificate rotation
echo -e "\nRestarting K3s to trigger certificate renewal..."
sudo systemctl stop k3s
sleep 5

# Remove dynamic certificates to force regeneration
echo "Removing dynamic certificates..."
sudo rm -f $K3S_DIR/server/tls/dynamic-cert.json
sudo rm -f $K3S_DIR/agent/client-kubelet.crt
sudo rm -f $K3S_DIR/agent/client-kubelet.key
sudo rm -f $K3S_DIR/agent/serving-kubelet.crt
sudo rm -f $K3S_DIR/agent/serving-kubelet.key

# Start K3s
sudo systemctl start k3s

# Wait for service to be ready
echo "Waiting for K3s to start..."
sleep 30

# Verify service is running
if sudo systemctl is-active --quiet k3s; then
    echo "✓ K3s service is running"
else
    echo "✗ K3s service failed to start"
    echo "  Restoring certificates from backup..."
    sudo cp -r "$BACKUP_DIR/tls" "$K3S_DIR/server/"
    sudo systemctl start k3s
    exit 1
fi

echo -e "\n✓ Certificate renewal completed"
echo "  Backup stored at: $BACKUP_DIR"
echo "  Run certificate check to verify new expiration dates"
'@

# Save scripts
$certCheckScript | Out-File -FilePath "check-certs.sh" -Encoding UTF8
$certRenewalScript | Out-File -FilePath "renew-certs.sh" -Encoding UTF8

Get-Content "check-certs.sh" -Raw | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content "check-certs.sh" -NoNewline
Get-Content "renew-certs.sh" -Raw | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content "renew-certs.sh" -NoNewline

# Check certificates on all nodes
Write-Host "`n=== Checking Certificate Status ===" -ForegroundColor Green

$allNodes = $Config.MasterIPs + $Config.WorkerIPs
$nodesNeedingRenewal = @()

foreach ($node in $allNodes) {
    Write-Host "`nChecking certificates on $node..." -ForegroundColor Yellow
    
    Copy-FileToNode -Config $Config -Node $node -LocalPath "check-certs.sh" -RemotePath "/tmp/check-certs.sh"
    $certStatus = Invoke-SSHCommand -Node $node -Command "chmod +x /tmp/check-certs.sh && sudo /tmp/check-certs.sh"
    
    Write-Host $certStatus
    
    # Check if any certificates need renewal (less than 30 days)
    if ($certStatus -match "⚠️") {
        $nodesNeedingRenewal += $node
    }
}

if ($CheckOnly) {
    Write-Host "`n=== Certificate Check Complete ===" -ForegroundColor Green
    if ($nodesNeedingRenewal.Count -gt 0) {
        Write-Host "Nodes needing certificate renewal: $($nodesNeedingRenewal -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "All certificates are valid for more than 30 days" -ForegroundColor Green
    }
    
    # Cleanup
    Remove-Item -Path "check-certs.sh", "renew-certs.sh" -ErrorAction SilentlyContinue
    exit 0
}

# Renewal process
if ($nodesNeedingRenewal.Count -eq 0 -and -not $Force) {
    Write-Host "`n✓ All certificates are valid. No renewal needed." -ForegroundColor Green
    Write-Host "Use -Force flag to force renewal anyway." -ForegroundColor Yellow
} else {
    if ($Force) {
        Write-Host "`n=== Forcing Certificate Renewal ===" -ForegroundColor Yellow
        $nodesNeedingRenewal = $allNodes
    } else {
        Write-Host "`n=== Certificate Renewal Required ===" -ForegroundColor Yellow
        Write-Host "Nodes needing renewal: $($nodesNeedingRenewal -join ', ')" -ForegroundColor White
    }
    
    $confirm = Read-Host "`nProceed with certificate renewal? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Certificate renewal cancelled." -ForegroundColor Yellow
        exit 0
    }
    
    # Renew certificates on master nodes first
    Write-Host "`n--- Renewing Master Node Certificates ---" -ForegroundColor Cyan
    foreach ($master in $Config.MasterIPs) {
        if ($nodesNeedingRenewal -contains $master -or $Force) {
            Write-Host "`nRenewing certificates on master $master..." -ForegroundColor Yellow
            
            Copy-FileToNode -Config $Config -Node $master -LocalPath "renew-certs.sh" -RemotePath "/tmp/renew-certs.sh"
            Invoke-SSHCommand -Config $Config -Node $master -Command "chmod +x /tmp/renew-certs.sh && sudo /tmp/renew-certs.sh"
            
            # Wait for cluster to stabilize
            Start-Sleep -Seconds 30
            
            # Verify master is healthy
            $masterHealth = Invoke-SSHCommand -Node $master -Command "sudo k3s kubectl get nodes | grep $(hostname)"
            if ($masterHealth -match "Ready") {
                Write-Host "✓ Master $master is healthy after renewal" -ForegroundColor Green
            } else {
                Write-Host "✗ Master $master health check failed" -ForegroundColor Red
            }
        }
    }
    
    # Renew certificates on worker nodes
    Write-Host "`n--- Renewing Worker Node Certificates ---" -ForegroundColor Cyan
    foreach ($worker in $Config.WorkerIPs) {
        if ($nodesNeedingRenewal -contains $worker -or $Force) {
            Write-Host "`nRenewing certificates on worker $worker..." -ForegroundColor Yellow
            
            Copy-FileToNode -Config $Config -Node $worker -LocalPath "renew-certs.sh" -RemotePath "/tmp/renew-certs.sh"
            Invoke-SSHCommand -Config $Config -Node $worker -Command "chmod +x /tmp/renew-certs.sh && sudo /tmp/renew-certs.sh"
            
            Start-Sleep -Seconds 10
        }
    }
    
    # Verify renewal
    Write-Host "`n=== Verifying Certificate Renewal ===" -ForegroundColor Green
    Start-Sleep -Seconds 30
    
    foreach ($node in $nodesNeedingRenewal) {
        Write-Host "`nVerifying certificates on $node..." -ForegroundColor Yellow
        $newCertStatus = Invoke-SSHCommand -Node $node -Command "sudo /tmp/check-certs.sh | grep -E '(API Server|Kubelet)' | head -5"
        Write-Host $newCertStatus
    }
}

# Update kubeconfig if needed
Write-Host "`n=== Updating Local Kubeconfig ===" -ForegroundColor Green
$kubeconfigPath = "$HOME\.kube\k3s-config"
$backupPath = "$HOME\.kube\k3s-config.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"

if (Test-Path $kubeconfigPath) {
    Write-Host "Backing up current kubeconfig to $backupPath" -ForegroundColor Yellow
    Copy-Item $kubeconfigPath $backupPath
    
    Write-Host "Fetching updated kubeconfig from master..." -ForegroundColor Yellow
    Copy-FileFromNode -Config $Config -Node $Config.MasterIPs[0] -RemotePath "/etc/rancher/k3s/k3s.yaml" -LocalPath "$kubeconfigPath.new"
    
    # Update server URL to use proxy
    $content = Get-Content "$kubeconfigPath.new" -Raw
    $content = $content -replace 'https://127.0.0.1:6443', "https://$($Config.ProxyIP):6443"
    $content | Set-Content $kubeconfigPath
    
    Remove-Item "$kubeconfigPath.new"
    Write-Host "✓ Kubeconfig updated" -ForegroundColor Green
}

# Cleanup
Remove-Item -Path "check-certs.sh", "renew-certs.sh" -ErrorAction SilentlyContinue

# Summary
Write-Host "`n=== Certificate Renewal Summary ===" -ForegroundColor Green
Write-Host @"

Certificate Management Tips:
1. Enable automatic rotation by adding to K3s server args:
   --certificate-rotation=true
   
2. Schedule regular certificate checks:
   .\k3s-certificate-renewal.ps1 -CheckOnly
   
3. K3s automatically rotates certificates 90 days before expiry
   when certificate-rotation is enabled
   
4. Certificate locations:
   - Server: /var/lib/rancher/k3s/server/tls/
   - Agent: /var/lib/rancher/k3s/agent/
   
5. Monitor certificate expiration with:
   kubectl get certificates -A
   kubectl get csr

Next Steps:
□ Test cluster connectivity
□ Verify all applications are working
□ Update monitoring alerts for certificate expiration
□ Document renewal date

"@ -ForegroundColor Cyan