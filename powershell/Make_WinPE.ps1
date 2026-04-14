#Commands to Manually Make Boot Image:
 
#Some Variables
$PSLocation = "C:\WinPE_amd64_PS" 
$wimLocal = "$PSLocation\media\sources\boot.wim"
$wimExport = "$PSLocation\media\sources\Boot_Win11x64_24H2.wim"
$mountPoint = "$PSLocation\mount"
$DISMPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\"
$ocPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
$driverPath = "C:\Boot\Driver"
 
function Copy-PE {
  $env = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat" 
  cmd.exe /c """$env"" && copype amd64 $PSLocation"
}
 
function Make-ISO {
  $env = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat" 
  cmd.exe /c """$env"" && MakeWinPEMedia /ISO $PSLocation $PSLocation\WinPE_amd64.iso"
}
#Remove Old WIM resources
Remove-item "C:\WinPE_amd64_PS" -Recurse 

#Make a fresh copy
Copy-PE 
Mount-WindowsImage -Path $mountpoint -ImagePath $wimLocal -Index 1 -Verbose

#Add Optional Capabilities
Add-WindowsPackage -PackagePath "$($ocPath)\winpe-wmi.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\winpe-wmi_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-NetFX.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-NetFX_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-HTA.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-HTA_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-Scripting.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\winpe-scripting_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\winpe-wds-tools.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-WDS-Tools_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-SecureStartup.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-SecureStartup_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-PowerShell.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-PowerShell_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-StorageWMI.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-StorageWMI_en-us.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-DismCmdlets.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-DismCmdlets_en-us.cab" -Path $mountPoint -Verbos
Add-WindowsPackage -PackagePath "$($ocPath)\WinPE-Dot3Svc.cab" -Path $mountPoint -Verbose
Add-WindowsPackage -PackagePath "$($ocPath)\en-us\WinPE-Dot3Svc_en-us.cab" -Path $mountPoint -Verbose

#Add Drivers
Add-WindowsDriver -Path $mountPoint -Driver $driverPath -Recurse

#Add other stuff (if needed)
#Copy-Item -Path "C:\Boot\Build" -Destination $mountPoint -Recurse -Force

#Apply update (if needed)
#Add-WindowsPackage -PackagePath "C:\Boot\Updates\windows11.0-kb5032202-x64.msu" -Path $mountPoint -Verbose

#Do Some Cleanup
Start-Process "$DISMPath\DISM.exe" -ArgumentList " /Image:$mountPoint /Cleanup-image /StartComponentCleanup /Resetbase /Defer" -Wait -LoadUserProfile -NoNewWindow
Start-Process "$DISMPath\DISM.exe" -ArgumentList " /Image:$mountPoint /Cleanup-image /StartComponentCleanup /Resetbase" -Wait -LoadUserProfile -NoNewWindow

#Dismount and Save
Dismount-WindowsImage -Path $mountPoint -Save -Verbose
Export-WindowsImage -SourceImagePath $wimLocal -SourceIndex 1 -DestinationImagePath $wimExport -CompressionType max -Verbose

#Make an ISO if you want
#Make-ISO 
