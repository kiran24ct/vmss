packer {
  required_plugins {
    azure = {
      source = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}  

build {
  sources = [
    # "source.azure-arm.win-2016"
    # "source.azure-arm.win-2019"
    "source.azure-arm.win-2022"
  ]

  #######################################################################################
  #                                                                                     #
  # Configure install user and AzDevOps user                                            #
  #                                                                                     #
  #######################################################################################
  provisioner "windows-shell" {
    inline = [
      "net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes /active:yes /Y", 
      "net localgroup Administrators ${var.install_user} /add", 
      "net userAzDevOps ${var.install_password) /add /passwordchg:no /passwordreg:yes /active:yes /Y",
      "net localgroup Administrators AzDevOps /add", 
      "winrm set winrm/config/service/auth @${Basic=\"true\"}`",
      "winrm get winrm/config/service/auth"
    ]    
  }

  #######################################################################################
  #                                                                                     #
  # Install NFCU Certificates                                                           # 
  # ニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニニ
  # This is done early in the process to ensure tooling that needs to download from the # 
  # internet works as expected                                                          #
  #                                                                                     #  
  #######################################################################################
  provisioner "file" {
    destination = "${local.cert_path}"
    source      = "${path.root}/../certs/"
  }

  provisioner "powershell" {
    script = "${path.root}/../scripts/build/Install-NfcuCertificate.ps1"
  }

  #######################################################################################
  #                                                                                     #
  # Configure PowerShell
  #                                                                                     #
  #######################################################################################
  provisioner "powershell" {
    script = "${path.root}/../scripts/build/Configure-PowerShell.ps1"
  }

  #######################################################################################
  #                                                                                     #
  # folder creation and file copy operations                                            #
  #                                                                                     #
  #######################################################################################
  provisioner "powershell" {
    inline = [
      "New-Item -Path ${local.image_folder} -ItemType Directory -Force", 
      "New-Item -Path ${local.tool_cache} -ItemType Directory -Force"
    ]
  }

  provisioner "file" {
  destination = "${local.powershell_modules_path}\\ImageHelpers"
  source      = "${path.root}/../scripts/modules/"
 }

  provisioner "file" {
  destination = "${local.image_folder}\\tests"
  source      = "${path.root}/../scripts/tests/"
 }

  provisioner "powershell" {
    inline = [
      "\"${var.image_version}\" | Out-File .version",
      "[Environment]::SetEnvironmentVariable('IMAGE_VERSION', '${var.image_version}', 'Machine')"
    ]
  }

  provisioner "powershell" {
    inline = [
      "\"${var.image_version}\" | Out-File .version",
      "[Environment]::SetEnvironmentVariable('IMAGE_VERSION', '${var.image_version}', 'Machine')"
    ]
  }

  #######################################################################################
  #                                                                                     #   
  # Manifest files                                                                      #
  #                                                                                     #
  #######################################################################################
  provisioner "file" {
    # This copies the Windows 2016 specific manifest to the Windows 2016 Packer VM.
    destination = "${local.image_folder}\\manifest.json"
    only        = ["azure-arm.win-2016"]
    sources     = ["${path.root}/../manifests/win2016.json"]
  }

  provisioner "file" {
    # This copies the Windows 2019 specific manifest to the Windows 2016 Packer VM.
    destination = "${local.image_folder}\\manifest.json"
    only        = ["azure-arm.win-2019"]
    sources     = ["${path.root}/../manifests/win2016.json"]
  }

  provisioner "file" {
    # This copies the Windows 2022 specific manifest to the Windows 2016 Packer VM.
    destination = "${local.image_folder}\\manifest.json"
    only        = ["azure-arm.win-2022"]
    sources     = ["${path.root}/../manifests/win2022.json"]
  }  

  #######################################################################################
  #                                                                                     #   
  # Install Powershell Modules   
  # =================================================================================== #  
  # This is is done before installing software and tooling to ensure the latest version
  # of Pester is installed, otherwise it defaults to the version bundled in Windows.
  # The bundled version is rather old and does not support the tests written for this
  # pipeline.
  # 
  #######################################################################################
  provisioner "powershell" {
    script = "$[path.root]/../scripts/build/Install-PowerShel1Modules.ps1"
  }

  #######################################################################################
  #                                                                                     #  
  # Set PowerShell Repository for AzDevOps User                                         #
  #=====================================================================================#
  # Azure DevOps will use the user AzDevOps to run the agent under. This user must be
  # configured to use Artifactory to download PowerShell modules from. We must do this
  # under the AzDevOps user because Set-PRepository is a user configuration and not a
  # global configuration.
  #
  #######################################################################################
  provisioner "powershell" {
    elevated password = "${var .install_password}"
    elevated_user     = "AzDevOps" 
    script            = "${path.root}/../scripts/build/Set-PowerShellRepository.ps1'
  }

  #######################################################################################
  #                                                                                     #  
  # Install Windows Features
  # ================================================================================== #
  # Several of these features are needed before the software can be installed
  # (such as Docker). Once done, a reboot is needed.
  #
  #######################################################################################
  provisioner "powershell" {
    script = ["${path.root}/../scripts/build/Install-WindowsFeatures.ps1"
  }

  # Set system time Zone to EST
  provisioner "powershell" {
    inline = [
      "Set-TimeZone -Id 'Eastern Standard Time'"
    ]
  }

  # Post reboot, you get the "Windows installing features" screen
  # The restart_check_command is used to make sure the step is done
  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {while ( (Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue).State -ne 'Enabled' ) { Start-Sleep30; Writ-Output 'Inprogress' }}\""
    restart timeout       = "10m"
  }

  # Disable unused WLANSVC service
  provisioner "powershell" {
    inline = ["Set-Service -Name wlansvc -StartupType Manual", "if ((Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc }"]
  }

  #######################################################################################
  #
  # Install Software and Tools
  # ================================================================================== #
  # The order of installs may be important to ensure tools are available for downstream
  # installs. Take caution when added new entries or changing the order of the scripts.
  #
  #######################################################################################
  provisioner "powershell" {
  scripts = [
    "${path.root}/../scripts/build/Install-AzCopy.ps1",
    "${path.root}/../scripts/build/Install-Jq.ps1",
    "${path.root}/../scripts/build/Install-Git.ps1",
    "${path.root}/../scripts/build/Install-PowerShellCore.ps1",
    "${path.root}/../scripts/build/Install-VisualStudio.ps1",
    "${path.root}/../scripts/build/Install-DacFx.ps1",
    "${path.root}/../scripts/build/install_7-zip.ps1",
    "${path.root}/../scripts/build/InstallAzcli.ps1",
    "${path.root}/../scripts/build/InstallDAClient.ps1",
    "${path.root}/../scripts/build/InstallCF-CLI.ps1",
    "${path.root}/../scripts/build/InstallPSModules.ps1",
    "${path.root}/../scripts/build/Install-Python.ps1",
    "${path.root}/../scripts/build/firefox_install.ps1",
    "${path.root}/../scripts/build/InstallTabularEditor.ps1",
    "${path.root}/../scripts/build/InstallUCD.ps1",
    "${path.root}/../scripts/build/Install-NodeJs.ps1",
    "${path.root}/../scripts/build/Set-AgentEnvironmentVariables.ps1",
    "${path.root}/../scripts/build/Install-Docker.ps1",
    "${path.root}/../scripts/build/Install-Venafi.ps1",
    "${path.root}/../scripts/build/Install-Kubelogin.ps1",
    "${path.root}/../scripts/build/Configure-NuGet.ps1",
    "${path.root}/../scripts/build/Configure-Pypi.ps1"
   ]
 } 

 provisioner "powershell" {
   environment_vars = [
     "MAVEN_JFROG_ADO_PASSWORD=${var.maven_jfrog_ado_password}",
     "MAVEN_JFROG_ADO_USERNAME=${var.maven_jfrog_ado_username}"
   ]
   scripts = [
     "${path.root}/../scripts/build/Install-JavaDevelopmentKit.ps1",
     "${path.root}/../scripts/build/Install-Ant.ps1",
     "${path.root}/../scripts/build/Install-Maven.ps1"
   ]
 }

 provisioner "powershell" {
   elevated_password = "${var.install_password}"
   elevated_user     = "AzDevOps"
   environment_vars  = ["GH_TOKEN=${var-github_token}"]
   script            = "${path.root}/../scripts/build/Install-GitHubCli.ps1"
 }

 #######################################################################################
 #                                                                                     #
 # Reboot before installing Chrome
 # ===================================================================================== #
 # This addresses random failures when installing Chrome. It likely has something to do
 # with the installation of Visual Studio or Windows Updates.
 #
 #######################################################################################
  provisioner "windows-restart" (
    restart_check_command - "powershell -command \"& (Write-Output restarted. "}\""
  }

  provisioner "powershell" {
    script = "${path.root}/../scripts/build/Install_Chrome.ps1"
  }

  #######################################################################################
  #                                                                                     #
  # Sysprep
  # ==================================================================================  #
  # This must be the last step as it ensures the image is ready to be used in VM or VMSS
  # creation. Generally, this should not be modified.
  #                                                                                     #                                                                                  
  #######################################################################################
  provisioner "powershell" {
    inline = [
      "if (Test-Path \"$env:SystemRoot\\System32\\Sysprep\\unattend.xml\") { Remove-Item \"$env:SystemRoot\\System32\\Sysprep\\unattend.xml\" -Force }",
      "& \"$env:SystemRoot\\System32\\Sysprep\\Sysprep.exe\" /oobe /generalize /mode:vm /quiet /quit",
      "while($true) { $imageState = Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State' | Select-Object -ExpandProperty ImageState; if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState; Start-Sleep -Seconds 10 } else { break } }"
    ]
  }
}
