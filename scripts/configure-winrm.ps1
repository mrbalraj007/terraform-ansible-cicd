# Run this in PowerShell as Administrator after RDP-ing into the Windows instance
# Script configures WinRM for Ansible connectivity

Write-Host "Configuring WinRM..." -ForegroundColor Green

# 1. Enable PSRemoting and WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-NetConnectionProfile -NetworkCategory Private

# 2. Configure WinRM — max memory, auth, and listeners
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# 3. Create self-signed cert and HTTPS listener
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
New-Item -Path WSMan:\Localhost\Listener -Transport HTTPS -Address * -CertificateThumbprint $cert.Thumbprint -Force -ErrorAction SilentlyContinue

# 4. Windows Firewall rules
New-NetFirewallRule -DisplayName "WinRM HTTP"  -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue

# 5. Restart WinRM service
Restart-Service WinRM -Force

# 6. Verify
winrm enumerate winrm/config/Listener

Write-Host "WinRM configured. Test: Test-WSMan -ComputerName localhost" -ForegroundColor Green