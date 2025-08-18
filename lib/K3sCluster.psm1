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
            
            # Kubernetes configuration
            ServiceCIDR = $jsonContent.kubernetes.serviceCIDR
            ClusterCIDR = $jsonContent.kubernetes.clusterCIDR
            ClusterDNS = $jsonContent.kubernetes.clusterDNS
            ClusterDomain = $jsonContent.kubernetes.clusterDomain
            NodePortRange = $jsonContent.kubernetes.nodePortRange
            MaxPods = $jsonContent.kubernetes.maxPods
            
            # K3s extra arguments
            ExtraServerArgs = $jsonContent.k3s.extraArgs.server
            ExtraAgentArgs = $jsonContent.k3s.extraArgs.agent
            
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
    
    # Check if we're in a Vagrant environment
    if (Test-Path "Vagrantfile") {
        # Use Vagrant to copy files - we need to determine the VM name based on IP
        $vmName = Get-VagrantVMName -IPAddress $Node
        if ($vmName) {
            # Copy to vagrant shared folder first, then move to target location inside VM
            $fileName = Split-Path -Leaf $LocalPath
            $localSharedPath = "./temp_$fileName"  # Local path to copy to current directory with unique name
            $sharedPath = "/vagrant/temp_$fileName"  # Path inside VM
            
            # Copy file to current directory with temp name (will be available in VM at /vagrant)
            Copy-Item $LocalPath $localSharedPath -Force
            
            # Move file inside VM to target location
            vagrant ssh $vmName -c "sudo cp '$sharedPath' '$RemotePath' && sudo chmod +x '$RemotePath'"
            
            # Clean up temp file
            Remove-Item $localSharedPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "Warning: Could not determine Vagrant VM name for IP $Node, using direct SSH" -ForegroundColor Yellow
            scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no $LocalPath "$($Config.SSHUser)@$Node`:$RemotePath"
        }
    } else {
        scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no $LocalPath "$($Config.SSHUser)@$Node`:$RemotePath"
    }
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
    
    # Check if we're in a Vagrant environment
    if (Test-Path "Vagrantfile") {
        # Use Vagrant to copy files - we need to determine the VM name based on IP
        $vmName = Get-VagrantVMName -IPAddress $Node
        if ($vmName) {
            # Copy to vagrant shared folder first, then get it locally
            $fileName = Split-Path -Leaf $RemotePath
            $sharedPath = "/vagrant/temp_$fileName"
            $localSharedPath = "./temp_$fileName"
            
            # Copy from remote path to shared folder inside VM
            vagrant ssh $vmName -c "sudo cp '$RemotePath' '$sharedPath'"
            
            # Copy from shared folder to local path
            Copy-Item $localSharedPath $LocalPath -Force
            
            # Clean up temp file
            Remove-Item $localSharedPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "Warning: Could not determine Vagrant VM name for IP $Node, using direct SSH" -ForegroundColor Yellow
            scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node`:$RemotePath" $LocalPath
        }
    } else {
        scp -i $Config.SSHKeyPath -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node`:$RemotePath" $LocalPath
    }
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
    
    # Check if we're in a Vagrant environment
    if (Test-Path "Vagrantfile") {
        # Use Vagrant SSH command
        $vmName = Get-VagrantVMName -IPAddress $Node
        if ($vmName) {
            # Properly quote the command for vagrant ssh
            vagrant ssh $vmName -c "$Command"
        } else {
            Write-Host "Warning: Could not determine Vagrant VM name for IP $Node, using direct SSH" -ForegroundColor Yellow
            Get-SSHCommand -Config $Config -Node $Node -Command $Command
        }
    } else {
        Get-SSHCommand -Config $Config -Node $Node -Command $Command
    }
}

# Function to get Vagrant VM name based on IP address
function Get-VagrantVMName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IPAddress
    )
    
    # Map IP addresses to VM names based on our Vagrantfile configuration
    switch ($IPAddress) {
        "192.168.56.100" { return "k3s-proxy" }
        "192.168.56.10" { return "k3s-master-1" }
        "192.168.56.20" { return "k3s-worker-1" }
        default { return $null }
    }
}

# Function to build K3s server arguments based on configuration
function Get-K3sServerArgs {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$false)]
        [switch]$IsFirstServer
    )
    
    $args = @()
    
    # Kubernetes networking arguments
    if ($Config.ServiceCIDR) {
        $args += "--service-cidr=$($Config.ServiceCIDR)"
    }
    if ($Config.ClusterCIDR) {
        $args += "--cluster-cidr=$($Config.ClusterCIDR)"
    }
    if ($Config.ClusterDNS) {
        $args += "--cluster-dns=$($Config.ClusterDNS)"
    }
    if ($Config.ClusterDomain) {
        $args += "--cluster-domain=$($Config.ClusterDomain)"
    }
    if ($Config.NodePortRange) {
        $args += "--service-node-port-range=$($Config.NodePortRange)"
    }
    if ($Config.MaxPods) {
        $args += "--kubelet-arg=max-pods=$($Config.MaxPods)"
    }
    
    # TLS SANs
    foreach ($san in $Config.TLSSans) {
        $args += "--tls-san=$san"
    }
    
    # Disable services
    foreach ($service in $Config.DisableServices) {
        $args += "--disable=$service"
    }
    
    # Extra server arguments
    if ($Config.ExtraServerArgs) {
        $args += $Config.ExtraServerArgs
    }
    
    # Standard arguments
    $args += "--token=$($Config.K3sToken)"
    $args += "--write-kubeconfig-mode=644"
    
    # First server gets cluster-init, others join
    if ($IsFirstServer) {
        $args += "--cluster-init"
    }
    
    return $args -join " "
}

# Function to build K3s agent arguments based on configuration  
function Get-K3sAgentArgs {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$ServerURL
    )
    
    $args = @()
    
    # Basic agent arguments
    $args += "--server=$ServerURL"
    $args += "--token=$($Config.K3sToken)"
    
    # Kubelet arguments
    if ($Config.MaxPods) {
        $args += "--kubelet-arg=max-pods=$($Config.MaxPods)"
    }
    
    # Extra agent arguments
    if ($Config.ExtraAgentArgs) {
        $args += $Config.ExtraAgentArgs
    }
    
    return $args -join " "
}

# Export functions
Export-ModuleMember -Function Load-ClusterConfig, Get-SSHCommand, Copy-FileToNode, Copy-FileFromNode, Invoke-SSHCommand, Get-K3sServerArgs, Get-K3sAgentArgs