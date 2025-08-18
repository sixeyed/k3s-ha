# Deploy All Demo Apps
# This script deploys all three demo apps and runs comprehensive tests

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "test", "cleanup", "full")]
    [string]$Action = "full",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "demo-apps"
)

Write-Host "`n=== K3s Cluster Demo Apps Deployment ===" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan

function Test-Prerequisites {
    Write-Host "`nChecking prerequisites..." -ForegroundColor Yellow
    
    # Check kubectl
    try {
        $kubectlVersion = kubectl version --client --short 2>$null
        Write-Host "✓ kubectl: $kubectlVersion" -ForegroundColor Green
    } catch {
        Write-Host "✗ kubectl not found!" -ForegroundColor Red
        return $false
    }
    
    # Check helm
    try {
        $helmVersion = helm version --short 2>$null
        Write-Host "✓ helm: $helmVersion" -ForegroundColor Green
    } catch {
        Write-Host "✗ helm not found!" -ForegroundColor Red
        return $false
    }
    
    # Check cluster connectivity
    try {
        $nodes = kubectl get nodes --no-headers 2>$null
        $nodeCount = ($nodes | Measure-Object).Count
        Write-Host "✓ Cluster connectivity: $nodeCount nodes" -ForegroundColor Green
    } catch {
        Write-Host "✗ Cannot connect to cluster!" -ForegroundColor Red
        return $false
    }
    
    # Check storage classes
    $storageClasses = kubectl get storageclass --no-headers 2>$null
    $localPath = $storageClasses | Where-Object { $_ -match "local-path" }
    $nfsClient = $storageClasses | Where-Object { $_ -match "nfs-client" }
    
    if ($localPath) {
        Write-Host "✓ local-path storage class available" -ForegroundColor Green
    } else {
        Write-Host "⚠ local-path storage class not found" -ForegroundColor Yellow
    }
    
    if ($nfsClient) {
        Write-Host "✓ nfs-client storage class available" -ForegroundColor Green
    } else {
        Write-Host "⚠ nfs-client storage class not found" -ForegroundColor Yellow
    }
    
    return $true
}

function Deploy-AllApps {
    Write-Host "`n=== Deploying All Demo Apps ===" -ForegroundColor Green
    
    Write-Host "`n1. Deploying Nginx LoadBalancer..." -ForegroundColor Yellow
    & ./deploy-nginx-lb.ps1 -Action deploy -Namespace $Namespace
    
    Write-Host "`n2. Deploying Redis Local Storage..." -ForegroundColor Yellow
    & ./deploy-redis-local.ps1 -Action deploy -Namespace $Namespace
    
    Write-Host "`n3. Deploying PostgreSQL NFS Storage..." -ForegroundColor Yellow
    & ./deploy-postgres-nfs.ps1 -Action deploy -Namespace $Namespace
    
    Write-Host "`n=== All Apps Deployed ===" -ForegroundColor Green
}

function Test-AllApps {
    Write-Host "`n=== Testing All Demo Apps ===" -ForegroundColor Green
    
    Write-Host "`n1. Testing Nginx LoadBalancer..." -ForegroundColor Yellow
    & ./deploy-nginx-lb.ps1 -Action test -Namespace $Namespace
    
    Write-Host "`n2. Testing Redis Local Storage..." -ForegroundColor Yellow
    & ./deploy-redis-local.ps1 -Action test -Namespace $Namespace
    
    Write-Host "`n3. Testing PostgreSQL NFS Storage..." -ForegroundColor Yellow
    & ./deploy-postgres-nfs.ps1 -Action test -Namespace $Namespace
    
    # Summary report
    Write-Host "`n=== Cluster Summary ===" -ForegroundColor Green
    Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
    
    Write-Host "`nPods:" -ForegroundColor Yellow
    kubectl get pods -n $Namespace
    
    Write-Host "`nServices:" -ForegroundColor Yellow
    kubectl get svc -n $Namespace
    
    Write-Host "`nPersistent Volume Claims:" -ForegroundColor Yellow
    kubectl get pvc -n $Namespace
    
    Write-Host "`nStorage Classes:" -ForegroundColor Yellow
    kubectl get storageclass
    
    Write-Host "`n=== All Tests Complete ===" -ForegroundColor Green
}

function Cleanup-AllApps {
    Write-Host "`n=== Cleaning Up All Demo Apps ===" -ForegroundColor Green
    
    Write-Host "`nCleaning up apps..." -ForegroundColor Yellow
    & ./deploy-nginx-lb.ps1 -Action cleanup -Namespace $Namespace
    & ./deploy-redis-local.ps1 -Action cleanup -Namespace $Namespace  
    & ./deploy-postgres-nfs.ps1 -Action cleanup -Namespace $Namespace
    
    # Optional: Remove namespace (with confirmation)
    Write-Host "`nRemove namespace $Namespace? (y/N): " -ForegroundColor Yellow -NoNewline
    $response = Read-Host
    if ($response -eq 'y' -or $response -eq 'Y') {
        kubectl delete namespace $Namespace --ignore-not-found=true
        Write-Host "✓ Namespace $Namespace removed" -ForegroundColor Green
    }
    
    Write-Host "`n=== Cleanup Complete ===" -ForegroundColor Green
}

# Main execution
switch ($Action) {
    "deploy" {
        if (Test-Prerequisites) {
            Deploy-AllApps
        }
    }
    
    "test" {
        if (Test-Prerequisites) {
            Test-AllApps
        }
    }
    
    "cleanup" {
        Cleanup-AllApps
    }
    
    "full" {
        if (Test-Prerequisites) {
            Deploy-AllApps
            Start-Sleep -Seconds 30  # Give apps time to fully start
            Test-AllApps
        }
    }
}

Write-Host ""