# K3s Health Check and Troubleshooting Script
# Comprehensive cluster health monitoring and diagnostics

param(
    [ValidateSet("health", "diagnose", "logs", "performance", "fix-common")]
    [string]$Mode = "health",
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "../cluster.json",
    
    [int]$LogLines = 50,
    [switch]$Verbose
)

Write-Host "=== K3s Health Check and Troubleshooting ===" -ForegroundColor Green
Write-Host "Mode: $Mode" -ForegroundColor Yellow

#########################################
# CONFIGURATION LOADING
#########################################

# Import configuration module
Import-Module "$PSScriptRoot\..\lib\K3sCluster.psm1" -Force

# Load configuration
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$Config = Load-ClusterConfig -ConfigPath $ConfigFile

# Helper functions

function Test-NodeSSH {
    param([string]$Node)
    
    $result = Invoke-SSHCommand -Config $Config -Node $Node -Command "echo 'SSH_OK'" 2>$null
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