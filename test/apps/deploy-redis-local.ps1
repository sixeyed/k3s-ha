# Deploy Redis Local Storage Demo App
# This script deploys Redis with local persistent storage to test local-path storage class

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "test", "cleanup")]
    [string]$Action = "deploy",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "demo-apps"
)

Write-Host "`n=== Redis Local Storage Demo ===" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan

switch ($Action) {
    "deploy" {
        Write-Host "`nDeploying Redis with local storage..." -ForegroundColor Yellow
        
        # Create namespace if it doesn't exist
        kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
        
        # Deploy with Helm
        helm upgrade --install redis-demo ./redis-local --namespace $Namespace --create-namespace
        
        Write-Host "`nWaiting for deployment to be ready..." -ForegroundColor Yellow
        kubectl wait --for=condition=available --timeout=120s deployment/redis-demo-redis-local -n $Namespace
        
        # Check PVC status
        Write-Host "`n=== Storage Information ===" -ForegroundColor Green
        kubectl get pvc redis-demo-redis-local-data -n $Namespace
        kubectl get pv | grep $Namespace | grep redis-demo
        
        Write-Host "`nDeployment complete! Run with -Action test to verify." -ForegroundColor Green
    }
    
    "test" {
        Write-Host "`nTesting Redis with local storage..." -ForegroundColor Yellow
        
        # Check pod status
        $pod = kubectl get pods -n $Namespace -l app.kubernetes.io/name=redis-local -o jsonpath='{.items[0].metadata.name}' 2>$null
        if ($pod) {
            Write-Host "✓ Pod running: $pod" -ForegroundColor Green
        } else {
            Write-Host "✗ Pod not found!" -ForegroundColor Red
            return
        }
        
        # Check PVC status
        $pvcStatus = kubectl get pvc redis-demo-redis-local-data -n $Namespace -o jsonpath='{.status.phase}' 2>$null
        if ($pvcStatus -eq "Bound") {
            Write-Host "✓ PVC bound successfully" -ForegroundColor Green
        } else {
            Write-Host "✗ PVC not bound (Status: $pvcStatus)" -ForegroundColor Red
        }
        
        # Test Redis functionality
        Write-Host "`nTesting Redis operations..." -ForegroundColor Yellow
        
        # Set a test key
        $setResult = kubectl exec -n $Namespace $pod -- redis-cli SET test-key "Local storage test - $(Get-Date)" 2>$null
        if ($setResult -eq "OK") {
            Write-Host "✓ Redis SET operation successful" -ForegroundColor Green
        } else {
            Write-Host "✗ Redis SET operation failed" -ForegroundColor Red
        }
        
        # Get the test key
        $getValue = kubectl exec -n $Namespace $pod -- redis-cli GET test-key 2>$null
        if ($getValue -and $getValue -ne "") {
            Write-Host "✓ Redis GET operation successful: $getValue" -ForegroundColor Green
        } else {
            Write-Host "✗ Redis GET operation failed" -ForegroundColor Red
        }
        
        # Check Redis info
        $redisInfo = kubectl exec -n $Namespace $pod -- redis-cli INFO persistence 2>$null
        if ($redisInfo -match "rdb_changes_since_last_save") {
            Write-Host "✓ Redis persistence information available" -ForegroundColor Green
        }
        
        # Display volume mount information
        Write-Host "`n=== Storage Mount Information ===" -ForegroundColor Green
        kubectl exec -n $Namespace $pod -- df -h /data 2>$null
        
        # Display pod and PVC status
        Write-Host "`n=== Pod Status ===" -ForegroundColor Green
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=redis-local
        
        Write-Host "`n=== PVC Status ===" -ForegroundColor Green
        kubectl get pvc -n $Namespace
        
        Write-Host "`n=== Local Storage Test Complete ===" -ForegroundColor Green
    }
    
    "cleanup" {
        Write-Host "`nCleaning up Redis local storage app..." -ForegroundColor Yellow
        helm uninstall redis-demo -n $Namespace
        # Note: PVC is not automatically deleted to preserve data
        Write-Host "Note: PVC is preserved. Delete manually if needed: kubectl delete pvc redis-demo-redis-local-data -n $Namespace" -ForegroundColor Yellow
        Write-Host "✓ Cleanup complete!" -ForegroundColor Green
    }
}

Write-Host ""