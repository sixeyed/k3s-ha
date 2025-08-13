# K3s Health Check and Troubleshooting Script
# Comprehensive cluster health monitoring and diagnostics

param(
    [ValidateSet("health", "diagnose", "logs", "performance", "fix-common")]
    [string]$Mode = "health",
    
    [string]$ProxyIP = "10.0.1.100",
    [string[]]$MasterIPs = @("10.0.1.10", "10.0.1.11", "10.0.1.12"),
    [string[]]$WorkerIPs = @("10.0.1.20", "10.0.1.21", "10.0.1.22", "10.0.1.23", "10.0.1.24", "10.0.1.25"),
    [string]$SSHUser = "ubuntu",
    [string]$SSHKeyPath = "$HOME\.ssh\id_rsa",
    [int]$LogLines = 50,
    [switch]$Verbose
)

Write-Host "=== K3s Health Check and Troubleshooting ===" -ForegroundColor Green
Write-Host "Mode: $Mode" -ForegroundColor Yellow

# Helper functions
function Invoke-SSHCommand {
    param(
        [string]$Node,
        [string]$Command
    )
    ssh -i $SSHKeyPath -o StrictHostKeyChecking=no $SSHUser@$Node $Command
}

function Test-NodeSSH {
    param([string]$Node)
    
    $result = Invoke-SSHCommand -Node $Node -Command "echo 'SSH_OK'" 2>$null
    return $result -eq "SSH_OK"
}

function Get-NodeHealth {
    param([string]$Node)
    
    $health = @{
        Node = $Node
        SSHAccess = $false
        K3sRunning = $false
        K3sVersion = "Unknown"
        SystemLoad = "Unknown"
        MemoryUsage = "Unknown"
        DiskUsage = "Unknown"
        Issues = @()
    }
    
    # Check SSH access
    if (Test-NodeSSH -Node $Node) {
        $health.SSHAccess = $