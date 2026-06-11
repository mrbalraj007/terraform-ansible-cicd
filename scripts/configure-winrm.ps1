<powershell>
$LogFile = "C:\winrm_setup.log"
$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $LogFile -Append
}

Write-Log "=== WinRM Bootstrap Started ==="

# STEP 1 - Execution policy
Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force -ErrorAction SilentlyContinue
Write-Log "ExecutionPolicy: Unrestricted"

# STEP 2 - Create local admin for Ansible
$AnsibleUser = "ansible_admin"
$AnsiblePass = ConvertTo-SecureString "${WINRM_PASSWORD}" -AsPlainText -Force
try {
    if (Get-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue
    }
    New-LocalUser -Name $AnsibleUser -Password $AnsiblePass `
        -FullName "Ansible Admin" -Description "WinRM service account" `
        -PasswordNeverExpires -ErrorAction Stop
    Add-LocalGroupMember -Group "Administrators" -Member $AnsibleUser -ErrorAction SilentlyContinue
    Write-Log "Created local admin: $AnsibleUser"
} catch {
    Write-Log "WARNING: Could not create local admin: $($_.Exception.Message)"
}

# STEP 3 - Ensure WinRM is running
Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name WinRM -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Write-Log "WinRM service: $((Get-Service WinRM).Status)"

# STEP 4 - Enable PSRemoting
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Log "PSRemoting enabled"
} catch {
    Write-Log "WARNING: Enable-PSRemoting failed: $($_.Exception.Message)"
}

# STEP 5 - Configure WinRM settings
try {
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-Null
    winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-Null
    winrm set winrm/config/service/auth '@{CredSSP="true"}' 2>&1 | Out-Null
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}' 2>&1 | Out-Null
    winrm set winrm/config '@{MaxTimeoutms="1800000"}' 2>&1 | Out-Null
    Write-Log "WinRM settings applied"
} catch {
    Write-Log "WARNING: WinRM settings error: $($_.Exception.Message)"
}

# STEP 6 - Create HTTP listener
try {
    $enumOut = & winrm enumerate winrm/config/listener 2>&1
    if ($enumOut -notmatch "Transport = HTTP") {
        & winrm create winrm/config/listener?Address=*+Transport=HTTP 2>&1 | Out-Null
        Write-Log "HTTP listener created"
    } else {
        Write-Log "HTTP listener already present"
    }
} catch {
    Write-Log "WARNING: HTTP listener creation failed: $($_.Exception.Message)"
}

# STEP 7 - Create HTTPS listener with self-signed cert
try {
    $thumbprint = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=WINRM" } | Select-Object -First 1).Thumbprint
    if (-not $thumbprint) {
        Write-Log "Creating self-signed certificate for WinRM HTTPS..."
        $thumbprint = (New-SelfSignedCertificate -DnsName $env:COMPUTERNAME, WINRM -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop).Thumbprint
        Write-Log "Certificate created: $thumbprint"
    }
    $httpsExists = & winrm enumerate winrm/config/listener 2>&1 | Select-String "Transport = HTTPS"
    if (-not $httpsExists) {
        & winrm create winrm/config/listener?Address=*+Transport=HTTPS "@{CertificateThumbprint=`"$thumbprint`"}" 2>&1 | Out-Null
        Write-Log "HTTPS listener created with thumbprint $thumbprint"
    } else {
        Write-Log "HTTPS listener already present"
    }
} catch {
    Write-Log "WARNING: HTTPS listener creation failed: $($_.Exception.Message)"
}

# STEP 8 - Firewall rules
try {
    netsh advfirewall firewall add rule name="WinRM-HTTP-5985" protocol=TCP dir=in localport=5985 action=allow 2>&1 | Out-Null
    netsh advfirewall firewall add rule name="WinRM-HTTPS-5986" protocol=TCP dir=in localport=5986 action=allow 2>&1 | Out-Null
    netsh advfirewall set allprofiles state off 2>&1 | Out-Null
    Write-Log "Firewall configured"
} catch {
    Write-Log "WARNING: Firewall configuration failed: $($_.Exception.Message)"
}

# STEP 9 - Restart WinRM and wait for it
try {
    Restart-Service WinRM -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    Write-Log "WinRM final status: $((Get-Service WinRM).Status)"
} catch {
    Write-Log "WARNING: WinRM restart failed: $($_.Exception.Message)"
    Start-Service -Name WinRM -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# STEP 10 - Confirm ports listening with retry
Start-Sleep -Seconds 5
$tries = 0
$maxTries = 6
do {
    $tries++
    Start-Sleep -Seconds 5
    $listeners = & winrm enumerate winrm/config/listener 2>&1
    Write-Log "WinRM listeners (attempt $tries): $(($listeners | Select-String 'Transport' | ForEach-Object { $_.ToString().Trim() }) -join ', ')"
    $httpOk = $listeners -match "Transport = HTTP"
    $httpsOk = $listeners -match "Transport = HTTPS"
} until (($httpOk -and $httpsOk) -or $tries -ge $maxTries)

$netstat = netstat -an 2>&1
$port5985 = $netstat | Select-String ":5985"
$port5986 = $netstat | Select-String ":5986"
if ($port5985) { Write-Log "Port 5985 LISTENING: OK" }
else           { Write-Log "WARNING: Port 5985 not found in netstat" }
if ($port5986) { Write-Log "Port 5986 LISTENING: OK" }
else           { Write-Log "WARNING: Port 5986 not found in netstat" }

Write-Log "=== WinRM Bootstrap Complete ==="
</powershell>