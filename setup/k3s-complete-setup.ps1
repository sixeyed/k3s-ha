# Complete K3s HA Cluster Setup with Nginx Proxy and NFS Storage
# Architecture: 1 Nginx Proxy + 3 Control Plane (with NFS) + 6 Worker Nodes

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "cluster.json"
)

#########################################
# CONFIGURATION LOADING
#########################################

# Import configuration module
Import-Module "$PSScriptRoot\..\lib\K3sCluster.psm1" -Force

# Load configuration
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$Config = Load-ClusterConfig -ConfigPath $ConfigFile

# Helper functions (now using shared module functions)

#########################################
# NGINX PROXY CONFIGURATION
#########################################

$NginxConfig = @'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

stream {
    log_format k3s_log '$remote_addr [$time_local] '
                       '$protocol $status $bytes_sent $bytes_received '
                       '$session_time "$upstream_addr"';
    
    access_log /var/log/nginx/k3s-access.log k3s_log;
    
    upstream k3s_api {
        least_conn;
        ###MASTER_SERVERS###
    }
    
    server {
        listen 6443;
        proxy_pass k3s_api;
        proxy_timeout 600s;
        proxy_connect_timeout 5s;
        proxy_buffer_size 64k;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    server {
        listen 80;
        location / {
            root /var/www/html;
            index index.html;
        }
        location /nginx_status {
            stub_status on;
            access_log off;
            allow 127.0.0.1;
            allow 10.0.1.0/24;
            deny all;
        }
    }
}
'@

#########################################
# PROXY SETUP SCRIPT
#########################################

$ProxySetupScript = @'
#!/bin/bash
# Nginx Proxy Setup Script

echo "Setting up Nginx Proxy for K3s HA"

# Update system
apt-get update
apt-get upgrade -y

# Install Nginx with stream module
apt-get install -y nginx libnginx-mod-stream

# Backup original config
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# Deploy new configuration
cat > /etc/nginx/nginx.conf << 'NGINX_EOF'
###NGINX_CONFIG###
NGINX_EOF

# Create status page
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html>
<head>
    <title>K3s HA Proxy Status</title>
    <meta http-equiv="refresh" content="10">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .info { background-color: #e7f3fe; padding: 20px; border-radius: 5px; }
        h1 { color: #333; }
        pre { background-color: #f5f5f5; padding: 10px; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>K3s High Availability Proxy</h1>
    <div class="info">
        <h2>Configuration</h2>
        <ul>
            <li>Proxy Endpoint: https://###PROXY_IP###:6443</li>
            <li>Load Balancing: Least Connections</li>
            <li>Backend Masters: 10.0.1.10, 10.0.1.11, 10.0.1.12</li>
            <li>Health Check: Every 5 seconds</li>
        </ul>
    </div>
    <h2>kubectl Configuration</h2>
    <pre>kubectl config set-cluster k3s-ha --server=https://###PROXY_IP###:6443</pre>
</body>
</html>
HTML_EOF

# Enable and start Nginx
systemctl enable nginx
systemctl restart nginx

# Setup firewall
ufw allow 6443/tcp comment 'K3s API'
ufw allow 80/tcp comment 'Status Page'
ufw allow 22/tcp comment 'SSH'
echo "y" | ufw enable

echo "Nginx proxy setup complete!"
'@

#########################################
# MASTER NODE SETUP SCRIPT
#########################################

$MasterSetupScript = @'
#!/bin/bash
# K3s Master Setup Script with NFS Storage

MASTER_NUMBER=$1
FIRST_MASTER_IP=$2
K3S_TOKEN=$3
K3S_VERSION=$4
STORAGE_DEVICE=$5
NFS_MOUNT_PATH=$6
K3S_SERVER_ARGS="$7"

echo "Setting up K3s Master Node $MASTER_NUMBER"

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl wget nfs-kernel-server nfs-common open-iscsi

# Install iptables (required for newer K3s versions)
apt-get install -y iptables

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
if [ -b "$STORAGE_DEVICE" ]; then
    echo "Setting up NFS storage on $STORAGE_DEVICE"
    
    # Create partition
    parted -s $STORAGE_DEVICE mklabel gpt
    parted -s $STORAGE_DEVICE mkpart primary ext4 0% 100%
    sleep 2
    
    # Format and mount
    mkfs.ext4 -F ${STORAGE_DEVICE}1
    mkdir -p $NFS_MOUNT_PATH
    echo "${STORAGE_DEVICE}1 $NFS_MOUNT_PATH ext4 defaults,noatime 0 2" >> /etc/fstab
    mount $NFS_MOUNT_PATH
    
    # Create NFS directories
    mkdir -p $NFS_MOUNT_PATH/{shared,data,backups}
    chmod 777 $NFS_MOUNT_PATH/{shared,data,backups}
fi

# Configure NFS exports
cat > /etc/exports << EOF
$NFS_MOUNT_PATH/shared  10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
$NFS_MOUNT_PATH/data    10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
$NFS_MOUNT_PATH/backups 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

# Start NFS server
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra

# Install K3s
if [ "$MASTER_NUMBER" -eq 1 ]; then
    echo "Installing first K3s master"
    echo "K3s args: $K3S_SERVER_ARGS"
    eval "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server $K3S_SERVER_ARGS"
else
    echo "Installing additional K3s master"
    echo "K3s args: --server https://${FIRST_MASTER_IP}:6443 $K3S_SERVER_ARGS"
    eval "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server --server https://${FIRST_MASTER_IP}:6443 $K3S_SERVER_ARGS"
fi

echo "Master setup complete!"
'@

#########################################
# WORKER NODE SETUP SCRIPT
#########################################

$WorkerSetupScript = @'
#!/bin/bash
# K3s Worker Setup Script

PROXY_IP=$1
K3S_TOKEN=$2
K3S_VERSION=$3
K3S_AGENT_ARGS="$4"

echo "Setting up K3s Worker Node"

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl wget nfs-common open-iscsi

# Install iptables (required for newer K3s versions)
apt-get install -y iptables

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
echo "K3s agent args: $K3S_AGENT_ARGS"
eval "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - agent $K3S_AGENT_ARGS"

echo "Worker setup complete!"
'@

#########################################
# NFS PROVISIONER K8S MANIFEST
#########################################

$NFSProvisionerYaml = @'
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: nfs-provisioner
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: nfs-provisioner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: leader-locking-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
  labels:
    app: nfs-client-provisioner
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k3s.io/nfs
            - name: NFS_SERVER
              value: ###PRIMARY_MASTER_IP###  # Primary master NFS
            - name: NFS_PATH
              value: ###NFS_MOUNT_PATH###/shared
      volumes:
        - name: nfs-client-root
          nfs:
            server: ###PRIMARY_MASTER_IP###
            path: ###NFS_MOUNT_PATH###/shared
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: k3s.io/nfs
parameters:
  archiveOnDelete: "false"
  pathPattern: "${.PVC.namespace}/${.PVC.name}"
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client-retain
provisioner: k3s.io/nfs
parameters:
  archiveOnDelete: "true"
  pathPattern: "${.PVC.namespace}/${.PVC.name}"
reclaimPolicy: Retain
allowVolumeExpansion: true
'@

#########################################
# MAIN DEPLOYMENT SCRIPT
#########################################

Write-Host "=== K3s HA Cluster Deployment Script ===" -ForegroundColor Green
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Proxy: $($Config.ProxyIP)" -ForegroundColor White
Write-Host "  Masters: $($Config.MasterIPs -join ', ')" -ForegroundColor White
Write-Host "  Workers: $($Config.WorkerIPs -join ', ')" -ForegroundColor White

# Function to deploy scripts
function Deploy-Scripts {
    Write-Host "`n=== Preparing deployment scripts ===" -ForegroundColor Green
    
    # Generate master server lines for Nginx upstream
    $masterServers = ""
    foreach ($masterIP in $Config.MasterIPs) {
        $masterServers += "        server ${masterIP}:6443 max_fails=3 fail_timeout=5s;`n"
    }
    $masterServers = $masterServers.TrimEnd("`n")
    
    # Prepare Nginx config with actual IPs
    $NginxConfigFinal = $NginxConfig -replace '###MASTER_SERVERS###', $masterServers
    
    # Prepare proxy setup script
    $ProxySetupFinal = $ProxySetupScript -replace '###NGINX_CONFIG###', $NginxConfigFinal
    $ProxySetupFinal = $ProxySetupFinal -replace '###PROXY_IP###', $Config.ProxyIP
    
    # Prepare NFS provisioner YAML with actual IPs
    $NFSProvisionerFinal = $NFSProvisionerYaml -replace '###PRIMARY_MASTER_IP###', $Config.MasterIPs[0]
    $NFSProvisionerFinal = $NFSProvisionerFinal -replace '###NFS_MOUNT_PATH###', $Config.NFSMountPath
    
    # Save scripts locally
    $NginxConfigFinal | Out-File -FilePath "nginx.conf" -Encoding UTF8
    $ProxySetupFinal | Out-File -FilePath "setup-proxy.sh" -Encoding UTF8
    $MasterSetupScript | Out-File -FilePath "setup-master.sh" -Encoding UTF8
    $WorkerSetupScript | Out-File -FilePath "setup-worker.sh" -Encoding UTF8
    $NFSProvisionerFinal | Out-File -FilePath "nfs-provisioner.yaml" -Encoding UTF8
    
    # Convert line endings for Linux
    Get-ChildItem *.sh | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content -replace "`r`n", "`n" | Set-Content $_.FullName -NoNewline
    }
}

# Function to setup proxy
function Setup-ProxyNode {
    Write-Host "`n=== Setting up Nginx Proxy ===" -ForegroundColor Green
    
    # Copy and execute setup script
    Copy-FileToNode -Config $Config -Node $Config.ProxyIP -LocalPath "setup-proxy.sh" -RemotePath "/tmp/setup-proxy.sh"
    Invoke-SSHCommand -Config $Config -Node $Config.ProxyIP -Command "chmod +x /tmp/setup-proxy.sh && sudo /tmp/setup-proxy.sh"
    
    Write-Host "Proxy setup complete!" -ForegroundColor Green
}

# Function to setup masters
function Setup-MasterNodes {
    Write-Host "`n=== Setting up Master Nodes ===" -ForegroundColor Green
    
    for ($i = 0; $i -lt $Config.MasterIPs.Count; $i++) {
        $masterIP = $Config.MasterIPs[$i]
        $masterNumber = $i + 1
        $isFirstServer = $i -eq 0
        
        Write-Host "`nSetting up Master $masterNumber ($masterIP)..." -ForegroundColor Yellow
        
        # Generate K3s server arguments using the module function
        $k3sServerArgs = Get-K3sServerArgs -Config $Config -IsFirstServer:$isFirstServer
        if (-not $isFirstServer) {
            # Remove cluster-init for additional servers (it's handled in the script)
            $k3sServerArgs = $k3sServerArgs -replace "--cluster-init\s*", ""
        }
        
        Write-Host "  K3s server arguments: $k3sServerArgs" -ForegroundColor Cyan
        
        # Copy setup script
        Copy-FileToNode -Config $Config -Node $masterIP -LocalPath "setup-master.sh" -RemotePath "/tmp/setup-master.sh"
        
        # Execute setup script
        $setupCmd = "chmod +x /tmp/setup-master.sh && sudo /tmp/setup-master.sh $masterNumber $($Config.MasterIPs[0]) $($Config.K3sToken) $($Config.K3sVersion) $($Config.StorageDevice) $($Config.NFSMountPath) `"$k3sServerArgs`""
        Invoke-SSHCommand -Config $Config -Node $masterIP -Command $setupCmd
        
        if ($i -eq 0) {
            Write-Host "Waiting for first master to initialize..." -ForegroundColor Cyan
            Start-Sleep -Seconds 30
        } else {
            Start-Sleep -Seconds 20
        }
    }
    
    Write-Host "All masters setup complete!" -ForegroundColor Green
}

# Function to setup workers
function Setup-WorkerNodes {
    Write-Host "`n=== Setting up Worker Nodes ===" -ForegroundColor Green
    
    # Generate K3s agent arguments using the module function
    $serverURL = "https://$($Config.ProxyIP):6443"
    $k3sAgentArgs = Get-K3sAgentArgs -Config $Config -ServerURL $serverURL
    Write-Host "  K3s agent arguments: $k3sAgentArgs" -ForegroundColor Cyan
    
    foreach ($workerIP in $Config.WorkerIPs) {
        Write-Host "`nSetting up Worker ($workerIP)..." -ForegroundColor Yellow
        
        # Copy setup script
        Copy-FileToNode -Config $Config -Node $workerIP -LocalPath "setup-worker.sh" -RemotePath "/tmp/setup-worker.sh"
        
        # Execute setup script
        $setupCmd = "chmod +x /tmp/setup-worker.sh && sudo /tmp/setup-worker.sh $($Config.ProxyIP) $($Config.K3sToken) $($Config.K3sVersion) `"$k3sAgentArgs`""
        Invoke-SSHCommand -Config $Config -Node $workerIP -Command $setupCmd
        
        Start-Sleep -Seconds 10
    }
    
    Write-Host "All workers setup complete!" -ForegroundColor Green
}

# Function to configure cluster
function Configure-Cluster {
    Write-Host "`n=== Configuring Cluster ===" -ForegroundColor Green
    
    # Get kubeconfig from first master
    $kubeconfigPath = "$HOME\.kube\k3s-config"
    New-Item -ItemType Directory -Force -Path "$HOME\.kube" | Out-Null
    
    Write-Host "Retrieving kubeconfig..." -ForegroundColor Yellow
    scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no "$($Config.SSHUser)@$($Config.MasterIPs[0]):/etc/rancher/k3s/k3s.yaml" $kubeconfigPath
    
    # Update kubeconfig to use proxy
    $kubeconfig = Get-Content $kubeconfigPath -Raw
    $kubeconfig = $kubeconfig -replace 'https://127.0.0.1:6443', "https://$($Config.ProxyIP):6443"
    $kubeconfig | Set-Content $kubeconfigPath
    
    $env:KUBECONFIG = $kubeconfigPath
    
    # Deploy NFS provisioner
    Write-Host "Deploying NFS provisioner..." -ForegroundColor Yellow
    kubectl apply -f nfs-provisioner.yaml
    
    # Wait for provisioner to be ready
    Start-Sleep -Seconds 20
    kubectl rollout status deployment/nfs-client-provisioner -n nfs-provisioner
    
    Write-Host "Cluster configuration complete!" -ForegroundColor Green
}

# Function to verify cluster
function Test-Cluster {
    Write-Host "`n=== Verifying Cluster ===" -ForegroundColor Green
    
    Write-Host "`nNodes:" -ForegroundColor Yellow
    kubectl get nodes -o wide
    
    Write-Host "`nPods:" -ForegroundColor Yellow
    kubectl get pods -A
    
    Write-Host "`nStorage Classes:" -ForegroundColor Yellow
    kubectl get storageclass
    
    Write-Host "`nTesting NFS storage..." -ForegroundColor Yellow
    $testPVC = @'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
'@
    
    $testPVC | kubectl apply -f -
    Start-Sleep -Seconds 5
    kubectl get pvc test-nfs-claim
    kubectl delete pvc test-nfs-claim
}

# Main execution flow
function Start-Deployment {
    param(
        [switch]$PrepareOnly,
        [switch]$ProxyOnly,
        [switch]$MastersOnly,
        [switch]$WorkersOnly,
        [switch]$ConfigureOnly
    )
    
    if ($PrepareOnly -or !($ProxyOnly -or $MastersOnly -or $WorkersOnly -or $ConfigureOnly)) {
        Deploy-Scripts
    }
    
    if (!$PrepareOnly) {
        if ($ProxyOnly) {
            Setup-ProxyNode
        } elseif ($MastersOnly) {
            Setup-MasterNodes
        } elseif ($WorkersOnly) {
            Setup-WorkerNodes
        } elseif ($ConfigureOnly) {
            Configure-Cluster
            Test-Cluster
        } else {
            # Full deployment
            Setup-ProxyNode
            Setup-MasterNodes
            Setup-WorkerNodes
            Configure-Cluster
            Test-Cluster
        }
    }
    
    Write-Host "`n=== Deployment Complete! ===" -ForegroundColor Green
    Write-Host @"

Cluster Access:
  kubectl --kubeconfig=$HOME\.kube\k3s-config get nodes

Proxy Status Page:
  http://$($Config.ProxyIP)/

NFS Exports Available:
  - $($Config.MasterIPs[0]):/data/nfs/shared
  - $($Config.MasterIPs[0]):/data/nfs/data
  - $($Config.MasterIPs[0]):/data/nfs/backups

Storage Classes:
  - nfs-client (dynamic provisioning, delete)
  - nfs-client-retain (dynamic provisioning, retain)

"@ -ForegroundColor Cyan
}

# Script execution options
Write-Host "`nDeployment Options:" -ForegroundColor Yellow
Write-Host "  1. Full deployment (all components)" -ForegroundColor White
Write-Host "  2. Prepare scripts only" -ForegroundColor White
Write-Host "  3. Deploy proxy only" -ForegroundColor White
Write-Host "  4. Deploy masters only" -ForegroundColor White
Write-Host "  5. Deploy workers only" -ForegroundColor White
Write-Host "  6. Configure cluster only" -ForegroundColor White

$choice = Read-Host "`nSelect option (1-6)"

switch ($choice) {
    "1" { Start-Deployment }
    "2" { Start-Deployment -PrepareOnly }
    "3" { Start-Deployment -ProxyOnly }
    "4" { Start-Deployment -MastersOnly }
    "5" { Start-Deployment -WorkersOnly }
    "6" { Start-Deployment -ConfigureOnly }
    default { Write-Host "Invalid option" -ForegroundColor Red }
}

# Cleanup function
function Remove-TempFiles {
    Remove-Item -Path "nginx.conf", "setup-proxy.sh", "setup-master.sh", "setup-worker.sh", "nfs-provisioner.yaml" -ErrorAction SilentlyContinue
}

# Uncomment to cleanup temp files after deployment
# Remove-TempFiles