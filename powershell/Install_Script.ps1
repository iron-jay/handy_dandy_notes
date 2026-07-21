#########################################
# Functions
#########################################


Function Logging ([switch]$Err, [switch]$Warn, [switch]$Success, [switch]$lb, $msg){
        If ($Happening -eq $null){
            $Happening = $App}

        $LogFolderPath = "$env:temp"

        if ($Err){
            $prefix = "ERROR"}
        elseif ($Warn){
            $prefix = "WARNING"}
        elseif ($Success){
            $prefix = "SUCCESS"}
        else{
            $prefix = "INFO"}

        $LogP = "$LogFolderPath\$Happening $(Get-Date -Format yyyy-MM-dd).log"
        
        If ($lb){
            Add-Content -Path $logP -Value " "
            }
        Else{
            If (!(Test-Path $LogP)){
                Add-Content -Path $LogP -Value "$(Get-Date -Format hh:mm:ss) - $Happening Log Created"
                }
            Add-Content -Path $LogP -Value "$(Get-Date -Format hh:mm:ss) - $prefix - $msg"
            }
        }
	


Function RunApp ([switch]$In, [switch]$Unin, $Name, $Command, $Argument){
    if ($In){
            $action = "install"}
    elseif ($Unin){
            $action = "uninstall"}
    
    Logging -msg "Attempting $action on $name"

    $Return = (Start-Process $Command -ArgumentList $Argument -Wait -PassThru -NoNewWindow -ErrorVariable $err_exit).ExitCode

    if (!(($Return -eq 0) -or ($Return -eq 3010))){
        if (($action -eq "uninstall") -and ($Return -eq 1605)){
            Logging -Warn -msg "$Name is not installed, nothing to uninstall"
            }
        else{
            Logging -Err -msg "Step Failed"
            Logging -Err -msg "Exit Code: $Return"
            Logging -Err -msg "$err_exit"
            #[environment]::ExitCode = $Return
            #[environment]::Exit($Return)
            }
        }
    Else{
        Logging -Success -msg "Successfully ran $action on $Name"
        Logging -Success -msg "Exit Code: $Return"
        }
    }


#########################################
# Do Some Things
#########################################

$Happening = "Suite name"

Logging -Success "*** SCRIPT STARTED ***"

$App = "app name"
$Com = "app.exe"
$Arg = "/q"
RunApp -In $App $Com $Arg

Logging -Success -msg "*** SCRIPT COMPLETE ***"
