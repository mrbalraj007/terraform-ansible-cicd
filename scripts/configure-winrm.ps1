<powershell>
$LogFile = "C:\winrm_setup.log"
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $LogFile -Append
}

Write-Log "=== WinRM Bootstrap Started ==="

# STEP 1 - Execution policy
Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force
Write-Log "ExecutionPolicy: Unrestricted"

# STEP 2 - Create local admin for Ansible
$AnsibleUser = "ansible_admin"
$AnsiblePass = ConvertTo-SecureString "REPLACE_WITH_YOUR_PASSWORD" -AsPlainText -Force
if (Get-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue) {
    Remove-LocalUser -Name $AnsibleUser
}
New-LocalUser -Name $AnsibleUser -Password $AnsiblePass `
    -FullName "Ansible Admin" -Description "WinRM service account" `
    -PasswordNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member $AnsibleUser
Write-Log "Created local admin: $AnsibleUser"

# STEP 3 - Ensure WinRM is RUNNING before touching WSMan provider
Set-Service  -Name WinRM -StartupType Automatic
Start-Service -Name WinRM -ErrorAction SilentlyContinue
Start-Sleep  -Seconds 3
Write-Log "WinRM service: $((Get-Service WinRM).Status)"

# STEP 4 - Enable PSRemoting
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Start-Sleep -Seconds 2
Write-Log "PSRemoting enabled"

# STEP 5 - Configure via winrm.cmd (avoids WSMan drive hang)
winrm set winrm/config/service      '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/winrs        '@{MaxMemoryPerShellMB="1024"}'
winrm set winrm/config              '@{MaxTimeoutms="1800000"}'
Write-Log "WinRM settings applied"

# STEP 6 - Create HTTP listener if missing
$enumOut = & winrm enumerate winrm/config/listener 2>&1
if ($enumOut -notmatch "Transport = HTTP") {
    & winrm create winrm/config/listener?Address=*+Transport=HTTP
    Write-Log "HTTP listener created"
} else {
    Write-Log "HTTP listener already present"
}

# STEP 7 - Firewall rules + disable Windows Firewall
netsh advfirewall firewall add rule name="WinRM-HTTP-5985" protocol=TCP dir=in localport=5985 action=allow
netsh advfirewall firewall add rule name="WinRM-HTTPS-5986" protocol=TCP dir=in localport=5986 action=allow
netsh advfirewall set allprofiles state off
Write-Log "Firewall configured and disabled"

# STEP 8 - Restart WinRM to apply all changes
Restart-Service WinRM -Force
Start-Sleep -Seconds 5
Write-Log "WinRM final status: $((Get-Service WinRM).Status)"

# STEP 9 - Confirm port listening
$listening = netstat -an | Select-String "0.0.0.0:5985"
if ($listening) { Write-Log "Port 5985 LISTENING: OK" }
else            { Write-Log "WARNING: Port 5985 not found in netstat" }

Write-Log "=== WinRM Bootstrap Complete ==="
</powershell>