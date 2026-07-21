#MCM Client Installer

Function ConsoleLog
{
    param ([string]$Message)
    $Time = Get-Date -Format G
    Write-host "$Time - $Message"
}
Function RunApp ($Command, $Argument)
{
    $Return = (Start-Process -FilePath $Command -ArgumentList $Argument -Wait -PassThru).ExitCode
    If (!($Return.ExitCode -eq 0 -or $Return.ExitCode -eq 3010))
    {
        ConsoleLog "Failure"
        ConsoleLog "Exit Code: $Return.ExitCode"
        ConsoleLog "$Error[0].Exception.Message.ToString()"
    }
}


Import-Module BitsTransfer
Write-Host " 
 _____ ______   _______   ________  _____ ______           ________  ___       ___  _______   ________   _________   
|\   _ \  _   \|\  ___ \ |\   ____\|\   _ \  _   \        |\   ____\|\  \     |\  \|\  ___ \ |\   ___  \|\___   ___\ 
\ \  \\\__\ \  \ \   __/|\ \  \___|\ \  \\\__\ \  \       \ \  \___|\ \  \    \ \  \ \   __/|\ \  \\ \  \|___ \  \_| 
 \ \  \\|__| \  \ \  \_|/_\ \  \    \ \  \\|__| \  \       \ \  \    \ \  \    \ \  \ \  \_|/_\ \  \\ \  \   \ \  \  
  \ \  \    \ \  \ \  \_|\ \ \  \____\ \  \    \ \  \       \ \  \____\ \  \____\ \  \ \  \_|\ \ \  \\ \  \   \ \  \ 
   \ \__\    \ \__\ \_______\ \_______\ \__\    \ \__\       \ \_______\ \_______\ \__\ \_______\ \__\\ \__\   \ \__\
    \|__|     \|__|\|_______|\|_______|\|__|     \|__|        \|_______|\|_______|\|__|\|_______|\|__| \|__|    \|__|
                                                                                                                     
 ________  _______   ___  ________   ________  _________  ________  ___       ___       _______   ________     
|\   __  \|\  ___ \ |\  \|\   ___  \|\   ____\|\___   ___\\   __  \|\  \     |\  \     |\  ___ \ |\   __  \    
\ \  \|\  \ \   __/|\ \  \ \  \\ \  \ \  \___|\|___ \  \_\ \  \|\  \ \  \    \ \  \    \ \   __/|\ \  \|\  \   
 \ \   _  _\ \  \_|/_\ \  \ \  \\ \  \ \_____  \   \ \  \ \ \   __  \ \  \    \ \  \    \ \  \_|/_\ \   _  _\  
  \ \  \\  \\ \  \_|\ \ \  \ \  \\ \  \|____|\  \   \ \  \ \ \  \ \  \ \  \____\ \  \____\ \  \_|\ \ \  \\  \| 
   \ \__\\ _\\ \_______\ \__\ \__\\ \__\____\_\  \   \ \__\ \ \__\ \__\ \_______\ \_______\ \_______\ \__\\ _\ 
    \|__|\|__|\|_______|\|__|\|__| \|__|\_________\   \|__|  \|__|\|__|\|_______|\|_______|\|_______|\|__|\|__|"
Write-Host ""
ConsoleLog "Uninstalling Client"
$App = "C:\Windows\ccmsetup\CCMSetup.exe"
$CommandLine = "/uninstall"
RunApp $App $CommandLine
ConsoleLog "Complete"
 
Write-Host ""
ConsoleLog "Getting Domain Info"
$domain = (get-ciminstance win32_computersystem).domain
if($domain -eq "domain1"){
    $server = "primary1"
    $site = "site1"}
if($domain -eq "domain2"){
    $server = "primary2"
    $site = "site2"}
if($domain -eq "domain3"){
    $server = "primary3"
    $site = "site3"}
Write-Host ""
 
ConsoleLog "Domain is $domain"
ConsoleLog "Primary is $server"
ConsoleLog "Site Code is $site"
Write-Host ""
 
ConsoleLog "Copying client from primary to local storage."
try{
    Start-BitsTransfer -Source "<path to install files>" -Destination "C:\Windows\CCMSetup" -TransferType Download -Description "MECM Client" -DisplayName "MECM Client"
    ConsoleLog "Complete"
    }
catch{
    ConsoleLog "Failed"
    ConsoleLog "$Error[0].Exception.Message.ToString()"
    }
 
Write-Host ""
ConsoleLog "Installing Client"
$App = "C:\Windows\ccmsetup\CCMSetup.exe"
$CommandLine = "/mp:$server SMSSITECODE=$site /forceinstall"
RunApp $App $CommandLine
$on = get-process -Name "ccmsetup" -ErrorAction SilentlyContinue
while ($on -ne $null){
    Start-Sleep -Seconds 5
    $on = get-process -Name "ccmsetup" -ErrorAction SilentlyContinue}
ConsoleLog "Complete"
Write-Host ""
ConsoleLog "Re-install complete."