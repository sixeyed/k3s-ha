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
        } elseif (-not [System.IO.Path]::IsPathRooted($sshKeyPath)) {
            # Convert relative path to absolute path based on current working directory
            # since the config path might be relative too
            $sshKeyPath = Resolve-Path $sshKeyPath -ErrorAction SilentlyContinue
            if (-not $sshKeyPath) {
                # If not found in current directory, try relative to config file
                $configDir = Split-Path -Parent (Resolve-Path $ConfigPath)
                $sshKeyPath = Join-Path $configDir $jsonContent.ssh.keyPath
            }
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

# Helper function to get the correct SSH key for a node
function Get-SSHKeyForNode {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Node
    )
    
    # Get base key info
    $baseKeyPath = $Config.SSHKeyPath
    $keyDir = Split-Path -Parent $baseKeyPath
    $fullKeyName = Split-Path -Leaf $baseKeyPath
    
    # Extract the base key name by removing any existing role suffix
    # For example: vagrant_rsa_k3s-master-1 -> vagrant_rsa
    $baseKeyName = $fullKeyName
    if ($fullKeyName -match "^(.+)_k3s-(master|worker|proxy)(-\d+)?$") {
        $baseKeyName = $matches[1]
    }
    
    # Determine node role and create priority list of keys to try
    $keysToTry = @($baseKeyPath)  # Start with configured key
    
    # Add role-based keys
    if ($Node -eq $Config.ProxyIP) {
        $keysToTry += Join-Path $keyDir "${baseKeyName}_k3s-proxy"
    } elseif ($Config.MasterIPs -contains $Node) {
        $masterIndex = $Config.MasterIPs.IndexOf($Node) + 1
        $keysToTry += Join-Path $keyDir "${baseKeyName}_k3s-master-$masterIndex"
    } elseif ($Config.WorkerIPs -contains $Node) {
        $workerIndex = $Config.WorkerIPs.IndexOf($Node) + 1
        $keysToTry += Join-Path $keyDir "${baseKeyName}_k3s-worker-$workerIndex"
    }
    
    # Add IP-based key
    $keysToTry += Join-Path $keyDir "${baseKeyName}_${Node}"
    
    # Try each key until one works
    foreach ($keyPath in $keysToTry) {
        if (Test-Path $keyPath) {
            # Test if key works with a simple command
            $null = ssh -i $keyPath -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "$($Config.SSHUser)@$Node" "exit" 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $keyPath
            }
        }
    }
    
    # If nothing worked, return the original key
    return $baseKeyPath
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
    
    $sshKey = Get-SSHKeyForNode -Config $Config -Node $Node
    ssh -i $sshKey -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node" $Command
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
    
    $sshKey = Get-SSHKeyForNode -Config $Config -Node $Node
    scp -i $sshKey -o StrictHostKeyChecking=no $LocalPath "$($Config.SSHUser)@$Node`:$RemotePath"
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
    
    $sshKey = Get-SSHKeyForNode -Config $Config -Node $Node
    scp -i $sshKey -o StrictHostKeyChecking=no "$($Config.SSHUser)@$Node`:$RemotePath" $LocalPath
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
    
    # TLS SANs - automatically include proxy IP and master IPs
    $tlsSans = @()
    
    # Add proxy IP if it exists
    if ($Config.ProxyIP) {
        $tlsSans += $Config.ProxyIP
    }
    
    # Add master IPs
    if ($Config.MasterIPs) {
        $tlsSans += $Config.MasterIPs
    }
    
    # Add custom TLS SANs from config
    if ($Config.TLSSans) {
        $tlsSans += $Config.TLSSans
    }
    
    # Remove duplicates and add to args
    $tlsSans = $tlsSans | Sort-Object -Unique
    foreach ($san in $tlsSans) {
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
Export-ModuleMember -Function Load-ClusterConfig, Get-SSHCommand, Copy-FileToNode, Copy-FileFromNode, Invoke-SSHCommand, Get-K3sServerArgs, Get-K3sAgentArgs, Get-SSHKeyForNode