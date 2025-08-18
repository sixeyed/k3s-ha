# Vagrant K3s Testing Environment Setup Script
# Provides easy commands to manage the test cluster

param(
    [ValidateSet("up", "status", "ssh", "destroy", "clean", "prereqs")]
    [string]$Action = "help",
    [string]$Node = ""
)

# Prerequisites check function
function Test-Prerequisites {
    Write-Host "=== Checking Prerequisites ===" -ForegroundColor Cyan
    $allGood = $true
    
    # Check Vagrant
    $vagrantInstalled = $false
    $vagrantVersionStr = ""
    try {
        $vagrantVersionStr = vagrant --version 2>$null
        if ($vagrantVersionStr) {
            Write-Host "  ✓ Vagrant: $vagrantVersionStr" -ForegroundColor Green
            $vagrantInstalled = $true
        } else {
            throw "Vagrant not found"
        }
    }
    catch {
        Write-Host "  ✗ Vagrant: Not installed" -ForegroundColor Red
        Write-Host "    Install: brew install --cask vagrant" -ForegroundColor Yellow
        $allGood = $false
    }
    
    # Check VirtualBox
    $vboxInstalled = $false
    $vboxVersionStr = ""
    try {
        $vboxVersionStr = VBoxManage --version 2>$null
        if ($vboxVersionStr) {
            Write-Host "  ✓ VirtualBox: $vboxVersionStr" -ForegroundColor Green
            $vboxInstalled = $true
        } else {
            throw "VirtualBox not found"
        }
    }
    catch {
        Write-Host "  ✗ VirtualBox: Not installed" -ForegroundColor Red
        Write-Host "    Install: brew install --cask virtualbox" -ForegroundColor Yellow
        $allGood = $false
    }
    
    # Check PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 5) {
        Write-Host "  ✓ PowerShell: $($psVersion.ToString())" -ForegroundColor Green
    } else {
        Write-Host "  ✗ PowerShell: $($psVersion.ToString()) (requires 5.1+)" -ForegroundColor Red
        $allGood = $false
    }
    
    # Check SSH key
    $sshKeyPath = "~/.ssh/id_rsa"
    if (Test-Path (Resolve-Path $sshKeyPath -ErrorAction SilentlyContinue)) {
        Write-Host "  ✓ SSH Key: $sshKeyPath exists" -ForegroundColor Green
    } else {
        Write-Host "  ✗ SSH Key: $sshKeyPath not found" -ForegroundColor Red
        Write-Host "    Generate: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa" -ForegroundColor Yellow
        $allGood = $false
    }
    
    # Check CPU architecture for VirtualBox compatibility
    try {
        $architecture = ""
        if ($IsMacOS) {
            $architecture = sysctl -n machdep.cpu.brand_string
            $isAppleSilicon = (sysctl -n machdep.cpu.brand_string) -like "*Apple*"
            if ($isAppleSilicon) {
                Write-Host "  ✓ Architecture: Apple Silicon (ARM64) - Using VirtualBox with ARM64 support" -ForegroundColor Green
                Write-Host "    VirtualBox 7.1+ provides native ARM64 support with Bento boxes" -ForegroundColor Green
            } else {
                Write-Host "  ✓ Architecture: Intel x86_64" -ForegroundColor Green
            }
        } elseif ($IsWindows) {
            $architecture = (Get-WmiObject Win32_Processor).Name
            Write-Host "  ✓ Architecture: $architecture" -ForegroundColor Green
        } else {
            $architecture = uname -m
            Write-Host "  ✓ Architecture: $architecture" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  ? Architecture: Could not determine CPU architecture" -ForegroundColor Yellow
    }
    
    # Check available memory (minimum 8GB recommended)
    try {
        if ($IsWindows) {
            $totalMemory = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property capacity -Sum).sum / 1GB, 1)
        } elseif ($IsMacOS) {
            # macOS
            $totalMemory = [math]::Round((sysctl -n hw.memsize) / 1GB, 1)
        } else {
            # Linux
            $totalMemory = [math]::Round((Get-Content /proc/meminfo | Where-Object {$_ -like "MemTotal:*"} | ForEach-Object {($_.Split()[1] -as [int]) / 1MB}), 1)
        }
        
        if ($totalMemory -ge 8) {
            Write-Host "  ✓ RAM: $($totalMemory)GB available" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ RAM: $($totalMemory)GB (8GB+ recommended)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  ? RAM: Could not determine available memory" -ForegroundColor Yellow
    }
    
    # Check disk space (minimum 20GB recommended)
    try {
        $freeSpace = [math]::Round((Get-PSDrive -Name (Get-Location).Drive.Name).Free / 1GB, 1)
        if ($freeSpace -ge 20) {
            Write-Host "  ✓ Disk: $($freeSpace)GB free space" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Disk: $($freeSpace)GB free (20GB+ recommended)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  ? Disk: Could not determine available disk space" -ForegroundColor Yellow
    }
    
    Write-Host ""
    if ($allGood) {
        Write-Host "✓ All prerequisites met!" -ForegroundColor Green
        return $true
    } else {
        Write-Host "✗ Some prerequisites missing. Install them and try again." -ForegroundColor Red
        return $false
    }
}

Write-Host "=== K3s Vagrant Testing Environment ===" -ForegroundColor Green

switch ($Action) {
    "prereqs" {
        Test-Prerequisites
    }
    
    "up" {
        Write-Host "Checking prerequisites first..." -ForegroundColor Cyan
        if (-not (Test-Prerequisites)) {
            Write-Host "✗ Prerequisites not met. Run './vagrant-setup.ps1 prereqs' for details." -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Starting Vagrant VMs with VirtualBox..." -ForegroundColor Yellow
        vagrant up --provider=virtualbox
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n✓ VMs started successfully!" -ForegroundColor Green
            
            # Set up SSH keys for deployment
            Write-Host "`nSetting up SSH keys..." -ForegroundColor Yellow
            
            # Create ssh_keys directory
            $sshKeysDir = "ssh_keys"
            if (-not (Test-Path $sshKeysDir)) {
                New-Item -ItemType Directory -Path $sshKeysDir -Force | Out-Null
                Write-Host "  ✓ Created $sshKeysDir directory" -ForegroundColor Green
            }
            
            # Create .gitignore in ssh_keys directory
            $gitignorePath = "$sshKeysDir/.gitignore"
            $gitignoreContent = @"
# Ignore all SSH keys to prevent accidental commits
*
!.gitignore
"@
            Set-Content -Path $gitignorePath -Value $gitignoreContent -Force
            Write-Host "  ✓ Created .gitignore for SSH keys" -ForegroundColor Green
            
            # Copy the actual vagrant machine private keys for each VM
            $vms = @("k3s-proxy", "k3s-master-1", "k3s-worker-1")
            $keysConfigured = 0
            
            foreach ($vm in $vms) {
                $vagrantKeySource = ".vagrant/machines/$vm/virtualbox/private_key"
                $vagrantKeyDest = "$sshKeysDir/vagrant_rsa_$vm"
                
                if (Test-Path $vagrantKeySource) {
                    Copy-Item $vagrantKeySource $vagrantKeyDest -Force
                    if ($IsWindows) {
                        # Windows: Set file permissions
                        $acl = Get-Acl $vagrantKeyDest
                        $acl.SetAccessRuleProtection($true, $false)
                        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
                        $acl.SetAccessRule($accessRule)
                        Set-Acl $vagrantKeyDest $acl
                    } else {
                        # Unix-like: Set proper permissions
                        chmod 600 $vagrantKeyDest
                    }
                    $keysConfigured++
                    Write-Host "  ✓ SSH key configured for $vm" -ForegroundColor Green
                } else {
                    Write-Host "  ⚠ Vagrant key not found for $vm at: $vagrantKeySource" -ForegroundColor Yellow
                }
            }
            
            # Also copy a generic key for the config (use master's key as default)
            if (Test-Path ".vagrant/machines/k3s-master-1/virtualbox/private_key") {
                Copy-Item ".vagrant/machines/k3s-master-1/virtualbox/private_key" "$sshKeysDir/vagrant_rsa" -Force
                if ($IsWindows) {
                    $acl = Get-Acl "$sshKeysDir/vagrant_rsa"
                    $acl.SetAccessRuleProtection($true, $false)
                    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
                    $acl.SetAccessRule($accessRule)
                    Set-Acl "$sshKeysDir/vagrant_rsa" $acl
                } else {
                    chmod 600 "$sshKeysDir/vagrant_rsa"
                }
            }
            
            if ($keysConfigured -eq $vms.Count) {
                Write-Host "  ✓ All SSH keys configured successfully in $sshKeysDir/" -ForegroundColor Green
            } else {
                Write-Host "  ⚠ Some SSH keys missing. Deployment may fail." -ForegroundColor Yellow
            }
            
            Write-Host "`nNext step - Deploy K3s cluster:" -ForegroundColor Cyan
            Write-Host "  pwsh ../../setup/k3s-setup.ps1 -ConfigFile test/minimal-cluster/vagrant-cluster.json" -ForegroundColor Yellow
            Write-Host "`nVM Details:" -ForegroundColor Cyan
            Write-Host "  Proxy:  192.168.56.100 (k3s-proxy)" -ForegroundColor White
            Write-Host "  Master: 192.168.56.10  (k3s-master-1)" -ForegroundColor White
            Write-Host "  Worker: 192.168.56.20  (k3s-worker-1)" -ForegroundColor White
        }
    }
    
    "status" {
        Write-Host "Checking VM status..." -ForegroundColor Yellow
        vagrant status
        Write-Host "`nVM Network Configuration:" -ForegroundColor Cyan
        Write-Host "  Proxy:  192.168.56.100 (k3s-proxy)" -ForegroundColor White
        Write-Host "  Master: 192.168.56.10  (k3s-master-1)" -ForegroundColor White
        Write-Host "  Worker: 192.168.56.20  (k3s-worker-1)" -ForegroundColor White
    }
    
    "ssh" {
        if ([string]::IsNullOrEmpty($Node)) {
            Write-Host "Available nodes: proxy, master, worker" -ForegroundColor Yellow
            Write-Host "Usage: ./vagrant-setup.ps1 ssh -Node master" -ForegroundColor Cyan
            return
        }
        
        $vmName = switch ($Node.ToLower()) {
            "proxy" { "k3s-proxy" }
            "master" { "k3s-master-1" }
            "worker" { "k3s-worker-1" }
            default { 
                Write-Host "Invalid node. Use: proxy, master, or worker" -ForegroundColor Red
                return
            }
        }
        
        Write-Host "Connecting to $vmName..." -ForegroundColor Yellow
        vagrant ssh $vmName
    }
    
    "destroy" {
        Write-Host "⚠️  This will destroy all VMs and data!" -ForegroundColor Red
        $confirm = Read-Host "Are you sure? (y/N)"
        if ($confirm -eq 'y' -or $confirm -eq 'Y') {
            vagrant destroy -f
            # Clean up storage files
            if (Test-Path "k3s-master-1-storage.vdi") {
                Remove-Item "k3s-master-1-storage.vdi" -Force
                Write-Host "✓ Cleaned up storage files" -ForegroundColor Green
            }
            Write-Host "✓ All VMs destroyed" -ForegroundColor Green
        } else {
            Write-Host "Operation cancelled" -ForegroundColor Yellow
        }
    }
    
    
    "clean" {
        Write-Host "Cleaning up generated files..." -ForegroundColor Yellow
        $filesToClean = @(
            ".vagrant", "k3s-master-1-storage.vdi", "ssh_keys", "vagrant_rsa*"
        )
        
        foreach ($file in $filesToClean) {
            if (Test-Path $file) {
                Remove-Item $file -Recurse -Force
                Write-Host "  ✓ Removed $file" -ForegroundColor Green
            }
        }
        Write-Host "✓ Cleanup complete" -ForegroundColor Green
    }
    
    default {
        Write-Host "`nVagrant K3s VM Management" -ForegroundColor Green
        Write-Host "Usage: ./vagrant-setup.ps1 <action>" -ForegroundColor Yellow
        
        Write-Host "`nVM Management Actions:" -ForegroundColor Cyan
        Write-Host "  prereqs      - Check system prerequisites (Vagrant, VirtualBox)" -ForegroundColor White
        Write-Host "  up           - Start all VMs (checks prerequisites first)" -ForegroundColor White
        Write-Host "  status       - Show VM status and IPs" -ForegroundColor White
        Write-Host "  ssh          - SSH to a VM (use -Node proxy|master|worker)" -ForegroundColor White
        Write-Host "  clean        - Clean up generated files" -ForegroundColor White
        Write-Host "  destroy      - Destroy all VMs and data" -ForegroundColor White
        
        Write-Host "`nWorkflow:" -ForegroundColor Yellow
        Write-Host "  1. ./vagrant-setup.ps1 up" -ForegroundColor White
        Write-Host "  2. pwsh ../../setup/k3s-setup.ps1 -ConfigFile test/minimal-cluster/vagrant-cluster.json" -ForegroundColor White
        Write-Host "  3. kubectl get nodes" -ForegroundColor White
        
        Write-Host "`nExamples:" -ForegroundColor Yellow
        Write-Host "  ./vagrant-setup.ps1 ssh -Node master" -ForegroundColor White
        Write-Host "  ./vagrant-setup.ps1 status" -ForegroundColor White
    }
}