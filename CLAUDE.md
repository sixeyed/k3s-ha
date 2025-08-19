# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a PowerShell-based Infrastructure-as-Code solution for deploying and managing highly available K3s Kubernetes clusters in on-premises datacenters. The solution provides a complete deployment automation framework without requiring virtual IPs, using Nginx proxy for load balancing.

## Architecture

The cluster is highly configurable and supports various deployment sizes:

**Production HA Setup (recommended):**
- **1 Nginx Proxy VM** (10.0.1.100) - Load balances API traffic to masters
- **3 Control Plane Nodes** (10.0.1.10-12) - Masters with integrated NFS storage
- **6 Worker Nodes** (10.0.1.20-25) - Application workload nodes

**Minimal Test Setup:**
- **1 Nginx Proxy VM** - Load balancer
- **1 Control Plane Node** - Single master with NFS storage  
- **1 Worker Node** - Application workload node

Key architectural decisions:
- **Flexible scaling** - Deploy 1+1+1 for testing or 1+3+N for production
- **No virtual IP dependency** - uses Nginx for HA instead
- **Integrated NFS storage** - runs on master nodes for persistent volumes
- **Full Kubernetes networking control** - configurable CIDRs, DNS, pod limits
- **All communication secured with TLS**
- **Supports scaling** up to 100+ worker nodes

## Key Commands

### Initial Deployment
```powershell
# Full cluster deployment with default cluster.json
./setup/k3s-setup.ps1

# Use custom configuration file
./setup/k3s-setup.ps1 -ConfigFile "production-cluster.json"

# Explicit action (same as default)
./setup/k3s-setup.ps1 -Action Deploy

# Step-by-step deployment options:
./setup/k3s-setup.ps1 -Action PrepareOnly     # Generate scripts only
./setup/k3s-setup.ps1 -Action ProxyOnly      # Deploy proxy only  
./setup/k3s-setup.ps1 -Action MastersOnly    # Deploy masters only
./setup/k3s-setup.ps1 -Action WorkersOnly    # Deploy workers only
./setup/k3s-setup.ps1 -Action ConfigureOnly  # Configure cluster only

# Import kubeconfig only (for existing clusters)
./setup/k3s-setup.ps1 -Action ImportKubeConfig -ConfigFile "cluster.json"
```

### Configuration Testing & Validation
```powershell
# Test configuration file validity
./test-config.ps1
./test-config.ps1 -ConfigFile "production-cluster.json"

# Local testing with Vagrant (easiest for development - complete end-to-end workflow)
cd test/clusters/vagrant/minimal
./vagrant-setup.ps1 up        # Start 3 VMs with NFS setup (proxy + master + worker)

# Deploy K3s cluster with YAML-based NFS provisioner
cd ../../../../setup
./k3s-setup.ps1 -ConfigFile "../test/clusters/vagrant/minimal/vagrant-cluster.json"

# Test cluster functionality with demo apps
cd ../test/apps
./deploy-postgres-nfs.ps1 -Action deploy -Namespace demo-apps    # Deploy PostgreSQL with NFS
./deploy-postgres-nfs.ps1 -Action test -Namespace demo-apps      # Verify NFS storage works
./deploy-all-demos.ps1 -Action full                              # Deploy and test all demo apps

# Clean up
cd ../clusters/vagrant/minimal
./vagrant-setup.ps1 destroy   # Clean up VMs

# Deploy minimal test cluster on remote VMs
./setup/k3s-setup.ps1 -ConfigFile "test-cluster.json"
```

### Day 2 Operations
```powershell
# Add a new worker node
./operations/k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26"

# Add a new master node  
./operations/k3s-add-node.ps1 -NodeType master -NewNodeIP "10.0.1.13"

# Use custom configuration file
./operations/k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26" -ConfigFile "staging-cluster.json"

# Upgrade cluster to new K3s version
./operations/k3s-upgrade-cluster.ps1 -NewK3sVersion "v1.31.2+k3s1"

# Upgrade with custom configuration
./operations/k3s-upgrade-cluster.ps1 -NewK3sVersion "v1.31.2+k3s1" -ConfigFile "production-cluster.json"

# Perform cluster health check and troubleshooting
./operations/k3s-health-troubleshoot.ps1 -Mode health

# Backup cluster data
./operations/k3s-backup-restore.ps1 -Operation backup -IncludeNFSData

# Restore from backup
./operations/k3s-backup-restore.ps1 -Operation restore -BackupPath "/path/to/backup"

# Renew TLS certificates
./operations/k3s-certificate-renewal.ps1 -RenewAll
```

### Cluster Access
```powershell
# Configure kubectl (done automatically by setup script)
$env:KUBECONFIG = "$HOME\.kube\k3s-config"

# Verify cluster
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
```

### Monitoring and Debugging
```powershell
# View proxy status page
Start-Process "http://10.0.1.100/"

# Check Nginx logs
ssh ubuntu@10.0.1.100 "sudo tail -f /var/log/nginx/k3s-access.log"

# Check K3s service logs on masters
ssh ubuntu@10.0.1.10 "sudo journalctl -u k3s -f"

# Check NFS exports
ssh ubuntu@10.0.1.10 "showmount -e localhost"
```

## Repository Structure

- **setup/** - Initial deployment scripts and documentation
  - `k3s-setup.ps1` - Main deployment automation script with YAML-based NFS provisioner
  - `k3s-deployment-guide.md` - Detailed deployment instructions and troubleshooting
  - `config/` - Generated deployment configuration files (ignored by git)
  
- **operations/** - Day 2 operational scripts
  - `k3s-add-node.ps1` - Add new master or worker nodes
  - `k3s-upgrade-cluster.ps1` - Rolling cluster upgrades
  - `k3s-certificate-renewal.ps1` - TLS certificate management
  - `k3s-backup-restore.ps1` - Backup and restore procedures
  - `k3s-health-troubleshoot.ps1` - Health checks and diagnostics

- **lib/** - Shared PowerShell modules
  - `K3sCluster.psm1` - Centralized cluster management functions with SSH automation

- **test/** - Testing environments and demo applications
  - **clusters/vagrant/minimal/** - Minimal test environment (3 VMs: proxy + master + worker)
    - `Vagrantfile` - VirtualBox/VMware VM configuration with ARM64 support
    - `vagrant-cluster.json` - Vagrant-specific configuration
    - `vagrant-setup.ps1` - Vagrant VM management script
    - `ssh_keys/` - Auto-generated Vagrant SSH keys (ignored by git)
  - **apps/** - Demo applications for testing cluster functionality
    - `deploy-postgres-nfs.ps1` - PostgreSQL with NFS storage (tests RWX volumes)
    - `deploy-redis-local.ps1` - Redis with local storage (tests RWO volumes)
    - `deploy-nginx-lb.ps1` - Nginx load balancer (tests NodePort services)
    - `deploy-all-demos.ps1` - Deploy and test all demo apps together

- **Generated Configuration Files**
  - `setup/config/` - Generated deployment files (nginx.conf, setup scripts, yaml files)
  - All generated files are ignored by git and created automatically during deployment

## Configuration Management

All configuration is centralized in JSON files, with `cluster.json` as the default:

```json
{
  "cluster": {
    "name": "k3s-ha-production",
    "version": "v1.31.1+k3s1"
  },
  "network": {
    "proxyIP": "10.0.1.100",
    "masterIPs": ["10.0.1.10", "10.0.1.11", "10.0.1.12"],
    "workerIPs": ["10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25"]
  },
  "kubernetes": {
    "serviceCIDR": "10.43.0.0/16",
    "clusterCIDR": "10.42.0.0/16", 
    "clusterDNS": "10.43.0.10",
    "clusterDomain": "cluster.local",
    "nodePortRange": "30000-32767",
    "maxPods": 110
  },
  "storage": {
    "device": "/dev/sdb",
    "nfsMountPath": "/data/nfs",
    "nfsProvisionerPath": "/data/nfs/shared"
  },
  "ssh": {
    "user": "ubuntu",
    "keyPath": "~/.ssh/id_rsa"
  },
  "k3s": {
    "token": null,
    "disableServices": ["traefik"],
    "tlsSans": [],
    "extraArgs": {
      "server": [],
      "agent": []
    }
  },
  "operations": {
    "drainTimeout": 300,
    "upgradeStrategy": "rolling", 
    "backupRetention": 7
  }
}
```

**Configuration Features:**
- **Centralized Configuration**: Single JSON file for all cluster settings
- **Kubernetes Networking**: Full control over pod/service CIDRs, DNS, and networking
- **Environment-Specific**: Support for multiple configuration files (staging, production, etc.)
- **Auto-Generation**: TLS SANs and tokens auto-populate if not specified
- **Path Expansion**: SSH key paths support `~` expansion
- **Validation**: Configuration loading includes error handling and validation
- **Extensible**: Add custom K3s arguments for servers and agents

**Multiple Environments:**
- Create separate config files: `staging-cluster.json`, `production-cluster.json`
- Pass config file to any script: `-ConfigFile "environment-cluster.json"`
- All scripts use the shared cluster management module: `lib/K3sCluster.psm1`

## Storage Architecture

The cluster provides two storage options:
- **NFS Dynamic Provisioning** - Via YAML-based provisioner running on masters with storage classes:
  - `nfs-client` - Dynamic provisioning with delete reclaim policy (data deleted when PVC removed)
  - `nfs-client-retain` - Dynamic provisioning with retain reclaim policy (data preserved when PVC removed)
- **Local Storage** - For high-performance workloads using local-path provisioner (default)

**NFS Implementation:**
- **Deployment Method**: YAML-based (replaced unreliable Helm charts)
- **Host Networking**: Uses host network for direct API server access
- **Provisioner Pod**: Runs with appropriate RBAC permissions and environment variables
- **Storage Classes**: Auto-creates both delete and retain policies
- **Functional Verification**: Deployment includes PVC test to ensure provisioner works

**NFS Exports Available:**
- `/data/nfs/shared` (or `/mnt/nfs-storage/shared` in Vagrant) - General shared storage
- `/data/nfs/data` (or `/mnt/nfs-storage/data` in Vagrant) - Application data storage  
- `/data/nfs/backups` (or `/mnt/nfs-storage/backups` in Vagrant) - Backup storage location

**Key Storage Features:**
- **ReadWriteMany (RWX)**: NFS volumes can be mounted by multiple pods on different nodes
- **Dynamic Provisioning**: Automatic volume creation and cleanup
- **Cross-Node Access**: Any pod on any node can access the same NFS volume
- **Environment Agnostic**: Works with any NFS path specified in configuration

## Development Guidelines

When modifying scripts:
- **Environment-Agnostic Design**: All scripts are completely environment-agnostic and work with any SSH-accessible infrastructure (bare metal, cloud VMs, Vagrant, etc.)
- All PowerShell scripts use SSH for remote execution via helper functions  
- Linux shell scripts are embedded as here-strings and deployed via SCP
- Configuration is loaded from JSON files using the shared `lib/K3sCluster.psm1` module
- IP addresses and settings are parameterized through the configuration system
- All remote operations include error handling and status reporting
- Scripts support both automated and manual execution modes
- Use `-ConfigFile` parameter to support multiple environments
- **No Environment-Specific Logic**: Scripts contain no Vagrant, cloud, or bare metal specific code paths
- SSH key paths support relative paths (resolved relative to config file location) and `~` expansion
- Generated deployment files are stored in `setup/config/` and ignored by git

**Module Usage:**
```powershell
# Import the cluster management module
Import-Module "$PSScriptRoot\..\lib\K3sCluster.psm1" -Force

# Load configuration 
$Config = Load-ClusterConfig -ConfigPath $ConfigFile

# Use helper functions
Invoke-SSHCommand -Config $Config -Node $nodeIP -Command $command
Copy-FileToNode -Config $Config -Node $nodeIP -LocalPath $file -RemotePath $path
Copy-FileFromNode -Config $Config -Node $nodeIP -RemotePath $remotePath -LocalPath $file

# Generate K3s arguments based on configuration
$serverArgs = Get-K3sServerArgs -Config $Config -IsFirstServer
$agentArgs = Get-K3sAgentArgs -Config $Config -ServerURL "https://proxy:6443"
```

**Available Module Functions:**
- `Load-ClusterConfig` - Load and validate JSON configuration
- `Invoke-SSHCommand` - Execute commands on remote nodes  
- `Copy-FileToNode` / `Copy-FileFromNode` - Transfer files via SCP
- `Get-K3sServerArgs` - Generate server arguments with networking settings
- `Get-K3sAgentArgs` - Generate agent arguments with pod limits

## Testing and Verification Workflows

### Complete End-to-End Testing (Recommended)
```powershell
# This workflow tests everything from VM creation to application deployment
cd test/clusters/vagrant/minimal
./vagrant-setup.ps1 destroy              # Clean slate (if needed)
./vagrant-setup.ps1 up                   # Create VMs with NFS setup

cd ../../../../setup
./k3s-setup.ps1 -ConfigFile "../test/clusters/vagrant/minimal/vagrant-cluster.json"

# Verify cluster is healthy
kubectl get nodes                         # Should show 2 nodes Ready
kubectl get pods -A                       # All system pods should be Running
kubectl get sc                            # Should show nfs-client storage classes

# Test NFS storage functionality
cd ../test/apps
./deploy-postgres-nfs.ps1 -Action deploy -Namespace demo-apps
./deploy-postgres-nfs.ps1 -Action test -Namespace demo-apps

# Clean up
./deploy-postgres-nfs.ps1 -Action cleanup -Namespace demo-apps
```

### NFS Provisioner Troubleshooting
```powershell
# Check NFS provisioner pod status
kubectl get pods -n nfs-provisioner
kubectl logs -n nfs-provisioner deployment/nfs-client-provisioner

# Verify NFS exports on master
vagrant ssh k3s-master-1 -c "showmount -e localhost"

# Test NFS mount manually
kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs
  namespace: default
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-client
EOF

# Check PVC status (should show Bound)
kubectl get pvc test-nfs
kubectl delete pvc test-nfs
```

### Common Issues and Solutions
1. **NFS provisioner CrashLoopBackOff**: 
   - Check NFS exports: `showmount -e <master-ip>`
   - Verify NFS directories exist and have correct permissions
   - Ensure YAML deployment includes host networking

2. **PVC stuck in Pending**: 
   - Check storage class exists: `kubectl get sc`
   - Check provisioner pod logs: `kubectl logs -n nfs-provisioner deployment/nfs-client-provisioner`

3. **Mount failures**: 
   - Verify NFS path configuration matches between cluster config and actual NFS exports
   - Check network connectivity between nodes

## Prerequisites

### For Local Testing (Vagrant)
- **VirtualBox 7.1+** (ARM64 support) or **VMware Workstation/Fusion**
- **Vagrant 2.3+** with VM provider plugins
- **PowerShell 7+** (cross-platform, includes Windows PowerShell 5.1+)
- **8GB+ RAM** available for VMs (1GB proxy + 2GB master + 1GB worker + host overhead)
- **20GB+ disk space** for VM storage and container images

### For Production/Remote Deployment  
- **PowerShell 5.1+** on deployment machine (Windows, Linux, or macOS)
- **Ubuntu VMs** (20.04/22.04 LTS recommended) - Minimum 3 VMs (1 proxy + 1 master + 1 worker)
- **SSH key authentication** configured for all nodes (no password authentication)
- **Network connectivity** between all nodes on same subnet
- **Storage devices** on master nodes for NFS (optional if using existing storage)
- **Static IP addresses** for all nodes (DHCP reservations acceptable)

## Security Features

- TLS encryption for all K3s communication
- SSH key-based authentication only (no passwords)
- Network isolation recommendations in deployment guide
- Regular certificate rotation procedures
- RBAC enabled by default on cluster
- Firewall configuration included in setup scripts