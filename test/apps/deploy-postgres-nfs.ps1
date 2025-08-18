# Deploy PostgreSQL NFS Storage Demo App
# This script deploys PostgreSQL with NFS persistent storage to test NFS storage class

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "test", "cleanup")]
    [string]$Action = "deploy",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "demo-apps"
)

Write-Host "`n=== PostgreSQL NFS Storage Demo ===" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan

switch ($Action) {
    "deploy" {
        Write-Host "`nDeploying PostgreSQL with NFS storage..." -ForegroundColor Yellow
        
        # Create namespace if it doesn't exist
        kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
        
        # Deploy with Helm
        helm upgrade --install postgres-demo ./postgres-nfs --namespace $Namespace --create-namespace
        
        Write-Host "`nWaiting for deployment to be ready..." -ForegroundColor Yellow
        kubectl wait --for=condition=available --timeout=180s deployment/postgres-demo-postgres-nfs -n $Namespace
        
        # Check PVC status
        Write-Host "`n=== Storage Information ===" -ForegroundColor Green
        kubectl get pvc postgres-demo-postgres-nfs-data -n $Namespace
        kubectl get pv | grep $Namespace | grep postgres-demo
        
        Write-Host "`nDeployment complete! Run with -Action test to verify." -ForegroundColor Green
    }
    
    "test" {
        Write-Host "`nTesting PostgreSQL with NFS storage..." -ForegroundColor Yellow
        
        # Check pod status
        $pod = kubectl get pods -n $Namespace -l app.kubernetes.io/name=postgres-nfs -o jsonpath='{.items[0].metadata.name}' 2>$null
        if ($pod) {
            Write-Host "✓ Pod running: $pod" -ForegroundColor Green
        } else {
            Write-Host "✗ Pod not found!" -ForegroundColor Red
            return
        }
        
        # Check PVC status
        $pvcStatus = kubectl get pvc postgres-demo-postgres-nfs-data -n $Namespace -o jsonpath='{.status.phase}' 2>$null
        if ($pvcStatus -eq "Bound") {
            Write-Host "✓ PVC bound successfully" -ForegroundColor Green
        } else {
            Write-Host "✗ PVC not bound (Status: $pvcStatus)" -ForegroundColor Red
        }
        
        # Test PostgreSQL functionality
        Write-Host "`nTesting PostgreSQL operations..." -ForegroundColor Yellow
        
        # Test database connection
        $pgReady = kubectl exec -n $Namespace $pod -- pg_isready -U postgres 2>$null
        if ($pgReady -match "accepting connections") {
            Write-Host "✓ PostgreSQL is accepting connections" -ForegroundColor Green
        } else {
            Write-Host "✗ PostgreSQL connection test failed" -ForegroundColor Red
        }
        
        # Query demo data
        $demoData = kubectl exec -n $Namespace $pod -- psql -U postgres -d demoapp -t -c "SELECT COUNT(*) FROM demo_data;" 2>$null
        if ($demoData -and $demoData.Trim() -gt 0) {
            Write-Host "✓ Demo data found: $($demoData.Trim()) records" -ForegroundColor Green
        } else {
            Write-Host "✗ Demo data query failed" -ForegroundColor Red
        }
        
        # Insert test data with current timestamp
        $insertResult = kubectl exec -n $Namespace $pod -- psql -U postgres -d demoapp -c "INSERT INTO storage_test (test_name, test_result) VALUES ('NFS Test', 'Test run at $(Get-Date)');" 2>$null
        if ($insertResult -match "INSERT 0 1") {
            Write-Host "✓ Test data insertion successful" -ForegroundColor Green
        }
        
        # Query storage test data
        $storageTests = kubectl exec -n $Namespace $pod -- psql -U postgres -d demoapp -t -c "SELECT test_name, test_result FROM storage_test ORDER BY created_at DESC LIMIT 3;" 2>$null
        if ($storageTests) {
            Write-Host "✓ Recent storage tests:" -ForegroundColor Green
            $storageTests.Split("`n") | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
                Write-Host "   $($_.Trim())" -ForegroundColor Cyan
            }
        }
        
        # Check database size and storage usage
        $dbSize = kubectl exec -n $Namespace $pod -- psql -U postgres -d demoapp -t -c "SELECT pg_size_pretty(pg_database_size('demoapp'));" 2>$null
        if ($dbSize) {
            Write-Host "✓ Database size: $($dbSize.Trim())" -ForegroundColor Green
        }
        
        # Display volume mount information
        Write-Host "`n=== NFS Mount Information ===" -ForegroundColor Green
        kubectl exec -n $Namespace $pod -- df -h /var/lib/postgresql/data 2>$null
        
        # Check if data is actually on NFS
        $mountInfo = kubectl exec -n $Namespace $pod -- mount | grep "/var/lib/postgresql/data" 2>$null
        if ($mountInfo -match "nfs") {
            Write-Host "✓ Confirmed: Data is stored on NFS mount" -ForegroundColor Green
            Write-Host "   $mountInfo" -ForegroundColor Cyan
        } else {
            Write-Host "Mount info: $mountInfo" -ForegroundColor Yellow
        }
        
        # Display pod and PVC status
        Write-Host "`n=== Pod Status ===" -ForegroundColor Green
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=postgres-nfs
        
        Write-Host "`n=== PVC Status ===" -ForegroundColor Green
        kubectl get pvc -n $Namespace
        
        Write-Host "`n=== NFS Storage Test Complete ===" -ForegroundColor Green
    }
    
    "cleanup" {
        Write-Host "`nCleaning up PostgreSQL NFS storage app..." -ForegroundColor Yellow
        helm uninstall postgres-demo -n $Namespace
        # Note: PVC is not automatically deleted to preserve data
        Write-Host "Note: PVC is preserved. Delete manually if needed: kubectl delete pvc postgres-demo-postgres-nfs-data -n $Namespace" -ForegroundColor Yellow
        Write-Host "✓ Cleanup complete!" -ForegroundColor Green
    }
}

Write-Host ""