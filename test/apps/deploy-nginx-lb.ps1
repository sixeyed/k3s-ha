# Deploy Nginx LoadBalancer Demo App
# This script deploys an nginx app with LoadBalancer service to test external access

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "test", "cleanup")]
    [string]$Action = "deploy",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "demo-apps"
)

Write-Host "`n=== Nginx LoadBalancer Demo ===" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan

switch ($Action) {
    "deploy" {
        Write-Host "`nDeploying nginx LoadBalancer app..." -ForegroundColor Yellow
        
        # Create namespace if it doesn't exist
        kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
        
        # Deploy with Helm
        helm upgrade --install nginx-demo ./nginx-lb --namespace $Namespace --create-namespace
        
        Write-Host "`nWaiting for deployment to be ready..." -ForegroundColor Yellow
        kubectl wait --for=condition=available --timeout=120s deployment/nginx-demo-nginx-lb -n $Namespace
        
        # Get LoadBalancer IP (for K3s it will be a NodePort)
        Write-Host "`n=== Service Information ===" -ForegroundColor Green
        kubectl get svc nginx-demo-nginx-lb -n $Namespace
        
        # In K3s without MetalLB, LoadBalancer becomes NodePort
        $nodePort = kubectl get svc nginx-demo-nginx-lb -n $Namespace -o jsonpath='{.spec.ports[0].nodePort}'
        if ($nodePort) {
            Write-Host "`n✓ LoadBalancer service created (using NodePort: $nodePort)" -ForegroundColor Green
            Write-Host "Access the app at: http://192.168.56.10:$nodePort or http://192.168.56.20:$nodePort" -ForegroundColor Cyan
        }
        
        Write-Host "`nDeployment complete! Run with -Action test to verify." -ForegroundColor Green
    }
    
    "test" {
        Write-Host "`nTesting nginx LoadBalancer app..." -ForegroundColor Yellow
        
        # Check pod status
        $pods = kubectl get pods -n $Namespace -l app.kubernetes.io/name=nginx-lb -o jsonpath='{.items[*].metadata.name}'
        if ($pods) {
            Write-Host "✓ Pods running: $pods" -ForegroundColor Green
        } else {
            Write-Host "✗ No pods found!" -ForegroundColor Red
            return
        }
        
        # Check service
        $service = kubectl get svc nginx-demo-nginx-lb -n $Namespace -o jsonpath='{.metadata.name}' 2>$null
        if ($service) {
            Write-Host "✓ Service exists: $service" -ForegroundColor Green
        } else {
            Write-Host "✗ Service not found!" -ForegroundColor Red
            return
        }
        
        # Test HTTP connectivity
        $nodePort = kubectl get svc nginx-demo-nginx-lb -n $Namespace -o jsonpath='{.spec.ports[0].nodePort}'
        if ($nodePort) {
            Write-Host "`nTesting HTTP connectivity..." -ForegroundColor Yellow
            
            $testUrls = @("http://192.168.56.10:$nodePort", "http://192.168.56.20:$nodePort")
            $successCount = 0
            foreach ($url in $testUrls) {
                try {
                    $response = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200 -and $response.Content -match "LoadBalancer Working") {
                        Write-Host "✓ HTTP test passed: $url" -ForegroundColor Green
                        $successCount++
                    } else {
                        Write-Host "✗ HTTP test failed: $url (Status: $($response.StatusCode), Content check failed)" -ForegroundColor Red
                    }
                } catch {
                    # Try to extract more details about the error
                    $errorMessage = $_.Exception.Message
                    if ($_.Exception.Response) {
                        $statusCode = $_.Exception.Response.StatusCode
                        Write-Host "✗ HTTP test failed: $url (Status: $statusCode, Error: $errorMessage)" -ForegroundColor Red
                    } else {
                        Write-Host "✗ HTTP test failed: $url (Error: $errorMessage)" -ForegroundColor Red
                    }
                }
            }
            
            if ($successCount -gt 0) {
                Write-Host "✓ LoadBalancer is accessible ($successCount/$($testUrls.Count) endpoints working)" -ForegroundColor Green
            } else {
                Write-Host "✗ No endpoints are accessible" -ForegroundColor Red
            }
        }
        
        # Display pods and their status
        Write-Host "`n=== Pod Status ===" -ForegroundColor Green
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=nginx-lb
        
        Write-Host "`n=== LoadBalancer Test Complete ===" -ForegroundColor Green
    }
    
    "cleanup" {
        Write-Host "`nCleaning up nginx LoadBalancer app..." -ForegroundColor Yellow
        helm uninstall nginx-demo -n $Namespace
        Write-Host "✓ Cleanup complete!" -ForegroundColor Green
    }
}

Write-Host ""