# K3s Add Node to Cluster Script
# Supports adding both control plane and worker nodes to existing cluster

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("control-plane", "worker")]
    [string]$NodeType,
    
    [Parameter(Mandatory=$true)]
    [string]$NewNodeIP,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "../cluster.json"
)

Write-Host "=== K3s Add Node to Cluster ===" -ForegroundColor Green
Write-Host "Node Type: $NodeType" -ForegroundColor Yellow
Write-Host "New Node IP: $NewNodeIP" -ForegroundColor Yellow

#########################################
# CONFIGURATION LOADING
#########################################

# Import cluster management module
Import-Module "$PSScriptRoot\..\lib\K3sCluster.psm1" -Force

# Load configuration
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$Config = Load-ClusterConfig -ConfigPath $ConfigFile

# Helper functions (now using shared module functions)

# Get cluster information
Write-Host "`nGathering cluster information..." -ForegroundColor Cyan

# Get K3s token from first control plane node
$existingControlPlaneIP = $Config.ControlPlaneIPs[0]
$k3sToken = Invoke-SSHCommand -Config $Config -Node $existingControlPlaneIP -Command "sudo cat /var/lib/rancher/k3s/server/node-token"
if ([string]::IsNullOrEmpty($k3sToken)) {
    Write-Host "Error: Could not retrieve K3s token from control plane node" -ForegroundColor Red
    exit 1
}

# Get K3s version from config (or detect from cluster)
$k3sVersion = $Config.K3sVersion
if ([string]::IsNullOrEmpty($k3sVersion)) {
    $k3sVersion = Invoke-SSHCommand -Config $Config -Node $existingControlPlaneIP -Command "k3s --version | grep -oP 'k3s version \K[^\s]+'"
}
Write-Host "Using K3s version: $k3sVersion" -ForegroundColor Green

# Create setup script based on node type
if ($NodeType -eq "control-plane") {
    Write-Host "`nPreparing control plane node setup..." -ForegroundColor Cyan
    
    # Get current control plane count
    $env:KUBECONFIG = "$HOME\.kube\k3s-config"
    $controlPlaneCount = (kubectl get nodes -l node-role.kubernetes.io/control-plane=true --no-headers | Measure-Object).Count + 1
    
    # Update Nginx proxy configuration
    Write-Host "Updating Nginx proxy configuration..." -ForegroundColor Yellow
    
    $nginxUpdateScript = @"
#!/bin/bash
# Add new control plane node to Nginx upstream

# Backup current config
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.\$(date +%Y%m%d_%H%M%S)

# Add new server to upstream
sudo sed -i '/upstream k3s_api {/,/}/ s/}$/    server $NewNodeIP:6443 max_fails=3 fail_timeout=5s;\n}/' /etc/nginx/nginx.conf

# Test configuration
if sudo nginx -t; then
    sudo nginx -s reload
    echo "Nginx configuration updated successfully"
else
    echo "Error in Nginx configuration, reverting..."
    sudo cp /etc/nginx/nginx.conf.bak.\$(date +%Y%m%d_%H%M%S) /etc/nginx/nginx.conf
    exit 1
fi
"@
    
    $nginxUpdateScript | Out-File -FilePath "update-nginx.sh" -Encoding UTF8
    Get-Content "update-nginx.sh" -Raw | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content "update-nginx.sh" -NoNewline
    
    Copy-FileToNode -Config $Config -Node $ProxyIP -LocalPath "update-nginx.sh" -RemotePath "/tmp/update-nginx.sh"
    Invoke-SSHCommand -Config $Config -Node $ProxyIP -Command "chmod +x /tmp/update-nginx.sh && /tmp/update-nginx.sh"
    
    # Create control plane setup script
    $controlPlaneSetupScript = @"
#!/bin/bash
# Add new control plane node to K3s cluster

echo "Setting up new K3s control plane node"

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl wget nfs-kernel-server nfs-common open-iscsi iptables

# Configure kernel parameters
cat > /etc/sysctl.d/k3s.conf << EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
EOF
sysctl -p /etc/sysctl.d/k3s.conf

# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Setup storage for NFS
if [ -b "$StorageDevice" ]; then
    echo "Setting up NFS storage on $StorageDevice"
    parted -s $StorageDevice mklabel gpt
    parted -s $StorageDevice mkpart primary ext4 0% 100%
    sleep 2
    mkfs.ext4 -F ${StorageDevice}1
    mkdir -p $NFSMountPath
    echo "${StorageDevice}1 $NFSMountPath ext4 defaults,noatime 0 2" >> /etc/fstab
    mount $NFSMountPath
    
    # Create NFS directories
    mkdir -p $NFSMountPath/{shared,data,backups}
    chmod 777 $NFSMountPath/{shared,data,backups}
fi

# Configure NFS exports
cat > /etc/exports << EOF
$NFSMountPath/shared  10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
$NFSMountPath/data    10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
$NFSMountPath/backups 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra

# Install K3s
echo "Installing K3s control plane node (this may take a few minutes)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$k3sVersion sh -s - server \
    --server https://$ExistingControlPlaneIP:6443 \
    --token=$k3sToken \
    --tls-san=$ProxyIP \
    --tls-san=$NewNodeIP \
    --disable=traefik \
    --write-kubeconfig-mode=644

echo "New control plane node setup complete!"
"@
    
    $setupScriptPath = "setup-new-control-plane.sh"
    
} else {
    Write-Host "`nPreparing worker node setup..." -ForegroundColor Cyan
    
    # Create worker setup script
    $workerSetupScript = @"
#!/bin/bash
# Add new worker node to K3s cluster

echo "Setting up new K3s worker node"

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl wget nfs-common open-iscsi iptables

# Configure kernel parameters
cat > /etc/sysctl.d/k3s.conf << EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
EOF
sysctl -p /etc/sysctl.d/k3s.conf

# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Install K3s agent
echo "Installing K3s worker (this may take a few minutes)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$k3sVersion sh -s - agent \
    --server https://$ProxyIP:6443 \
    --token=$k3sToken

echo "New worker node setup complete!"
"@
    
    $setupScriptPath = "setup-new-worker.sh"
}

# Save and deploy setup script
if ($NodeType -eq "control-plane") {
    $controlPlaneSetupScript | Out-File -FilePath $setupScriptPath -Encoding UTF8
} else {
    $workerSetupScript | Out-File -FilePath $setupScriptPath -Encoding UTF8
}

Get-Content $setupScriptPath -Raw | ForEach-Object { $_ -replace "`r`n", "`n" } | Set-Content $setupScriptPath -NoNewline

Write-Host "`nDeploying setup script to new node..." -ForegroundColor Yellow
Copy-FileToNode -Config $Config -Node $NewNodeIP -LocalPath $setupScriptPath -RemotePath "/tmp/$setupScriptPath"

Write-Host "Running setup on new node (this may take several minutes)..." -ForegroundColor Yellow
Invoke-SSHCommand -Config $Config -Node $NewNodeIP -Command "chmod +x /tmp/$setupScriptPath && sudo /tmp/$setupScriptPath"

# Wait for node to join
Write-Host "`nWaiting for node to join cluster..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Verify node joined
$env:KUBECONFIG = "$HOME\.kube\k3s-config"
Write-Host "`nVerifying node status..." -ForegroundColor Yellow
kubectl get nodes | Select-String $NewNodeIP

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Node successfully added to cluster!" -ForegroundColor Green
    
    # Label control plane nodes
    if ($NodeType -eq "control-plane") {
        Write-Host "Applying control plane labels..." -ForegroundColor Yellow
        kubectl label node $NewNodeIP node-role.kubernetes.io/master=true --overwrite
        kubectl label node $NewNodeIP node-role.kubernetes.io/control-plane=true --overwrite
    }
    
    # Show final cluster state
    Write-Host "`nCurrent cluster state:" -ForegroundColor Cyan
    kubectl get nodes -o wide
    
} else {
    Write-Host "`n✗ Node failed to join cluster. Check logs on the new node:" -ForegroundColor Red
    Write-Host "  ssh $SSHUser@$NewNodeIP 'sudo journalctl -u k3s -n 50'" -ForegroundColor Yellow
}

# Cleanup
Remove-Item -Path $setupScriptPath, "update-nginx.sh" -ErrorAction SilentlyContinue

# Post-addition tasks
Write-Host "`n=== Post-Addition Tasks ===" -ForegroundColor Green
Write-Host @"

For Control Plane Nodes:
1. Update monitoring to include new control plane node
2. Update backup scripts to include new control plane node's etcd
3. Test NFS exports: showmount -e $NewNodeIP
4. Update documentation with new topology

For Worker Nodes:
1. Apply any required node labels or taints
2. Test application deployment on new node
3. Update load balancer configurations if needed

Next Steps:
- Monitor node health: kubectl top node $NewNodeIP
- Check system logs: ssh $SSHUser@$NewNodeIP 'sudo journalctl -u k3s -f'
- Deploy test workload to verify functionality

"@ -ForegroundColor Cyan