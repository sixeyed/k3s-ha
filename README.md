# K3s High Availability Cluster Deployment Suite

A comprehensive PowerShell-based deployment and management solution for production-ready K3s Kubernetes clusters in on-premises datacenters.

## 🎯 Overview

This repository provides a complete Infrastructure-as-Code solution for deploying and managing a highly available K3s cluster without requiring virtual IPs. Perfect for environments where traditional HA solutions aren't feasible.

### Architecture

```
┌─────────────────┐
│   Nginx Proxy   │ (10.0.1.100)
│   (2CPU/4GB)    │
└────────┬────────┘
         │
    ┌────┴────┬─────────┐
    │         │         │
┌───▼───┐ ┌──▼───┐ ┌──▼───┐
│Master1│ │Master2│ │Master3│ (10.0.1.10-12)
│ +NFS  │ │ +NFS  │ │ +NFS  │ (4CPU/16GB + 500GB storage)
└───┬───┘ └───┬───┘ └───┬───┘
    │         │         │
    └────┬────┴─────────┘
         │
    ┌────┴────┬─────────┬─────────┬─────────┬─────────┐
    │         │         │         │         │         │
┌───▼───┐ ┌──▼───┐ ┌──▼───┐ ┌──▼───┐ ┌──▼───┐ ┌──▼───┐
│Worker1│ │Worker2│ │Worker3│ │Worker4│ │Worker5│ │Worker6│
└───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘
(10.0.1.20-25, 8-16CPU/32-64GB)
```

### Key Features

- **High Availability**: 3 master nodes with automatic failover
- **No Virtual IP Required**: Uses Nginx proxy for load balancing
- **Integrated Storage**: NFS running on master nodes
- **Production Ready**: Includes monitoring, backup, and upgrade procedures
- **Fully Automated**: PowerShell scripts handle entire deployment

## 📋 Prerequisites

- **10 Ubuntu VMs** (20.04/22.04 LTS recommended)
- **PowerShell 5.1+** on deployment machine
- **SSH key authentication** configured
- **Network connectivity** between all nodes

## 🚀 Quick Start

1. **Clone this repository**
   ```powershell
   git clone https://github.com/sixeyed/k3s-ha
   cd k3s-ha
   ```

2. **Update configuration**
   Edit the [cluster.json](/cluster.json) file to match your environment:
   ```json
   {
     "network": {
       "proxyIP": "10.0.1.100",
       "masterIPs": ["10.0.1.10", "10.0.1.11", "10.0.1.12"],
       "workerIPs": ["10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25"]
     },
     "ssh": {
       "user": "ubuntu"
     }
   }
   ```

3. **Run deployment**
   ```powershell
   ./setup/k3s-complete-setup.ps1
   # Select option 1 for full deployment
   ```

4. **Verify cluster**
   ```powershell
   $env:KUBECONFIG = "$HOME\.kube\k3s-config"
   kubectl get nodes
   ```

## 📁 Repository Structure

### Initial Setup
- [k3s-complete-setup.ps1](/setup/k3s-complete-setup.ps1) - Main deployment script
- [k3s-deployment-guide.md](/setup/k3s-deployment-guide.md) - Detailed deployment instructions

### Day 2 Operations
- [k3s-add-node.ps1](/operations/k3s-add-node.ps1) - Add new nodes to cluster
- [k3s-upgrade-cluster.ps1](/operations/k3s-upgrade-cluster.ps1)  - Perform rolling upgrades
- [k3s-certificate-renewal.ps1](/operations/k3s-certificate-renewal.ps1)  - Manage TLS certificates
- [k3s-backup-restore.ps1](/operations/k3s-backup-restore.ps1)  - Backup and restore procedures
- [k3s-health-troubleshoot.ps1](/operations/k3s-health-troubleshoot.ps1)  - Health checks and diagnostics

## 🔧 Common Operations

### Add a New Worker Node
```powershell
./operations/k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26"
```

### Upgrade Cluster
```powershell
./operations/k3s-upgrade-cluster.ps1 -NewK3sVersion "v1.31.2+k3s1"
```

### Using Custom Configuration
```powershell
# Use a different configuration file
./setup/k3s-complete-setup.ps1 -ConfigFile "staging-cluster.json"
./operations/k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26" -ConfigFile "staging-cluster.json"
```

### Check Cluster Health
```powershell
./operations/k3s-health-troubleshoot.ps1 -Mode health
```

### Backup Cluster
```powershell
./operations/k3s-backup-restore.ps1 -Operation backup -IncludeNFSData
```

## 🛡️ Security Considerations

- All communication encrypted with TLS
- SSH key-based authentication only
- Network isolation recommended
- Regular certificate rotation
- RBAC enabled by default

## 💾 Storage

The cluster includes two storage options:
- **NFS** (dynamic provisioning via master nodes)
- **Local storage** (for high-performance workloads)

Storage classes available:
- `nfs-client` - Dynamic NFS with delete policy
- `nfs-client-retain` - Dynamic NFS with retain policy

## 🔍 Monitoring

Access points:
- **Nginx Status**: http://proxy-ip/
- **Kubernetes Dashboard**: Deploy separately
- **Metrics Server**: Included for resource monitoring

## 🆘 Troubleshooting

### Node Not Joining
```powershell
# Check node logs
ssh ubuntu@node-ip "sudo journalctl -u k3s -n 100"
```

### Storage Issues
```powershell
# Check NFS exports
ssh ubuntu@master-ip "showmount -e localhost"
```

### Proxy Issues
```powershell
# Check Nginx logs
ssh ubuntu@proxy-ip "sudo tail -f /var/log/nginx/k3s-access.log"
```

## 📈 Scaling

The architecture supports:
- Up to 100 worker nodes
- Thousands of pods
- Multiple storage backends


## 🙏 Acknowledgments

- K3s by Rancher Labs

---

**Need Help?** Check the deployment guide or open an issue.