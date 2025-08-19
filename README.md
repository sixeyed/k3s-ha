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
│ CP-1  │ │ CP-2  │ │ CP-3  │ (10.0.1.10-12)
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

- **High Availability**: 3 control plane nodes with automatic failover (configurable 1-N control plane nodes)
- **No Virtual IP Required**: Uses Nginx proxy for load balancing
- **Environment Agnostic**: Works with any SSH-accessible infrastructure (bare metal, cloud VMs, Vagrant)
- **Integrated Storage**: NFS running on control plane nodes with dynamic provisioning
- **Kubernetes Network Control**: Configure pod/service CIDRs, DNS, and networking
- **Centralized Configuration**: JSON-based config with environment support
- **Production Ready**: Includes monitoring, backup, and upgrade procedures
- **Fully Automated**: PowerShell scripts handle entire deployment
- **Flexible Scaling**: Deploy anywhere from 1+1 (test) to 3+N (production)

## 📋 Prerequisites

### For Local Testing (Vagrant)
- **VirtualBox** 6.1+ or VMware
- **Vagrant** 2.3+
- **PowerShell 5.1+** (Windows, Linux, or macOS)
- **8GB+ RAM** and **20GB+ disk space** for VMs

### For Production/Remote Deployment
- **Ubuntu VMs** (20.04/22.04 LTS recommended) - Minimum 3 VMs (1 proxy + 1 control plane + 1 worker), recommended 10 VMs for HA
- **PowerShell 5.1+** on deployment machine (Windows, Linux, or macOS)
- **SSH key authentication** configured for all nodes
- **Network connectivity** between all nodes
- **Storage devices** on control plane nodes (for NFS, optional if using existing storage)

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
       "controlPlaneIPs": ["10.0.1.10", "10.0.1.11", "10.0.1.12"],
       "workerIPs": ["10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25"]
     },
     "kubernetes": {
       "serviceCIDR": "10.43.0.0/16",
       "clusterCIDR": "10.42.0.0/16",
       "maxPods": 110
     },
     "ssh": {
       "user": "ubuntu",
       "keyPath": "~/.ssh/id_rsa"
     }
   }
   ```

3. **Run deployment**
   ```powershell
   ./setup/k3s-setup.ps1
   # Defaults to full deployment (-Action Deploy)
   ```

4. **Verify cluster**
   ```powershell
   $env:KUBECONFIG = "$HOME\.kube\k3s-config"
   kubectl get nodes
   ```

## 📁 Repository Structure

### Configuration
- [cluster.json](/cluster.json) - Main configuration file for all cluster settings
- [lib/K3sCluster.psm1](/lib/K3sCluster.psm1) - Shared PowerShell module with all cluster functions

### Local Testing & Demo Apps
- [test/clusters/vagrant/minimal/](/test/clusters/vagrant/minimal/) - Minimal test environment (3 VMs: proxy + control plane + worker)
- [test/clusters/vagrant/minimal/Vagrantfile](/test/clusters/vagrant/minimal/Vagrantfile) - VirtualBox/VMware Vagrant configuration
- [test/clusters/vagrant/minimal/vagrant-cluster.json](/test/clusters/vagrant/minimal/vagrant-cluster.json) - Vagrant-specific configuration
- [test/clusters/vagrant/minimal/ssh_keys/](/test/clusters/vagrant/minimal/ssh_keys) - Vagrant SSH keys (auto-generated, ignored by git)
- [test/apps/](/test/apps/) - Demo applications for testing cluster functionality
  - `deploy-postgres-nfs.ps1` - PostgreSQL with NFS storage demo
  - `deploy-redis-local.ps1` - Redis with local storage demo  
  - `deploy-nginx-lb.ps1` - Nginx load balancer demo
  - `deploy-all-demos.ps1` - Deploy and test all demo apps

### Initial Setup
- [setup/k3s-setup.ps1](/setup/k3s-setup.ps1) - Main deployment script
- [setup/k3s-deployment-guide.md](/setup/k3s-deployment-guide.md) - Detailed deployment instructions
- [setup/config/](/setup/config) - Generated deployment configuration files (ignored by git)

### Day 2 Operations
- [operations/k3s-add-node.ps1](/operations/k3s-add-node.ps1) - Add new nodes to cluster
- [operations/k3s-upgrade-cluster.ps1](/operations/k3s-upgrade-cluster.ps1)  - Perform rolling upgrades
- [operations/k3s-certificate-renewal.ps1](/operations/k3s-certificate-renewal.ps1)  - Manage TLS certificates
- [operations/k3s-backup-restore.ps1](/operations/k3s-backup-restore.ps1)  - Backup and restore procedures
- [operations/k3s-health-troubleshoot.ps1](/operations/k3s-health-troubleshoot.ps1)  - Health checks and diagnostics

### Testing & Validation
- [test-config.ps1](/test-config.ps1) - Validate configuration and test module functions

## 🔧 Common Operations

### Add a New Worker Node
```powershell
./operations/k3s-add-node.ps1 -NodeType worker -NewNodeIP "10.0.1.26"
```

### Upgrade Cluster
```powershell
./operations/k3s-upgrade-cluster.ps1 -NewK3sVersion "v1.31.2+k3s1"
```

## 🧪 Testing

### Minimal Cluster Setup with Vagrant

The fastest way to test the deployment is using the included Vagrant environment. This creates a complete working cluster that's perfect for testing and development:

```powershell
# 1. Navigate to minimal cluster directory
cd test/clusters/vagrant/minimal

# 2. Start VMs (creates 3 VMs: proxy + control plane + worker) 
./vagrant-setup.ps1 up

# 3. Deploy K3s cluster with NFS provisioner
cd ../../../../setup
./k3s-setup.ps1 -ConfigFile "../test/clusters/vagrant/minimal/vagrant-cluster.json"

# 4. Test with demo apps
cd ../test/apps
./deploy-postgres-nfs.ps1 -Action deploy -Namespace demo-apps    # Test NFS storage
./deploy-postgres-nfs.ps1 -Action test -Namespace demo-apps      # Verify functionality

# 5. Verify cluster
kubectl get nodes
kubectl get pods -A
kubectl get pvc,sc -n demo-apps  # Check storage
```

**VM Management:**
```powershell
cd test/clusters/vagrant/minimal
./vagrant-setup.ps1 status      # Check VM status
vagrant ssh k3s-control-plane-1  # SSH to control plane node
vagrant ssh k3s-worker-1         # SSH to worker node  
vagrant ssh k3s-proxy            # SSH to proxy node
./vagrant-setup.ps1 destroy      # Clean up everything
```

**Test Environment Details:**
- **Proxy**: 192.168.56.100 (k3s-proxy) - Nginx load balancer with status page
- **Control Plane**: 192.168.56.10 (k3s-control-plane-1) - K3s server + integrated NFS server  
- **Worker**: 192.168.56.20 (k3s-worker-1) - K3s agent for application workloads
- **SSH**: Automatically configured with Vagrant keys (no manual setup required)
- **Storage**: Full NFS dynamic provisioner with `nfs-client` and `nfs-client-retain` storage classes
- **Networking**: Complete pod/service CIDR configuration with DNS

**Platform Compatibility:**
- ✅ **Intel Mac/Windows/Linux**: Full VirtualBox support
- ✅ **Apple Silicon (ARM64)**: VirtualBox 7.1+ with Bento ubuntu-22.04 ARM64 boxes
- ✅ **VMware**: Alternative to VirtualBox (configure in Vagrantfile)

**Demo Applications:**
Test the cluster with included demo apps that showcase different storage patterns:
- **PostgreSQL + NFS**: Persistent database with shared storage (`nfs-client`)  
- **Redis + Local**: High-performance cache with local storage (`local-path`)
- **Nginx + LoadBalancer**: Web service with NodePort load balancing

### Testing with Remote VMs
```powershell
# Deploy a minimal cluster (1 proxy + 1 control plane + 1 worker) for testing
./test-config.ps1 -ConfigFile "test-cluster.json"  # Validate configuration
./setup/k3s-setup.ps1 -ConfigFile "test-cluster.json"
```

### Using Custom Configuration
```powershell
# Use different configuration files for different environments
./setup/k3s-setup.ps1 -ConfigFile "staging-cluster.json"
./setup/k3s-setup.ps1 -ConfigFile "production-cluster.json" -Action Deploy

# Step-by-step deployment options
./setup/k3s-setup.ps1 -Action PrepareOnly        # Generate scripts only
./setup/k3s-setup.ps1 -Action ProxyOnly         # Deploy proxy only
./setup/k3s-setup.ps1 -Action ControlPlaneOnly  # Deploy control plane nodes only
./setup/k3s-setup.ps1 -Action WorkersOnly       # Deploy workers only
./setup/k3s-setup.ps1 -Action ConfigureOnly     # Configure cluster only

# Import kubeconfig only (for existing clusters)
./setup/k3s-setup.ps1 -Action ImportKubeConfig -ConfigFile "cluster.json"

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

## 🌐 Kubernetes Network Configuration

The cluster provides full control over Kubernetes networking through the configuration file:

```json
{
  "kubernetes": {
    "serviceCIDR": "10.43.0.0/16",      // IP range for services
    "clusterCIDR": "10.42.0.0/16",      // IP range for pods
    "clusterDNS": "10.43.0.10",         // DNS server for pods
    "clusterDomain": "cluster.local",    // DNS domain
    "nodePortRange": "30000-32767",     // NodePort service range
    "maxPods": 110                      // Max pods per node
  }
}
```

**Benefits:**
- Avoid IP conflicts with existing networks
- Customize DNS settings for cluster services
- Scale pod density per node based on resources
- Control service port ranges

## 💾 Storage

The cluster includes two storage options:
- **NFS** (dynamic provisioning via control plane nodes)
- **Local storage** (for high-performance workloads)

**Storage Classes Available:**
- `nfs-client` - Dynamic NFS provisioning with delete reclaim policy (data deleted when PVC is removed)
- `nfs-client-retain` - Dynamic NFS provisioning with retain reclaim policy (data preserved when PVC is removed)  
- `local-path` - Local node storage for high-performance workloads (default)

**NFS Features:**
- **Integrated NFS Server**: Runs directly on control plane nodes (no external dependencies)
- **Dynamic Provisioning**: Automatic volume creation and management
- **ReadWriteMany (RWX)**: Volumes can be mounted by multiple pods simultaneously
- **Cross-Node Access**: Pods on any node can access the same NFS volume
- **Backup Integration**: NFS data included in cluster backup procedures

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
ssh ubuntu@control-plane-ip "showmount -e localhost"
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