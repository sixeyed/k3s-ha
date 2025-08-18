# K3s Cluster Demo Applications

This directory contains three demo applications designed to test different aspects of the K3s cluster:

## Demo Applications

### 1. Nginx LoadBalancer Demo (`nginx-lb/`)
**Purpose**: Test LoadBalancer service functionality and external access

- **Technology**: Nginx web server
- **Service Type**: LoadBalancer (becomes NodePort in K3s)
- **Storage**: None (stateless)
- **Test Coverage**: 
  - Service discovery and load balancing
  - External access via NodePort
  - Pod scaling and availability

### 2. Redis Local Storage Demo (`redis-local/`)
**Purpose**: Test local persistent storage with `local-path` storage class

- **Technology**: Redis in-memory database
- **Service Type**: ClusterIP
- **Storage**: 1Gi PVC using `local-path` storage class
- **Test Coverage**:
  - Local persistent volumes
  - Data persistence across pod restarts  
  - Storage class functionality

### 3. PostgreSQL NFS Storage Demo (`postgres-nfs/`)
**Purpose**: Test NFS persistent storage with `nfs-client` storage class

- **Technology**: PostgreSQL database
- **Service Type**: ClusterIP
- **Storage**: 2Gi PVC using `nfs-client` storage class
- **Test Coverage**:
  - NFS persistent volumes
  - Database initialization and data persistence
  - Network-attached storage functionality

## Deployment Scripts

### Individual App Deployment
Each app has its own PowerShell deployment script:

```powershell
# Deploy and test nginx LoadBalancer
./deploy-nginx-lb.ps1 -Action deploy
./deploy-nginx-lb.ps1 -Action test
./deploy-nginx-lb.ps1 -Action cleanup

# Deploy and test Redis with local storage
./deploy-redis-local.ps1 -Action deploy
./deploy-redis-local.ps1 -Action test
./deploy-redis-local.ps1 -Action cleanup

# Deploy and test PostgreSQL with NFS storage
./deploy-postgres-nfs.ps1 -Action deploy
./deploy-postgres-nfs.ps1 -Action test
./deploy-postgres-nfs.ps1 -Action cleanup
```

### All Apps at Once
Use the master script to deploy and test all apps:

```powershell
# Full deployment and testing
./deploy-all-demos.ps1 -Action full

# Deploy all apps
./deploy-all-demos.ps1 -Action deploy

# Test all apps
./deploy-all-demos.ps1 -Action test

# Clean up all apps
./deploy-all-demos.ps1 -Action cleanup
```

## Prerequisites

Before running the demo apps, ensure:

1. **Cluster Access**: `kubectl` can connect to your K3s cluster
2. **Helm**: Helm 3.x is installed and working
3. **Storage Classes**: 
   - `local-path` storage class exists (default in K3s)
   - `nfs-client` storage class exists (from NFS provisioner)

Check prerequisites:
```bash
kubectl get nodes
kubectl get storageclass
helm version
```

## Expected Test Results

### Successful Deployment Indicators

**Nginx LoadBalancer:**
- ✅ 2 nginx pods running
- ✅ LoadBalancer service created (as NodePort)  
- ✅ HTTP access working on NodePort
- ✅ Load balancing between pods

**Redis Local Storage:**
- ✅ 1 Redis pod running
- ✅ PVC bound to local-path storage
- ✅ Redis SET/GET operations working
- ✅ Data persists across pod restarts

**PostgreSQL NFS Storage:**
- ✅ 1 PostgreSQL pod running
- ✅ PVC bound to nfs-client storage
- ✅ Database accepting connections
- ✅ Demo data initialized and queryable
- ✅ Data stored on NFS mount

### Network Access

**External Access (LoadBalancer):**
- Nginx app accessible at: `http://192.168.56.10:NodePort` or `http://192.168.56.20:NodePort`
- NodePort will be displayed after deployment

**Internal Access (ClusterIP):**
- Redis: `redis-demo-redis-local.demo-apps.svc.cluster.local:6379`
- PostgreSQL: `postgres-demo-postgres-nfs.demo-apps.svc.cluster.local:5432`

## Troubleshooting

### Common Issues

**Pods stuck in ContainerCreating:**
```bash
kubectl describe pod <pod-name> -n demo-apps
# Look for volume mount issues
```

**PVC not binding:**
```bash
kubectl get pvc -n demo-apps
kubectl describe pvc <pvc-name> -n demo-apps
# Check if storage class exists and is working
```

**NFS mount failures:**
```bash
# Check NFS server on master node
ssh vagrant@192.168.56.10 "showmount -e localhost"
# Verify NFS provisioner is running
kubectl get pods -n nfs-provisioner
```

**LoadBalancer not accessible:**
```bash
# Check service and get NodePort
kubectl get svc -n demo-apps
# Test from cluster nodes directly
curl http://192.168.56.10:<NodePort>
```

### Cleanup

To completely clean up:
```powershell
./deploy-all-demos.ps1 -Action cleanup
# Manually delete PVCs if needed
kubectl delete pvc --all -n demo-apps
kubectl delete namespace demo-apps
```

## Architecture Validation

These demo apps validate the complete K3s cluster architecture:

- **Proxy Layer**: LoadBalancer service tests external access through Nginx proxy
- **Compute Layer**: All pod types (stateless, stateful) deploy and run correctly
- **Storage Layer**: Both local and network storage classes work properly  
- **Network Layer**: Service discovery, internal/external communication working
- **High Availability**: Multiple storage backends and service types supported

Running all demos successfully confirms the cluster is production-ready for diverse workload types.