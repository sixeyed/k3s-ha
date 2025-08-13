# K3s HA Cluster Management Module
# Provides centralized configuration loading and shared functions for all scripts

function Load-ClusterConfig {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ConfigPath
    )
    
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Error: Configuration file '$ConfigPath' not found!" -ForegroundColor Red
        Write-Host "Please create a cluster.json file or specify the correct path." -ForegroundColor Red
        exit 1
    }
    
    try {
        $jsonContent = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        
        # Expand SSH key path
        $sshKeyPath = $jsonContent.ssh.keyPath
        if ($sshKeyPath.StartsWith("~")) {
            $sshKeyPath = $sshKeyPath.Replace("~", $HOME)
        }
        
        # Generate token if not provided
        $k3sToken = $jsonContent.k3s.token
        if ([string]::IsNullOrEmpty($k3sToken)) {
            $k3sToken = "k3s-ha-token-$(Get-Random -Maximum 999999)"
        }
        
        # Build TLS SANs if not provided
        $tlsSans = $jsonContent.k3s.tlsSans
        if ($tlsSans.Count -eq 0) {
            $tlsSans = @($jsonContent.network.proxyIP) + $jsonContent.network.masterIPs
        }
        
        return @{
            # Network configuration
            ProxyIP = $jsonContent.network.proxyIP
            MasterIPs = $jsonContent.network.masterIPs
            WorkerIPs = $jsonContent.network.workerIPs
            
            # Cluster configuration
            ClusterName = $jsonContent.cluster.name
            K3sVersion = $jsonContent.cluster.version
            K3sToken = $k3sToken
            TLSSans = $tlsSans
            DisableServices = $jsonContent.k3s.disableServices
            
            # Storage configuration
            StorageDevice = $jsonContent.storage.device
            NFSMountPath = $jsonContent.storage.nfsMountPath
            
            # SSH configuration
            SSHUser = $jsonContent.ssh.user
            SSHKeyPath = $sshKeyPath
            
            # Operations configuration
            DrainTimeout = $jsonContent.operations.drainTimeout
            UpgradeStrategy = $jsonContent.operations.upgradeStrategy
            BackupRetention = $jsonContent.operations.backupRetention
        }
    }
    catch {
        Write-Host "Error parsing configuration file: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

function Get-SSHCommand {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Node,
        [Parameter(Mandatory=$true)]
        [string]$Command
    )
    
    ssh -i $Config.SSHKeyPath -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node" $Command
}

function Copy-FileToNode {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Node,
        [Parameter(Mandatory=$true)]
        [string]$LocalPath,
        [Parameter(Mandatory=$true)]
        [string]$RemotePath
    )
    
    scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no $LocalPath "$($Config.SSHUser)@$Node`:$RemotePath"
}

function Copy-FileFromNode {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Node,
        [Parameter(Mandatory=$true)]
        [string]$RemotePath,
        [Parameter(Mandatory=$true)]
        [string]$LocalPath
    )
    
    scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node`:$RemotePath" $LocalPath
}

# Helper function for backwards compatibility - wraps Get-SSHCommand
function Invoke-SSHCommand {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Node,
        [Parameter(Mandatory=$true)]
        [string]$Command
    )
    
    Get-SSHCommand -Config $Config -Node $Node -Command $Command
}

# Export functions
Export-ModuleMember -Function Load-ClusterConfig, Get-SSHCommand, Copy-FileToNode, Copy-FileFromNode, Invoke-SSHCommand