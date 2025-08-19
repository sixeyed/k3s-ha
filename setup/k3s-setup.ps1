# Complete K3s HA Cluster Setup with Nginx Proxy and NFS Storage
# Architecture: 1 Nginx Proxy + 3 Control Plane (with NFS) + 6 Worker Nodes
#
# Usage Examples:
#   ./k3s-setup.ps1                                          # Full deployment with default config
#   ./k3s-setup.ps1 -Action Deploy                          # Same as above (explicit)
#   ./k3s-setup.ps1 -Action PrepareOnly                     # Generate scripts only
#   ./k3s-setup.ps1 -Action ConfigureOnly                   # Configure cluster only
#   ./k3s-setup.ps1 -Action ImportKubeConfig                # Import existing cluster kubeconfig
#   ./k3s-setup.ps1 -ConfigFile "prod.json" -Action Deploy  # Deploy with custom config

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "cluster.json",
    
    [Parameter(Mandatory=$false)]
    [bool]$SetKubectlContext = $true,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Deploy", "PrepareOnly", "ProxyOnly", "MastersOnly", "WorkersOnly", "ConfigureOnly", "ImportKubeConfig")]
    [string]$Action = "Deploy"
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

function Get-NetworkSubnet {
    param([string]$IPAddress)
    
    # Calculate /24 network subnet from IP address
    $octets = $IPAddress.Split('.')
    if ($octets.Count -eq 4) {
        return "$($octets[0]).$($octets[1]).$($octets[2]).0/24"
    } else {
        throw "Invalid IP address format: $IPAddress"
    }
}

#########################################
# NGINX PROXY CONFIGURATION
#########################################

$NginxConfig = @'
load_module modules/ngx_stream_module.so;

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
            allow NETWORK_SUBNET;
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
NETWORK_SUBNET="$8"

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
$NFS_MOUNT_PATH/shared  $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
$NFS_MOUNT_PATH/data    $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
$NFS_MOUNT_PATH/backups $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
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

# Create K3s environment file with token (required for systemd service)
echo "K3S_TOKEN=$K3S_TOKEN" > /etc/systemd/system/k3s-agent.service.env
systemctl daemon-reload

echo "Worker setup complete!"
'@

#########################################
# NFS PROVISIONER K8S MANIFEST
#########################################

# NFS Provisioner deployment is now handled via Helm chart
# See Deploy-NFSProvisioner function below

#########################################
# NFS PROVISIONER DEPLOYMENT FUNCTION
#########################################

function Deploy-NFSProvisioner {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    
    Write-Host "Deploying NFS provisioner via YAML..." -ForegroundColor Yellow
    
    # Get primary master IP and NFS path from config
    $nfsServer = $Config.MasterIPs[0] 
    $nfsPath = $Config.NFSProvisionerPath
    
    Write-Host "  NFS Server: $nfsServer" -ForegroundColor Cyan
    Write-Host "  NFS Path: $nfsPath" -ForegroundColor Cyan
    
    # Create NFS provisioner YAML with proper configuration
    $nfsProvisionerYAML = @"
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
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k3s.io/nfs-client
            - name: NFS_SERVER
              value: $nfsServer
            - name: NFS_PATH
              value: $nfsPath
            - name: KUBERNETES_SERVICE_HOST
              value: $($Config.ProxyIP)
            - name: KUBERNETES_SERVICE_PORT
              value: "6443"
      volumes:
        - name: nfs-client-root
          nfs:
            server: $nfsServer
            path: $nfsPath
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: k3s.io/nfs-client
parameters:
  archiveOnDelete: "false"
  pathPattern: "`${.PVC.namespace}/`${.PVC.name}"
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client-retain
provisioner: k3s.io/nfs-client
parameters:
  archiveOnDelete: "true"
  pathPattern: "`${.PVC.namespace}/`${.PVC.name}"
reclaimPolicy: Retain
allowVolumeExpansion: true
"@

    Write-Host "  Applying NFS provisioner configuration..." -ForegroundColor Gray
    $nfsProvisionerYAML | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to deploy NFS provisioner via YAML"
    }
    
    Write-Host "  ✓ NFS provisioner deployed successfully" -ForegroundColor Green
    
    # Wait for deployment to be ready
    Write-Host "  Waiting for NFS provisioner to be ready..." -ForegroundColor Gray
    kubectl rollout status deployment/nfs-client-provisioner -n nfs-provisioner --timeout=300s
    
    # Test that NFS provisioner actually works by creating a test PVC
    Write-Host "  Testing NFS provisioner functionality..." -ForegroundColor Gray
    $testPVC = @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-provisioner-test
  namespace: nfs-provisioner
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
"@
    $testPVC | kubectl apply -f -
    
    # Wait for PVC to be bound (this verifies the provisioner is working)
    $timeout = 60
    $elapsed = 0
    do {
        $pvcStatus = kubectl get pvc nfs-provisioner-test -n nfs-provisioner -o jsonpath='{.status.phase}' 2>$null
        if ($pvcStatus -eq "Bound") {
            Write-Host "  ✓ NFS provisioner test successful" -ForegroundColor Green
            kubectl delete pvc nfs-provisioner-test -n nfs-provisioner >$null 2>&1
            break
        }
        Start-Sleep 2
        $elapsed += 2
    } while ($elapsed -lt $timeout)
    
    if ($pvcStatus -ne "Bound") {
        kubectl delete pvc nfs-provisioner-test -n nfs-provisioner >$null 2>&1
        throw "NFS provisioner test failed - PVC did not bind within $timeout seconds"
    }
    
    Write-Host "✓ NFS provisioner deployment complete!" -ForegroundColor Green
}

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
    Write-Host "`n=== Preparing deployment scripts ===" -ForegroundColor Cyan
    
    # Generate master server lines for Nginx upstream
    $masterServers = ""
    foreach ($masterIP in $Config.MasterIPs) {
        $masterServers += "        server ${masterIP}:6443 max_fails=3 fail_timeout=5s;`n"
    }
    $masterServers = $masterServers.TrimEnd("`n")
    
    # Prepare Nginx config with actual IPs
    $networkSubnet = Get-NetworkSubnet -IPAddress $Config.ProxyIP
    $NginxConfigFinal = $NginxConfig -replace '###MASTER_SERVERS###', $masterServers
    $NginxConfigFinal = $NginxConfigFinal -replace 'NETWORK_SUBNET', $networkSubnet
    
    # Prepare proxy setup script
    $ProxySetupFinal = $ProxySetupScript -replace '###NGINX_CONFIG###', $NginxConfigFinal
    $ProxySetupFinal = $ProxySetupFinal -replace '###PROXY_IP###', $Config.ProxyIP
    
    # NFS provisioner now deployed via Helm chart (see Deploy-NFSProvisioner function)
    
    # Create config directory if it doesn't exist (relative to script location)
    $configDir = "$PSScriptRoot/config"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Host "  ✓ Created config directory" -ForegroundColor Green
    }
    
    # Save scripts locally in config directory
    $NginxConfigFinal | Out-File -FilePath "$configDir/nginx.conf" -Encoding UTF8
    $ProxySetupFinal | Out-File -FilePath "$configDir/setup-proxy.sh" -Encoding UTF8
    $MasterSetupScript | Out-File -FilePath "$configDir/setup-master.sh" -Encoding UTF8
    $WorkerSetupScript | Out-File -FilePath "$configDir/setup-worker.sh" -Encoding UTF8
    Write-Host "  ✓ Generated deployment configuration files" -ForegroundColor Green
    
    # Convert line endings for Linux
    $shellScripts = Get-ChildItem "$configDir/*.sh" -ErrorAction SilentlyContinue
    if ($shellScripts) {
        $shellScripts | ForEach-Object {
            $content = Get-Content $_.FullName -Raw
            $content -replace "`r`n", "`n" | Set-Content $_.FullName -NoNewline
        }
        Write-Host "  ✓ Converted line endings for Linux compatibility" -ForegroundColor Green
    }
}

# Function to setup proxy
function Setup-ProxyNode {
    Write-Host "`n=== Setting up Nginx Proxy ===" -ForegroundColor Green
    
    # Copy and execute setup script in two steps to avoid complex quoting issues
    Copy-FileToNode -Config $Config -Node $Config.ProxyIP -LocalPath "$PSScriptRoot/config/setup-proxy.sh" -RemotePath "/tmp/setup-proxy.sh"
    
    $chmodCmd = "chmod +x /tmp/setup-proxy.sh"
    Invoke-SSHCommand -Config $Config -Node $Config.ProxyIP -Command $chmodCmd
    
    $setupCmd = "sudo /tmp/setup-proxy.sh"
    Invoke-SSHCommand -Config $Config -Node $Config.ProxyIP -Command $setupCmd
    
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
        Copy-FileToNode -Config $Config -Node $masterIP -LocalPath "$PSScriptRoot/config/setup-master.sh" -RemotePath "/tmp/setup-master.sh"
        
        # Execute setup script in two steps to avoid complex quoting issues
        $chmodCmd = "chmod +x /tmp/setup-master.sh"
        Invoke-SSHCommand -Config $Config -Node $masterIP -Command $chmodCmd
        
        $networkSubnet = Get-NetworkSubnet -IPAddress $Config.MasterIPs[0]
        $setupCmd = "sudo /tmp/setup-master.sh $masterNumber $($Config.MasterIPs[0]) $($Config.K3sToken) $($Config.K3sVersion) $($Config.StorageDevice) $($Config.NFSMountPath) '$k3sServerArgs' '$networkSubnet'"
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
        Copy-FileToNode -Config $Config -Node $workerIP -LocalPath "$PSScriptRoot/config/setup-worker.sh" -RemotePath "/tmp/setup-worker.sh"
        
        # Execute setup script in two steps to avoid complex quoting issues
        $chmodCmd = "chmod +x /tmp/setup-worker.sh"
        Invoke-SSHCommand -Config $Config -Node $workerIP -Command $chmodCmd
        
        $setupCmd = "sudo /tmp/setup-worker.sh $($Config.ProxyIP) $($Config.K3sToken) $($Config.K3sVersion) '$k3sAgentArgs'"
        Invoke-SSHCommand -Config $Config -Node $workerIP -Command $setupCmd
        
        Start-Sleep -Seconds 10
    }
    
    Write-Host "All workers setup complete!" -ForegroundColor Green
}

# Function to configure cluster
function Configure-Cluster {
    Write-Host "`n=== Configuring Cluster ===" -ForegroundColor Green
    
    # Wait for cluster to be fully ready
    Write-Host "Waiting for cluster to be ready..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    
    # Get kubeconfig from first master with retry logic
    $kubeconfigPath = Join-Path $HOME ".kube" "k3s-config"
    New-Item -ItemType Directory -Force -Path (Join-Path $HOME ".kube") | Out-Null
    
    Write-Host "Retrieving kubeconfig..." -ForegroundColor Yellow
    
    # Always remove existing kubeconfig to force fresh retrieval
    if (Test-Path $kubeconfigPath) {
        Remove-Item $kubeconfigPath -Force
        Write-Host "  • Removed existing kubeconfig to force fresh retrieval" -ForegroundColor Gray
    }
    
    $maxRetries = 3
    $retryCount = 0
    $success = $false
    
    while ($retryCount -lt $maxRetries -and -not $success) {
        try {
            Copy-FileFromNode -Config $Config -Node $Config.MasterIPs[0] -RemotePath "/etc/rancher/k3s/k3s.yaml" -LocalPath $kubeconfigPath
            
            # Verify the kubeconfig was retrieved successfully
            if (Test-Path $kubeconfigPath) {
                $kubeconfigContent = Get-Content $kubeconfigPath -Raw
                if ($kubeconfigContent -and $kubeconfigContent.Contains("certificate-authority-data")) {
                    $success = $true
                    Write-Host "✓ Kubeconfig retrieved successfully" -ForegroundColor Green
                } else {
                    throw "Invalid kubeconfig content"
                }
            } else {
                throw "Kubeconfig file not found"
            }
        }
        catch {
            $retryCount++
            Write-Host "⚠ Attempt $retryCount failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($retryCount -lt $maxRetries) {
                Write-Host "  Waiting 10 seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
            }
        }
    }
    
    if (-not $success) {
        throw "Failed to retrieve kubeconfig after $maxRetries attempts"
    }
    
    # Configure kubectl context if requested
    if ($SetKubectlContext) {
        Write-Host "Configuring kubectl context..." -ForegroundColor Yellow
        
        # Update kubeconfig to use proxy endpoint instead of localhost
        $kubeconfig = Get-Content $kubeconfigPath -Raw
        $kubeconfig = $kubeconfig -replace 'https://127\.0\.0\.1:6443', "https://$($Config.ProxyIP):6443"
        $kubeconfig = $kubeconfig -replace 'https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:6443', "https://$($Config.ProxyIP):6443"
        $kubeconfig | Set-Content $kubeconfigPath
        Write-Host "✓ Updated kubeconfig to use proxy endpoint: https://$($Config.ProxyIP):6443" -ForegroundColor Green
        
        # Generate cluster-specific context name
        $contextName = "$($Config.ClusterName)-$($Config.ProxyIP)"
        $clusterName = "$($Config.ClusterName)-$($Config.ProxyIP)"
        $userName = "$($Config.ClusterName)-$($Config.ProxyIP)"
        
        # Update context names using TARGETED replacements that avoid certificate data
        $kconfigContent = Get-Content $kubeconfigPath -Raw
        
        # Only replace "default" when it appears in specific YAML structure contexts
        # Use very specific patterns that won't match certificate data (multiline mode)
        $kconfigContent = $kconfigContent -replace '(?m)^(\s*- name:\s*)default$', "`${1}$userName"
        $kconfigContent = $kconfigContent -replace '(?m)^(\s*name:\s*)default$', "`${1}$clusterName" 
        $kconfigContent = $kconfigContent -replace '(?m)^(\s*current-context:\s*)default$', "`${1}$contextName"  
        $kconfigContent = $kconfigContent -replace '(?m)^(\s*cluster:\s*)default$', "`${1}$clusterName"
        $kconfigContent = $kconfigContent -replace '(?m)^(\s*user:\s*)default$', "`${1}$userName"
        
        # Save the carefully modified config
        $kconfigContent | Set-Content $kubeconfigPath
        Write-Host "✓ Updated context names in kubeconfig" -ForegroundColor Green
        Write-Host "  • Context name: $contextName" -ForegroundColor Green
        
        # Always merge into the standard kubeconfig location
        $standardKubeconfigPath = "$env:HOME/.kube/config"
        
        # Remove any existing context with the same name to avoid conflicts
        if (Test-Path $standardKubeconfigPath) {
            try {
                # Backup existing config
                Copy-Item $standardKubeconfigPath "$env:HOME/.kube/config.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
                Write-Host "  • Backed up existing kubeconfig" -ForegroundColor Gray
                
                # Remove ALL existing entries that could conflict with this cluster
                $clusterBaseName = $Config.ClusterName
                
                # Remove entries by server URL (most reliable method)
                Write-Host "  • Removing any existing entries for server: https://$($Config.ProxyIP):6443" -ForegroundColor Gray
                
                # Get list of existing clusters that use the same server
                $existingClusters = kubectl config get-clusters -o name 2>&1 | Where-Object { $_ -notmatch "error" }
                foreach ($cluster in $existingClusters) {
                    $clusterInfo = kubectl config view -o json 2>&1 | ConvertFrom-Json
                    if ($clusterInfo.clusters) {
                        $matchingCluster = $clusterInfo.clusters | Where-Object { 
                            $_.cluster.server -eq "https://$($Config.ProxyIP):6443" 
                        }
                        if ($matchingCluster) {
                            Write-Host "  • Removing cluster: $($matchingCluster.name)" -ForegroundColor Gray
                            kubectl config delete-cluster $matchingCluster.name 2>&1 | Out-Null
                            
                            # Also remove any contexts and users that reference this cluster
                            if ($clusterInfo.contexts) {
                                $clusterInfo.contexts | Where-Object { $_.context.cluster -eq $matchingCluster.name } | ForEach-Object {
                                    Write-Host "  • Removing context: $($_.name)" -ForegroundColor Gray
                                    kubectl config delete-context $_.name 2>&1 | Out-Null
                                }
                            }
                        }
                    }
                }
                
                # Also remove common naming patterns as fallback
                $possibleNames = @($contextName, "$clusterBaseName-$($Config.ProxyIP)", $clusterBaseName, "default")
                foreach ($name in $possibleNames) {
                    kubectl config delete-context $name 2>&1 | Out-Null
                    kubectl config delete-cluster $name 2>&1 | Out-Null  
                    kubectl config delete-user $name 2>&1 | Out-Null
                }
                Write-Host "  • Removed any existing entries for this cluster" -ForegroundColor Gray
            }
            catch {
                Write-Host "  • No existing entries to remove" -ForegroundColor Gray
            }
        }
        
        # Merge the new kubeconfig
        Write-Host "Merging kubeconfig into standard location..." -ForegroundColor Yellow
        
        # Clear and reset KUBECONFIG to ensure fresh file reading  
        $env:KUBECONFIG = $null
        Start-Sleep -Milliseconds 500
        
        # Use Unix-style paths for KUBECONFIG (kubectl expects Unix format even on Windows)
        $unixStandardPath = $standardKubeconfigPath -replace '\\', '/'
        $unixKubeconfigPath = $kubeconfigPath -replace '\\', '/'
        $env:KUBECONFIG = "${unixStandardPath}:${unixKubeconfigPath}"
        
        Write-Host "  • Using KUBECONFIG: $($env:KUBECONFIG)" -ForegroundColor Gray
        
        kubectl config view --flatten | Out-File -FilePath "$env:HOME/.kube/config-merged" -Encoding UTF8
        
        # Verify the merge worked and fix current-context if needed
        if (Test-Path "$env:HOME/.kube/config-merged") {
            $mergedContent = Get-Content "$env:HOME/.kube/config-merged" -Raw
            if ($mergedContent -and $mergedContent.Contains($contextName)) {
                # Fix current-context to match the new context name
                $mergedContent = $mergedContent -replace "current-context: .*", "current-context: $contextName"
                $mergedContent | Set-Content "$env:HOME/.kube/config-merged"
                
                Move-Item "$env:HOME/.kube/config-merged" $standardKubeconfigPath -Force
                Write-Host "  • Successfully merged kubeconfig into ~/.kube/config" -ForegroundColor Green
                Write-Host "  • Set current-context to: $contextName" -ForegroundColor Green
            } else {
                throw "Kubeconfig merge failed - context '$contextName' not found in merged config"
            }
        } else {
            throw "Kubeconfig merge failed - merged file not created"
        }
        
        # Switch to the new context
        $env:KUBECONFIG = $standardKubeconfigPath
        kubectl config use-context $contextName
        
        Write-Host "✓ Kubectl context '$contextName' configured and set as current" -ForegroundColor Green
        Write-Host "  You can now use 'kubectl get nodes' directly" -ForegroundColor Cyan
    } else {
        # Just update kubeconfig to use proxy but don't merge
        $kubeconfig = Get-Content $kubeconfigPath -Raw
        $kubeconfig = $kubeconfig -replace 'https://127\.0\.0\.1:6443', "https://$($Config.ProxyIP):6443"
        $kubeconfig = $kubeconfig -replace 'https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:6443', "https://$($Config.ProxyIP):6443"
        $kubeconfig | Set-Content $kubeconfigPath
        
        $env:KUBECONFIG = $kubeconfigPath
        Write-Host "  Use: export KUBECONFIG=$kubeconfigPath" -ForegroundColor Cyan
    }
    
    # Deploy NFS provisioner via Helm
    Deploy-NFSProvisioner -Config $Config
    
    Write-Host "Cluster configuration complete!" -ForegroundColor Green
}

# Function to import kubeconfig only
function Import-KubeConfig {
    Write-Host "`n=== Importing Kubeconfig ===" -ForegroundColor Green
    
    # Get kubeconfig from first master with retry logic
    $kubeconfigPath = Join-Path $HOME ".kube" "k3s-config"
    New-Item -ItemType Directory -Force -Path (Join-Path $HOME ".kube") | Out-Null
    
    Write-Host "Retrieving kubeconfig from master..." -ForegroundColor Yellow
    
    # Always remove existing kubeconfig to force fresh retrieval
    if (Test-Path $kubeconfigPath) {
        Remove-Item $kubeconfigPath -Force
        Write-Host "  • Removed existing kubeconfig to force fresh retrieval" -ForegroundColor Gray
    }
    
    $maxRetries = 3
    $retryCount = 0
    $success = $false
    
    while ($retryCount -lt $maxRetries -and -not $success) {
        try {
            Copy-FileFromNode -Config $Config -Node $Config.MasterIPs[0] -RemotePath "/etc/rancher/k3s/k3s.yaml" -LocalPath $kubeconfigPath
            
            # Verify the kubeconfig was retrieved successfully
            if (Test-Path $kubeconfigPath) {
                $kubeconfigContent = Get-Content $kubeconfigPath -Raw
                if ($kubeconfigContent -and $kubeconfigContent.Contains("certificate-authority-data")) {
                    $success = $true
                    Write-Host "✓ Kubeconfig retrieved successfully" -ForegroundColor Green
                } else {
                    throw "Invalid kubeconfig content"
                }
            } else {
                throw "Kubeconfig file not found"
            }
        }
        catch {
            $retryCount++
            Write-Host "⚠ Attempt $retryCount failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($retryCount -lt $maxRetries) {
                Write-Host "  Waiting 10 seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
            }
        }
    }
    
    if (-not $success) {
        throw "Failed to retrieve kubeconfig after $maxRetries attempts"
    }
    
    # Update kubeconfig to use proxy (handle multiple possible server addresses)
    $kubeconfig = Get-Content $kubeconfigPath -Raw
    $kubeconfig = $kubeconfig -replace 'https://127\.0\.0\.1:6443', "https://$($Config.ProxyIP):6443"
    $kubeconfig = $kubeconfig -replace 'https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:6443', "https://$($Config.ProxyIP):6443"
    $kubeconfig | Set-Content $kubeconfigPath
    Write-Host "✓ Updated kubeconfig to use proxy endpoint: https://$($Config.ProxyIP):6443" -ForegroundColor Green
    
    # Configure kubectl context
    Write-Host "Configuring kubectl context..." -ForegroundColor Yellow
    
    # Generate context name based on cluster name and proxy IP
    $contextName = "$($Config.ClusterName)-$($Config.ProxyIP)"
    $clusterName = "$($Config.ClusterName)-$($Config.ProxyIP)"
    $userName = "$($Config.ClusterName)-$($Config.ProxyIP)"
    
    # Load the k3s-config as YAML and update names
    $kconfigContent = Get-Content $kubeconfigPath -Raw
    
    # Use TARGETED string replacements that avoid certificate data corruption
    # Only replace "default" when it appears in specific YAML structure contexts
    $kconfigContent = $kconfigContent -replace '(?m)^(\s*- name:\s*)default$', "`${1}$userName"
    $kconfigContent = $kconfigContent -replace '(?m)^(\s*name:\s*)default$', "`${1}$clusterName" 
    $kconfigContent = $kconfigContent -replace '(?m)^(\s*current-context:\s*)default$', "`${1}$contextName"  
    $kconfigContent = $kconfigContent -replace '(?m)^(\s*cluster:\s*)default$', "`${1}$clusterName"
    $kconfigContent = $kconfigContent -replace '(?m)^(\s*user:\s*)default$', "`${1}$userName"
    
    # Save modified config
    $kconfigContent | Set-Content $kubeconfigPath
    Write-Host "✓ Updated context names in kubeconfig" -ForegroundColor Green
    
    # Verify the context name was updated correctly
    $updatedConfig = Get-Content $kubeconfigPath -Raw
    if ($updatedConfig.Contains($contextName)) {
        Write-Host "  • Verified context name updated to: $contextName" -ForegroundColor Green
    } else {
        throw "Failed to update context name to '$contextName' in kubeconfig"
    }
    
    # Always merge into the standard kubeconfig location
    $standardKubeconfigPath = "$env:HOME/.kube/config"
    
    # Remove any existing context with the same name to avoid conflicts
    if (Test-Path $standardKubeconfigPath) {
        try {
            # Backup existing config
            Copy-Item $standardKubeconfigPath "$env:HOME/.kube/config.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
            Write-Host "  • Backed up existing kubeconfig" -ForegroundColor Gray
            
            # Remove ALL existing entries that could conflict with this cluster
            $clusterBaseName = $Config.ClusterName
            
            # Remove entries by server URL (most reliable method)
            Write-Host "  • Removing any existing entries for server: https://$($Config.ProxyIP):6443" -ForegroundColor Gray
            
            # Get list of existing clusters that use the same server
            $existingClusters = kubectl config get-clusters -o name 2>&1 | Where-Object { $_ -notmatch "error" }
            foreach ($cluster in $existingClusters) {
                $clusterInfo = kubectl config view -o json 2>&1 | ConvertFrom-Json
                if ($clusterInfo.clusters) {
                    $matchingCluster = $clusterInfo.clusters | Where-Object { 
                        $_.cluster.server -eq "https://$($Config.ProxyIP):6443" 
                    }
                    if ($matchingCluster) {
                        Write-Host "  • Removing cluster: $($matchingCluster.name)" -ForegroundColor Gray
                        kubectl config delete-cluster $matchingCluster.name 2>&1 | Out-Null
                        
                        # Also remove any contexts and users that reference this cluster
                        if ($clusterInfo.contexts) {
                            $clusterInfo.contexts | Where-Object { $_.context.cluster -eq $matchingCluster.name } | ForEach-Object {
                                Write-Host "  • Removing context: $($_.name)" -ForegroundColor Gray
                                kubectl config delete-context $_.name 2>&1 | Out-Null
                            }
                        }
                    }
                }
            }
            
            # Also remove common naming patterns as fallback
            $possibleNames = @($contextName, "$clusterBaseName-$($Config.ProxyIP)", $clusterBaseName, "default")
            foreach ($name in $possibleNames) {
                kubectl config delete-context $name 2>&1 | Out-Null
                kubectl config delete-cluster $name 2>&1 | Out-Null  
                kubectl config delete-user $name 2>&1 | Out-Null
            }
            Write-Host "  • Removed any existing entries for this cluster" -ForegroundColor Gray
        }
        catch {
            Write-Host "  • No existing entries to remove" -ForegroundColor Gray
        }
    }
    
    # Merge the new kubeconfig
    Write-Host "Merging kubeconfig into standard location..." -ForegroundColor Yellow
    
    # Clear and reset KUBECONFIG to ensure fresh file reading  
    $env:KUBECONFIG = $null
    Start-Sleep -Milliseconds 500
    
    # Use Unix-style paths for KUBECONFIG (kubectl expects Unix format even on Windows)
    $unixStandardPath = $standardKubeconfigPath -replace '\\', '/'
    $unixKubeconfigPath = $kubeconfigPath -replace '\\', '/'
    $env:KUBECONFIG = "${unixStandardPath}:${unixKubeconfigPath}"
    
    Write-Host "  • Using KUBECONFIG: $($env:KUBECONFIG)" -ForegroundColor Gray
    
    kubectl config view --flatten | Out-File -FilePath "$env:HOME/.kube/config-merged" -Encoding UTF8
    
    # Verify the merge worked and fix current-context if needed
    if (Test-Path "$env:HOME/.kube/config-merged") {
        $mergedContent = Get-Content "$env:HOME/.kube/config-merged" -Raw
        if ($mergedContent -and $mergedContent.Contains($contextName)) {
            # Fix current-context to match the new context name
            $mergedContent = $mergedContent -replace "current-context: .*", "current-context: $contextName"
            $mergedContent | Set-Content "$env:HOME/.kube/config-merged"
            
            Move-Item "$env:HOME/.kube/config-merged" $standardKubeconfigPath -Force
            Write-Host "  • Successfully merged kubeconfig into ~/.kube/config" -ForegroundColor Green
            Write-Host "  • Set current-context to: $contextName" -ForegroundColor Green
        } else {
            throw "Kubeconfig merge failed - context '$contextName' not found in merged config"
        }
    } else {
        throw "Kubeconfig merge failed - merged file not created"
    }
    
    # Switch to the new context
    $env:KUBECONFIG = $standardKubeconfigPath
    kubectl config use-context $contextName
    
    Write-Host "✓ Kubectl context '$contextName' configured and set as current" -ForegroundColor Green
    Write-Host "✓ Kubeconfig import complete!" -ForegroundColor Green
    
    # Test the connection
    Write-Host "`nTesting connection..." -ForegroundColor Yellow
    $testOutput = kubectl get nodes --request-timeout=10s 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Successfully connected to cluster!" -ForegroundColor Green
        Write-Host $testOutput
    }
    else {
        Write-Host "⚠ Connection test failed!" -ForegroundColor Yellow
        Write-Host "  Error: $testOutput" -ForegroundColor Red
        Write-Host "  You may need to check that the cluster is running and accessible" -ForegroundColor Yellow
    }
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
  kubectl get nodes

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

# Script execution - automatically run based on Action parameter
Write-Host "`nExecuting Action: $Action" -ForegroundColor Yellow

switch ($Action) {
    "Deploy" { Start-Deployment }
    "PrepareOnly" { Start-Deployment -PrepareOnly }
    "ProxyOnly" { Start-Deployment -ProxyOnly }
    "MastersOnly" { Start-Deployment -MastersOnly }
    "WorkersOnly" { Start-Deployment -WorkersOnly }
    "ConfigureOnly" { Start-Deployment -ConfigureOnly }
    "ImportKubeConfig" { Import-KubeConfig }
}

# Cleanup function
function Remove-TempFiles {
    Remove-Item -Path "$PSScriptRoot/config" -Recurse -ErrorAction SilentlyContinue
}

# Uncomment to cleanup temp files after deployment
# Remove-TempFiles