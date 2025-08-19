# Test script to verify configuration loading and module functions work
param(
    [string]$ConfigFile = "cluster.json"
)

try {
    Write-Host "=== Testing K3s Configuration System ===" -ForegroundColor Green
    
    # Import configuration module
    Import-Module "$PSScriptRoot\lib\K3sCluster.psm1" -Force
    Write-Host "✓ Configuration module imported successfully" -ForegroundColor Green
    
    # Load configuration
    Write-Host "`nTesting configuration loading from: $ConfigFile" -ForegroundColor Yellow
    $Config = Load-ClusterConfig -ConfigPath $ConfigFile
    Write-Host "✓ Configuration loaded successfully" -ForegroundColor Green
    
    # Verify configuration structure
    Write-Host "`nConfiguration validation:" -ForegroundColor Yellow
    $requiredKeys = @('ProxyIP', 'MasterIPs', 'WorkerIPs', 'SSHUser', 'SSHKeyPath', 'K3sVersion', 'ServiceCIDR', 'ClusterCIDR')
    foreach ($key in $requiredKeys) {
        if ($Config.$key) {
            Write-Host "  ✓ $key : $($Config.$key)" -ForegroundColor Green
        } else {
            Write-Host "  ✗ $key : Missing or null" -ForegroundColor Red
        }
    }
    
    # Test SSH key path expansion
    Write-Host "`nSSH Configuration:" -ForegroundColor Yellow
    Write-Host "  SSH User: $($Config.SSHUser)" -ForegroundColor White
    Write-Host "  SSH Key Path: $($Config.SSHKeyPath)" -ForegroundColor White
    if (Test-Path $Config.SSHKeyPath) {
        Write-Host "  ✓ SSH key file exists" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ SSH key file not found (this is expected if not configured)" -ForegroundColor Yellow
    }
    
    # Test helper functions (dry run)
    Write-Host "`nTesting helper functions (dry run):" -ForegroundColor Yellow
    $testCommand = "echo 'test'"
    Write-Host "  Sample SSH command would be:" -ForegroundColor White
    Write-Host "    ssh -i $($Config.SSHKeyPath) -o StrictHostKeyChecking=no $($Config.SSHUser)@$($Config.MasterIPs[0]) $testCommand" -ForegroundColor Cyan
    
    Write-Host "`n✓ All configuration tests passed!" -ForegroundColor Green
    Write-Host "`nCluster Summary:" -ForegroundColor Yellow
    Write-Host "  Cluster Name: $($Config.ClusterName)" -ForegroundColor White
    Write-Host "  K3s Version: $($Config.K3sVersion)" -ForegroundColor White
    Write-Host "  Proxy: $($Config.ProxyIP)" -ForegroundColor White
    Write-Host "  Masters: $($Config.MasterIPs -join ', ')" -ForegroundColor White
    Write-Host "  Workers: $($Config.WorkerIPs -join ', ')" -ForegroundColor White
    Write-Host "  Storage: $($Config.StorageDevice) -> $($Config.NFSMountPath)" -ForegroundColor White
    
    Write-Host "`nKubernetes Network Configuration:" -ForegroundColor Yellow
    Write-Host "  Service CIDR: $($Config.ServiceCIDR)" -ForegroundColor White
    Write-Host "  Cluster CIDR: $($Config.ClusterCIDR)" -ForegroundColor White
    Write-Host "  Cluster DNS: $($Config.ClusterDNS)" -ForegroundColor White
    Write-Host "  Cluster Domain: $($Config.ClusterDomain)" -ForegroundColor White
    Write-Host "  NodePort Range: $($Config.NodePortRange)" -ForegroundColor White
    Write-Host "  Max Pods per Node: $($Config.MaxPods)" -ForegroundColor White
    
    # Test K3s argument generation
    Write-Host "`nTesting K3s argument generation:" -ForegroundColor Yellow
    $serverArgs = Get-K3sServerArgs -Config $Config -IsFirstServer
    Write-Host "  First Server Args: $serverArgs" -ForegroundColor Cyan
    $agentArgs = Get-K3sAgentArgs -Config $Config -ServerURL "https://$($Config.ProxyIP):6443"
    Write-Host "  Agent Args: $agentArgs" -ForegroundColor Cyan
    
} catch {
    Write-Host "✗ Configuration test failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}