# K3s HA Cluster Deployment Guide

## Overview

This guide covers the deployment and usage of a highly available K3s cluster with the following architecture:
- 1 Nginx proxy VM for load balancing
- 3 Control plane nodes (also serving NFS storage)
- 6 Worker nodes for applications
- No virtual IP required - uses Nginx for HA

## Prerequisites

### Required Resources
- **10 VMs total** with the following specifications:
  - **Proxy VM**: 2 vCPU, 4 GB RAM, 20 GB storage
  - **Control Plane VMs (3)**: 8 vCPU, 32 GB RAM, 150 GB OS + 1 TB storage disk
  - **Worker VMs (6)**: 8-16 vCPU, 32-64 GB RAM, 200 GB storage

### Network Requirements
- All VMs on same network (e.g., 10.0.1.0/24)
- Static IP addresses for all nodes
- Firewall allowing ports: 22, 80, 443, 6443, 2379-2380, 10250-10255
- SSH access from deployment machine to all nodes

### Software Requirements
- **Deployment machine**: Windows with PowerShell 5.1+
- **All VMs**: Ubuntu 20.04/22.04 LTS (recommended)
- SSH key-based authentication configured

## Initial Setup

### 1. Configure SSH Access

```powershell
# Generate SSH key if needed
ssh-keygen -t rsa -b 4096 -f $HOME\.ssh\id_rsa

# Copy SSH key to all nodes (replace with your IPs)
$nodes = @("10.0.1.100", "10.0.1.10", "10.0.1.11", "10.0.1.12", 
           "10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25")

foreach ($node in $nodes) {
    ssh-copy-id ubuntu@$node
}
```

### 2. Update Cluster Configuration

Edit the `cluster.json` file in the repository root to match your environment:

```json
{
  "cluster": {
    "name": "k3s-ha-production",
    "version": "v1.31.1+k3s1"
  },
  "network": {
    "proxyIP": "10.0.1.100",
    "controlPlaneIPs": [
      "10.0.1.10",
      "10.0.1.11", 
      "10.0.1.12"
    ],
    "workerIPs": [
      "10.0.1.20",
      "10.0.1.21",
      "10.0.1.22",
      "10.0.1.23",
      "10.0.1.24",
      "10.0.1.25"
    ]
  },
  "storage": {
    "device": "/dev/sdb",
    "nfsMountPath": "/data/nfs"
  },
  "ssh": {
    "user": "ubuntu",
    "keyPath": "~/.ssh/id_rsa"
  },
  "k3s": {
    "token": null,
    "disableServices": ["traefik"],
    "tlsSans": []
  },
  "operations": {
    "drainTimeout": 300,
    "upgradeStrategy": "rolling",
    "backupRetention": 7
  }
}
```

**Configuration Notes:**
- Update all IP addresses to match your environment
- The `token` field can be left null (will be auto-generated)
- The `tlsSans` array will auto-populate with proxy and control plane IPs if left empty
- Modify `disableServices` to exclude unwanted K3s components
- Set appropriate timeout and retention values for your environment

**Kubernetes Configuration Options:**
- `serviceCIDR`: IP range for Kubernetes services (default: 10.43.0.0/16)
- `clusterCIDR`: IP range for pods (default: 10.42.0.0/16) 
- `clusterDNS`: DNS server IP for pods (default: 10.43.0.10)
- `clusterDomain`: DNS domain for cluster (default: cluster.local)
- `nodePortRange`: Port range for NodePort services (default: 30000-32767)
- `maxPods`: Maximum pods per node (default: 110)

**Advanced K3s Configuration:**
- `extraArgs.server`: Additional arguments for K3s server nodes
- `extraArgs.agent`: Additional arguments for K3s agent (worker) nodes

**Example custom configurations:**
```json
{
  "kubernetes": {
    "serviceCIDR": "172.20.0.0/16",
    "clusterCIDR": "172.21.0.0/16",
    "maxPods": 200
  },
  "k3s": {
    "extraArgs": {
      "server": ["--kube-apiserver-arg=audit-log-path=/var/log/audit.log"],
      "agent": ["--kubelet-arg=image-gc-high-threshold=90"]
    }
  }
}
```

## Deployment Process

### Option 1: Full Automated Deployment

```powershell
# Run the deployment script with default cluster.json
.\k3s-complete-setup.ps1

# Or specify a custom configuration file
.\k3s-complete-setup.ps1 -ConfigFile "production-cluster.json"

# Select option 1 for full deployment
Select option (1-6): 1
```

This will:
1. Generate all configuration files
2. Setup the Nginx proxy
3. Install K3s on all control plane nodes with NFS
4. Install K3s on all worker nodes
5. Configure NFS storage provisioner
6. Verify the cluster

### Option 2: Step-by-Step Deployment

For more control, deploy each component separately:

```powershell
# Step 1: Generate configuration files only
.\k3s-complete-setup.ps1
Select option (1-6): 2

# Review generated files:
# - nginx.conf
# - setup-proxy.sh
# - setup-control plane.sh
# - setup-worker.sh
# - nfs-provisioner.yaml

# Step 2: Deploy proxy
.\k3s-complete-setup.ps1
Select option (1-6): 3

# Step 3: Deploy control planes (wait for completion)
.\k3s-complete-setup.ps1
Select option (1-6): 4

# Step 4: Deploy workers
.\k3s-complete-setup.ps1
Select option (1-6): 5

# Step 5: Configure cluster
.\k3s-complete-setup.ps1
Select option (1-6): 6
```

### Manual Deployment (Using Generated Scripts)

If you prefer to deploy manually:

```bash
# On proxy node
scp setup-proxy.sh ubuntu@10.0.1.100:/tmp/
ssh ubuntu@10.0.1.100 "chmod +x /tmp/setup-proxy.sh && sudo /tmp/setup-proxy.sh"

# On each control plane (adjust parameters)
scp setup-control plane.sh ubuntu@10.0.1.10:/tmp/
ssh ubuntu@10.0.1.10 "chmod +x /tmp/setup-control plane.sh && sudo /tmp/setup-control plane.sh 1 10.0.1.10 <token> v1.31.1+k3s1 /dev/sdb /data/nfs"

# On each worker
scp setup-worker.sh ubuntu@10.0.1.20:/tmp/
ssh ubuntu@10.0.1.20 "chmod +x /tmp/setup-worker.sh && sudo /tmp/setup-worker.sh 10.0.1.100 <token> v1.31.1+k3s1"
```

## Post-Deployment Configuration

### 1. Configure kubectl Access

The deployment script automatically configures kubectl. To use it:

```powershell
# Set the kubeconfig environment variable
$env:KUBECONFIG = "$HOME\.kube\k3s-config"

# Verify cluster access
kubectl get nodes

# Make it permanent (add to PowerShell profile)
Add-Content $PROFILE '$env:KUBECONFIG = "$HOME\.kube\k3s-config"'
```

### 2. Verify Cluster Health

```powershell
# Check all nodes are ready
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Check storage classes
kubectl get storageclass

# Test NFS provisioner
kubectl apply -f - @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
"@

kubectl get pvc test-pvc
kubectl delete pvc test-pvc
```

### 3. Access Monitoring

```powershell
# View proxy status page
Start-Process "http://10.0.1.100/"

# Check Nginx logs on proxy
ssh ubuntu@10.0.1.100 "sudo tail -f /var/log/nginx/k3s-access.log"

# Check K3s logs on control planes
ssh ubuntu@10.0.1.10 "sudo journalctl -u k3s -f"
```

## Using the Cluster

### Deploy Applications

Example deployment using NFS storage:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-example
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        volumeMounts:
        - name: shared-data
          mountPath: /usr/share/nginx/html
      volumes:
      - name: shared-data
        persistentVolumeClaim:
          claimName: nginx-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nginx-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
```

### Storage Classes Available

- **nfs-client**: Dynamic provisioning with delete reclaim policy
- **nfs-client-retain**: Dynamic provisioning with retain reclaim policy

### NFS Direct Access

For applications requiring direct NFS access:
- Server: Any control plane IP (10.0.1.10, 10.0.1.11, or 10.0.1.12)
- Exports:
  - `/data/nfs/shared` - General shared storage
  - `/data/nfs/data` - Application data
  - `/data/nfs/backups` - Backup storage

## Maintenance Operations

### Adding a New Worker Node

```powershell
# Add new worker node using operations script
.\operations\k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26"

# Or specify custom configuration file
.\operations\k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26" -ConfigFile "production-cluster.json"

# Add new control plane node
.\operations\k3s-add-node.ps1 -NodeType control plane -NewNodeIP "10.0.1.13"
```

### Updating Nginx Proxy Configuration

```bash
# Edit nginx configuration on proxy
ssh ubuntu@10.0.1.100
sudo nano /etc/nginx/nginx.conf

# Test configuration
sudo nginx -t

# Reload without dropping connections
sudo nginx -s reload
```

### Backing Up Cluster Data

```powershell
# Backup etcd (on any control plane)
ssh ubuntu@10.0.1.10 "sudo k3s etcd-snapshot save --name backup-$(date +%Y%m%d)"

# Backup NFS data
ssh ubuntu@10.0.1.10 "sudo tar -czf /data/nfs/backups/nfs-backup-$(date +%Y%m%d).tar.gz /data/nfs/shared /data/nfs/data"
```

## Troubleshooting

### Common Issues

1. **Nodes not joining cluster**
   ```bash
   # Check K3s service status
   sudo systemctl status k3s
   
   # View K3s logs
   sudo journalctl -u k3s -n 100
   ```

2. **Proxy not forwarding traffic**
   ```bash
   # Test backend connectivity from proxy
   curl -k https://10.0.1.10:6443/healthz
   
   # Check Nginx error log
   sudo tail -f /var/log/nginx/error.log
   ```

3. **NFS provisioner not working**
   ```bash
   # Check provisioner logs
   kubectl logs -n nfs-provisioner deployment/nfs-client-provisioner
   
   # Verify NFS exports on control planes
   showmount -e 10.0.1.10
   ```

### Health Checks

```powershell
# Quick health check script
$healthCheck = @'
Write-Host "=== K3s Cluster Health Check ===" -ForegroundColor Green

# Check nodes
Write-Host "`nNodes Status:" -ForegroundColor Yellow
kubectl get nodes

# Check critical pods
Write-Host "`nControl Plane Pods:" -ForegroundColor Yellow
kubectl get pods -n kube-system | Select-String "coredns|metrics-server|local-path"

# Check NFS provisioner
Write-Host "`nNFS Provisioner:" -ForegroundColor Yellow
kubectl get pods -n nfs-provisioner

# Test proxy connectivity
Write-Host "`nProxy Health:" -ForegroundColor Yellow
$proxyTest = Invoke-WebRequest -Uri "http://10.0.1.100/nginx_status" -UseBasicParsing
if ($proxyTest.StatusCode -eq 200) {
    Write-Host "Proxy is healthy" -ForegroundColor Green
} else {
    Write-Host "Proxy issue detected" -ForegroundColor Red
}
'@

Invoke-Expression $healthCheck
```

## Security Considerations

1. **Network Security**
   - Ensure cluster network is isolated
   - Use firewall rules to restrict access
   - Consider network policies for pod-to-pod communication

2. **Access Control**
   - Regularly rotate K3s tokens
   - Use RBAC for user access
   - Secure kubeconfig files

3. **Storage Security**
   - NFS exports are limited to cluster network
   - Consider encryption for sensitive data
   - Regular backups to separate location

## Performance Tuning

### Nginx Proxy Optimization
- Adjust worker_connections based on load
- Monitor connection counts
- Consider running multiple proxy VMs for redundancy

### NFS Performance
- Use dedicated network for storage traffic if possible
- Monitor NFS server load on control planes
- Consider SSD storage for better performance

### K3s Optimization
- Adjust --kube-apiserver-arg flags for API performance
- Monitor etcd performance
- Scale workers based on application needs