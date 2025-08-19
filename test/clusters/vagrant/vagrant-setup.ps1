# K3s Vagrant Cluster Management
# Supports different cluster configurations: minimal, ha

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("prereqs", "up", "deploy", "destroy", "status")]
    [string]$Action = "up",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("minimal", "ha")]
    [string]$ClusterType = "minimal",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

Write-Host "=== K3s Vagrant Cluster Management ===" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Cluster Type: $ClusterType" -ForegroundColor Cyan

$ClusterPath = "$PSScriptRoot/$ClusterType"

# Check if cluster configuration exists
if (-not (Test-Path $ClusterPath)) {
    Write-Host "Error: Cluster configuration '$ClusterType' not found at $ClusterPath" -ForegroundColor Red
    Write-Host "Available configurations:" -ForegroundColor Yellow
    Get-ChildItem "$PSScriptRoot" -Directory | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Yellow }
    exit 1
}

function Test-Prerequisites {
    Write-Host "`n=== Checking Prerequisites ===" -ForegroundColor Green
    $allGood = $true
    
    # Check Vagrant
    try {
        $vagrantVersion = vagrant --version 2>$null
        Write-Host "  ✓ Vagrant: $vagrantVersion" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Vagrant not found! Install from https://www.vagrantup.com/" -ForegroundColor Red
        $allGood = $false
    }
    
    # Check VirtualBox
    try {
        $vboxVersion = VBoxManage --version 2>$null
        Write-Host "  ✓ VirtualBox: $vboxVersion" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ VirtualBox not found! Install from https://www.virtualbox.org/" -ForegroundColor Red
        $allGood = $false
    }
    
    # Check PowerShell
    $psVersion = $PSVersionTable.PSVersion
    Write-Host "  ✓ PowerShell: $psVersion" -ForegroundColor Green
    
    # Check SSH Key
    $sshKeyPath = "$HOME/.ssh/id_rsa"
    if (Test-Path $sshKeyPath) {
        Write-Host "  ✓ SSH Key: $sshKeyPath exists" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ SSH Key: $sshKeyPath not found, will use Vagrant keys" -ForegroundColor Yellow
    }
    
    # Check architecture
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or (uname -m 2>$null) -eq "arm64") { "ARM64" } else { "AMD64" }
    Write-Host "  ✓ Architecture: $arch" -ForegroundColor Green
    if ($arch -eq "ARM64") {
        Write-Host "    Using VirtualBox with ARM64 support and Bento boxes" -ForegroundColor Cyan
    }
    
    # Check system resources
    try {
        if ($IsWindows) {
            $ram = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        } else {
            $ram = [math]::Round((sysctl -n hw.memsize 2>$null) / 1GB, 1)
        }
        Write-Host "  ✓ RAM: ${ram}GB available" -ForegroundColor Green
        
        if ($ClusterType -eq "ha" -and $ram -lt 16) {
            Write-Host "    ⚠ Warning: HA cluster recommended minimum is 16GB RAM" -ForegroundColor Yellow
        } elseif ($ClusterType -eq "minimal" -and $ram -lt 8) {
            Write-Host "    ⚠ Warning: Minimal cluster recommended minimum is 8GB RAM" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ? RAM: Unable to determine available memory" -ForegroundColor Yellow
    }
    
    # Check disk space
    try {
        if ($IsWindows) {
            $disk = [math]::Round((Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 1)
        } else {
            $disk = [math]::Round((df -g . | tail -1 | awk '{print $4}'), 1)
        }
        Write-Host "  ✓ Disk: ${disk}GB free space" -ForegroundColor Green
    } catch {
        Write-Host "  ? Disk: Unable to determine free space" -ForegroundColor Yellow
    }
    
    if ($allGood) {
        Write-Host "`n✓ All prerequisites met!" -ForegroundColor Green
    } else {
        Write-Host "`n✗ Please install missing prerequisites before continuing." -ForegroundColor Red
        return $false
    }
    
    return $true
}

function Start-VagrantCluster {
    Write-Host "`nStarting Vagrant cluster ($ClusterType)..." -ForegroundColor Yellow
    
    # Change to cluster directory
    Push-Location $ClusterPath
    
    try {
        # Check if VMs already exist
        $existingVMs = vagrant status --porcelain 2>$null | Where-Object { $_ -match ",running," }
        if ($existingVMs -and -not $Force) {
            Write-Host "⚠ Some VMs are already running:" -ForegroundColor Yellow
            vagrant status
            Write-Host "Use -Force to destroy and recreate, or 'destroy' action first." -ForegroundColor Yellow
            return
        }
        
        if ($Force -and $existingVMs) {
            Write-Host "Destroying existing VMs..." -ForegroundColor Yellow
            vagrant destroy -f
        }
        
        # Start VMs sequentially to avoid parallel startup issues  
        vagrant up --provider=virtualbox
        
        Write-Host "`n✓ Vagrant cluster started!" -ForegroundColor Green
        Show-ClusterInfo
        
    } catch {
        Write-Host "✗ Error starting cluster: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pop-Location
    }
}

function Deploy-K3sCluster {
    Write-Host "`nDeploying K3s to Vagrant cluster ($ClusterType)..." -ForegroundColor Yellow
    
    Push-Location $ClusterPath
    
    try {
        # Check if cluster JSON exists
        $clusterConfig = Get-ChildItem -Name "*-cluster.json" | Select-Object -First 1
        if (-not $clusterConfig) {
            Write-Host "✗ No cluster configuration (*-cluster.json) found in $ClusterPath" -ForegroundColor Red
            return
        }
        
        Write-Host "Using configuration: $clusterConfig" -ForegroundColor Cyan
        
        # Deploy K3s (path is relative to repo root)
        $deployScript = Join-Path (Get-Location) "../../../../setup/k3s-setup.ps1"
        $deployScript = [System.IO.Path]::GetFullPath($deployScript)
        Write-Host "Deploying with script: $deployScript" -ForegroundColor Cyan
        if (Test-Path $deployScript) {
            & pwsh -File $deployScript -ConfigFile $clusterConfig
        } else {
            Write-Host "✗ K3s deployment script not found: $deployScript" -ForegroundColor Red
            return
        }
        
        Write-Host "`n✓ K3s cluster deployed!" -ForegroundColor Green
        
    } catch {
        Write-Host "✗ Error deploying K3s: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pop-Location
    }
}

function Stop-VagrantCluster {
    Write-Host "`nDestroying Vagrant cluster ($ClusterType)..." -ForegroundColor Yellow
    
    if (-not $Force) {
        Write-Host "⚠️ This will destroy all VMs and data!" -ForegroundColor Red
        $response = Read-Host "Are you sure? (y/N)"
        if ($response -ne 'y' -and $response -ne 'Y') {
            Write-Host "Operation cancelled" -ForegroundColor Yellow
            return
        }
    }
    
    Push-Location $ClusterPath
    
    try {
        vagrant destroy -f
        Write-Host "✓ All VMs destroyed" -ForegroundColor Green
    } catch {
        Write-Host "✗ Error destroying cluster: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pop-Location
    }
}

function Show-ClusterStatus {
    Write-Host "`nCluster Status ($ClusterType):" -ForegroundColor Green
    
    Push-Location $ClusterPath
    
    try {
        vagrant status
        
        # If VMs are running, show additional info
        $runningVMs = vagrant status --porcelain 2>$null | Where-Object { $_ -match ",running," }
        if ($runningVMs) {
            Write-Host "`n=== Network Information ===" -ForegroundColor Green
            
            # Load cluster config to get IP addresses
            $clusterConfig = Get-ChildItem -Name "*-cluster.json" | Select-Object -First 1
            if ($clusterConfig) {
                $config = Get-Content $clusterConfig | ConvertFrom-Json
                Write-Host "Proxy:   $($config.network.proxyIP)" -ForegroundColor Cyan
                Write-Host "Masters: $($config.network.masterIPs -join ', ')" -ForegroundColor Cyan
                Write-Host "Workers: $($config.network.workerIPs -join ', ')" -ForegroundColor Cyan
            }
        }
        
    } catch {
        Write-Host "✗ Error getting status: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pop-Location
    }
}

function Show-ClusterInfo {
    Push-Location $ClusterPath
    
    try {
        $clusterConfig = Get-ChildItem -Name "*-cluster.json" | Select-Object -First 1
        if ($clusterConfig) {
            $config = Get-Content $clusterConfig | ConvertFrom-Json
            
            Write-Host "`n🎉 $($config.cluster.name) VMs are ready!" -ForegroundColor Green
            Write-Host "    " -ForegroundColor Green
            Write-Host "    Next steps:" -ForegroundColor Green
            Write-Host "    1. Deploy the cluster:" -ForegroundColor Green
            Write-Host "       $PSScriptRoot/vagrant-setup.ps1 -ClusterType $ClusterType -Action deploy" -ForegroundColor White
            Write-Host "    " -ForegroundColor Green
            Write-Host "    2. Or deploy manually:" -ForegroundColor Green
            Write-Host "       cd $ClusterPath" -ForegroundColor White
            Write-Host "       ../../../setup/k3s-setup.ps1 -ConfigFile $clusterConfig" -ForegroundColor White
            Write-Host "    " -ForegroundColor Green
            Write-Host "    VM Details:" -ForegroundColor Green
            Write-Host "    - Proxy:   $($config.network.proxyIP)" -ForegroundColor Green
            foreach ($ip in $config.network.masterIPs) {
                $index = $config.network.masterIPs.IndexOf($ip) + 1
                Write-Host "    - Master$index`: $ip" -ForegroundColor Green
            }
            foreach ($ip in $config.network.workerIPs) {
                $index = $config.network.workerIPs.IndexOf($ip) + 1
                Write-Host "    - Worker$index`: $ip" -ForegroundColor Green
            }
            Write-Host "    " -ForegroundColor Green
            Write-Host "    SSH: vagrant ssh [vm-name]" -ForegroundColor Green
            Write-Host "    " -ForegroundColor Green
        }
    } catch {
        Write-Host "Unable to load cluster configuration" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

# Main execution
switch ($Action) {
    "prereqs" {
        Test-Prerequisites
    }
    
    "up" {
        if (Test-Prerequisites) {
            Start-VagrantCluster
        }
    }
    
    "deploy" {
        Deploy-K3sCluster
    }
    
    "destroy" {
        Stop-VagrantCluster
    }
    
    "status" {
        Show-ClusterStatus
    }
}

Write-Host ""