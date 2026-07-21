<# 

Combined from Johan Schrewelius' CopyOSDLogs and TSVarsSafeDump scripts

    Command: powershell.exe -executionpolicy bypass -file CopyOSDLogs.ps1 
    Usage: Run in SCCM Task Sequence Error handling Section. 
           to zip and copy SMSTSLog folder to Share.
    Config:  
        $ComputerNameVariable = "OSDComputerName" 

    Command: powershell.exe -executionpolicy bypass -file TSVarsSafeDump.ps1 
    Usage:  Run in MEMCM Task Sequence to Dump TS-Varibles to disk ("_SMSTSLogPath"). 
            Variables known to contain sensitive information will be hidden.
    Confg: List of variables to exclude, edit as needed: 
            $HideVariables = @('_OSDOAF','_SMSTSReserved','_SMSTSTaskSequence') 
#> 

# Config Start 

$ComputerNameVariable = "OSDComputerName" 
$HideVariables = @('_OSDOAF','_SMSTSReserved','_SMSTSTaskSequence', '_TSSub') 

# Config End 

function Authenticate { 
    param( 
        [string]$UNCPath = $(Throw "An UNCPath must be specified"), 
        [string]$User, 
        [string]$PW 
    ) 
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo 
    $pinfo.FileName = "net.exe" 
    $pinfo.UseShellExecute = $false 
    $pinfo.Arguments = "USE $($UNCPath) /USER:$($User) $($PW)" 
    $p = New-Object System.Diagnostics.Process 
    $p.StartInfo = $pinfo 
    $p.Start() | Out-Null 
    $p.WaitForExit() 
}  

function ZipFiles { 
    param( 
        [string]$ZipFileName, 
        [string]$SourceDir 
    ) 
   Add-Type -Assembly System.IO.Compression.FileSystem 
   $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal 
   [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipFileName, $compressionLevel, $false) 
}  

function MatchArrayItem { 
    param ( 
        [array]$Arr, 
        [string]$Item 
        ) 
    $result = ($null -ne ($Arr | ? { $Item -match $_ })) 
    return $result 
}  

try { 
    $dt = get-date -Format "yyyy-MM-dd-HH-mm-ss" 
    $tsenv = New-Object -ComObject Microsoft.SMS.TSEnvironment 
    $LogPath = $tsenv.Value("SLShare") 
    $CmpName = $tsenv.Value("$ComputerNameVariable") 
    $source =  $tsenv.Value("_SMSTSLogPath") 
    $NaaUser = $tsenv.Value("_SMSTSReserved1-000") 
    $NaaPW = $tsenv.Value("_SMSTSReserved2-000") 

    Copy-Item "C:\Windows\Debug\NetSetup.log" -Destination $source -ErrorAction SilentlyContinue 
    
    $varNames = $tsenv.GetVariables() 
    $logFile = "TSVariables-$dt.log" 
    $logFileFullName = Join-Path -Path $source -ChildPath $logFile 
    
    foreach ($varName in $varNames) { 
        if ($varName.EndsWith("_HiddenValueFlag")) { 
            continue; 
        } 
        $value = $tsenv.Value($varName) 
            if ($varNames.Contains("$($varName)_HiddenValueFlag") -or (MatchArrayItem -Arr $HideVariables -Item $varName)) { 
            $value = "Hidden value" 
        } 
        "$varName = $value" | Out-File -FilePath $logFileFullName -Append 
    } 
    
    New-Item "$source\tmp" -ItemType Directory -Force 
    Copy-Item "$source\*" "$source\tmp" -Force -Exclude "tmp" 
    $source = "$source\tmp" 
    try { # Catch Error if already authenticated 
        Authenticate -UNCPath $LogPath -User $NaaUser -PW $NaaPW 
    } 
    catch {} 

    $filename =  Join-Path -Path "$LogPath" -ChildPath "$($CmpName )-$($dt).zip" 
    ZipFiles -ZipFileName $filename -SourceDir $source  
    Remove-Item -Path "$source" -Recurse -Force -ErrorAction SilentlyContinue 
} 

catch { 
    Write-Output "$_.Exception.Message" 
    exit 1 
} 