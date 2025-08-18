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
```

### Configuration Testing & Validation
```powershell
# Test configuration file validity
./test-config.ps1
./test-config.ps1 -ConfigFile "production-cluster.json"

# Local testing with Vagrant (easiest for development)
cd test/minimal-cluster
./vagrant-setup.ps1 prereqs   # Check prerequisites first
./vagrant-setup.ps1 up        # Start 3 VMs (checks prereqs automatically)
pwsh ../../setup/k3s-setup.ps1 -ConfigFile test/minimal-cluster/vagrant-cluster.json  # Deploy K3s cluster (automatic)
./vagrant-setup.ps1 destroy   # Clean up

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
  - `k3s-setup.ps1` - Main deployment automation script (renamed from k3s-complete-setup.ps1)
  - `k3s-deployment-guide.md` - Detailed deployment instructions and troubleshooting
  - `config/` - Generated deployment configuration files (ignored by git)
  
- **operations/** - Day 2 operational scripts
  - `k3s-add-node.ps1` - Add new master or worker nodes
  - `k3s-upgrade-cluster.ps1` - Rolling cluster upgrades
  - `k3s-certificate-renewal.ps1` - TLS certificate management
  - `k3s-backup-restore.ps1` - Backup and restore procedures
  - `k3s-health-troubleshoot.ps1` - Health checks and diagnostics

- **Local Testing Environment**
  - `Vagrantfile` - Creates 3 VMs for local testing
  - `test/minimal-cluster/vagrant-cluster.json` - Configuration for Vagrant environment
  - `test/minimal-cluster/vagrant-setup.ps1` - Manage Vagrant test environment
  - `test/minimal-cluster/ssh_keys/` - Vagrant SSH keys (auto-generated, ignored by git)

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
    "nfsMountPath": "/data/nfs"
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
- **NFS Dynamic Provisioning** - Via masters with storage classes:
  - `nfs-client` - Dynamic provisioning with delete reclaim policy
  - `nfs-client-retain` - Dynamic provisioning with retain reclaim policy
- **Local Storage** - For high-performance workloads using local-path provisioner

NFS exports available:
- `/data/nfs/shared` - General shared storage
- `/data/nfs/data` - Application data storage  
- `/data/nfs/backups` - Backup storage location

## Development Guidelines

When modifying scripts:
- All PowerShell scripts use SSH for remote execution via helper functions  
- Linux shell scripts are embedded as here-strings and deployed via SCP
- Configuration is loaded from JSON files using the shared `lib/K3sCluster.psm1` module
- IP addresses and settings are parameterized through the configuration system
- All remote operations include error handling and status reporting
- Scripts support both automated and manual execution modes
- Use `-ConfigFile` parameter to support multiple environments
- Generated deployment files are stored in `setup/config/` and ignored by git
- SSH keys for Vagrant testing are stored in `test/minimal-cluster/ssh_keys/` and ignored by git

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

## Prerequisites

- **PowerShell 5.1+** on deployment machine (Windows)
- **10 Ubuntu VMs** (20.04/22.04 LTS) with static IP addresses
- **SSH key authentication** configured for all nodes
- **Network connectivity** between all nodes on same subnet

## Security Features

- TLS encryption for all K3s communication
- SSH key-based authentication only (no passwords)
- Network isolation recommendations in deployment guide
- Regular certificate rotation procedures
- RBAC enabled by default on cluster
- Firewall configuration included in setup scripts