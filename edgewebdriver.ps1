################################################################################
##  File:  Install-Edge.ps1
##  Desc:  Install Microsoft Edge, block auto-update, and allow Edge WebDriver URLs
################################################################################

# Install Microsoft Edge (Enterprise Stable Channel)
Install-Binary `
    -Url 'https://msedgesetup.azureedge.net/enterprise/stable/MicrosoftEdgeEnterpriseX64.msi' `
    -ExpectedSignature 'F27BA8D7BFADEB751348E4D238391D5F6D2F1D6E'

# Block Microsoft Edge update service via firewall
Write-Host "Blocking Microsoft Edge update service via firewall..."
New-NetFirewallRule -DisplayName "BlockEdgeUpdate" -Direction Outbound -Action Block `
    -Program "C:\\Program Files (x86)\\Microsoft\\EdgeUpdate\\MicrosoftEdgeUpdate.exe" -Enabled True

# Stop and disable update services
$edgeServices = Get-Service -Name "edgeupdate*" -ErrorAction SilentlyContinue
if ($edgeServices) {
    Stop-Service $edgeServices
    $edgeServices.WaitForStatus('Stopped', "00:01:00")
    $edgeServices | Set-Service -StartupType Disabled
}

# Disable Edge auto-updates via registry
$regEdgeUpdatePath = "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate"
$regEdgePath = "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge"
($regEdgeUpdatePath, $regEdgePath) | ForEach-Object {
    New-Item -Path $_ -Force
}

$regEdgeParameters = @(
    @{ Name = "AutoUpdateCheckPeriodMinutes"; Value = 0 },
    @{ Name = "UpdateDefault"; Value = 0 },
    @{ Name = "DisableAutoUpdateChecksCheckboxValue"; Value = 1 },
    @{ Name = "DoNotUpdateToEdgeWithChromium"; Value = 1 },
    @{ Path = $regEdgePath; Name = "DefaultBrowserSettingEnabled"; Value = 0 }
)

foreach ($param in $regEdgeParameters) {
    if ($param.Path) {
        New-ItemProperty -Path $param.Path -Name $param.Name -Value $param.Value -PropertyType DWord -Force
    } else {
        New-ItemProperty -Path $regEdgeUpdatePath -Name $param.Name -Value $param.Value -PropertyType DWord -Force
    }
}

################################################################################
# Allow Edge WebDriver Access
################################################################################

Write-Host "Allowing outbound access to Edge WebDriver endpoints..."

# Allow EdgeDriver JSON
New-NetFirewallRule -DisplayName "Allow_EdgeDriver_JSON" -Direction Outbound -Action Allow `
    -RemoteAddress "0.0.0.0/0" -RemotePort 443 -Protocol TCP `
    -Description "Allow EdgeDriver metadata access"

################################################################################
# Verification Section
################################################################################

Write-Host "Verifying firewall rules..."

# Verify allow rule for Edge
$allowEdge = Get-NetFirewallRule -DisplayName "Allow_EdgeDriver_JSON" -ErrorAction SilentlyContinue
if ($allowEdge -and $allowEdge.Enabled -eq "True") {
    Write-Host "Allow rule for EdgeDriver is enabled."
} else {
    Write-Warning "Allow rule for EdgeDriver not found or not enabled."
}



------------------------

Install-Binary `
    -Url 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f73bb7cb-5f6f-4fd4-9b8d-efaa14420f12/MicrosoftEdgeEnterpriseX64.msi' `
    -ExpectedSignature 'F27BA8D7BFADEB751348E4D238391D5F6D2F1D6E'
