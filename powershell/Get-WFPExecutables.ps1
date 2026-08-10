#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scans the Security event log for Windows Filtering Platform (WFP)
    "Filtering Platform Connection" and "Filtering Platform Packet Drop"
    events and lists the distinct executables involved.

.DESCRIPTION
    Queries these WFP event IDs from the Security log (or a saved .evtx file):
      Filtering Platform Connection : 5031, 5150, 5151, 5154, 5155, 5156, 5157, 5158, 5159
      Filtering Platform Packet Drop: 5152, 5153
    Pulls the "Application Name" field out of each event's XML, converts the
    \device\harddiskvolumeN\... path to a drive letter, and reports distinct
    executables with hit counts, audit result (Success/Failure), and the
    time/EventRecordId of the most recent occurrence of each.

.PARAMETER EvtxPath
    Path to a saved .evtx file to scan instead of the live Security log.
    If omitted (default), the live Security event log is queried.

.PARAMETER StartTime
    Only include events on/after this time. Default: 24 hours ago.

.PARAMETER MaxEvents
    Cap on number of events pulled from the log (performance safety valve).
    Default: 50000.

.PARAMETER CsvPath
    If supplied, exports the distinct-executable summary (Category,
    Executable, AuditResult, Count, LastSeen, LastEventId, LastRecordId) to
    this CSV path. This is the default export and matches the console output.

.PARAMETER AllEventsCsvPath
    If supplied, additionally exports every individual matching event
    (one row per event, not deduplicated) to this CSV path.

.EXAMPLE
    .\Get-WFPExecutables.ps1

.EXAMPLE
    .\Get-WFPExecutables.ps1 -StartTime (Get-Date).AddDays(-7) -CsvPath C:\Temp\wfp-summary.csv

.EXAMPLE
    .\Get-WFPExecutables.ps1 -EvtxPath C:\Temp\Security.evtx -CsvPath C:\Temp\wfp-summary.csv -AllEventsCsvPath C:\Temp\wfp-all-events.csv
#>

[CmdletBinding()]
param(
    [string]$EvtxPath,
    [datetime]$StartTime = (Get-Date).AddHours(-24),
    [int]$MaxEvents = 50000,
    [string]$CsvPath,
    [string]$AllEventsCsvPath
)

$connectionIds = 5031, 5150, 5151, 5154, 5155, 5156, 5157, 5158, 5159
$packetDropIds = 5152, 5153
$allIds        = $connectionIds + $packetDropIds

# Map volume device paths (\device\harddiskvolumeN\) to drive letters
$volumeMap = @{}
Get-CimInstance Win32_Volume | ForEach-Object {
    if ($_.DeviceID -match 'harddiskvolume\d+' -and $_.DriveLetter) {
        $volumeMap[$Matches[0].ToLower()] = $_.DriveLetter
    }
}

function Convert-DevicePath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -match '\\device\\(harddiskvolume\d+)\\(.*)') {
        $vol = $Matches[1].ToLower()
        $rest = $Matches[2]
        if ($volumeMap.ContainsKey($vol)) {
            return "$($volumeMap[$vol])\$rest"
        }
    }
    return $Path
}

function Format-TimeForCsv {
    param([datetime]$Time)
    # Prefix with an apostrophe so Excel treats it as plain text instead of
    # re-parsing it as a date and silently truncating seconds/AM-PM on display.
    return "'" + $Time.ToString('yyyy-MM-dd hh:mm:ss tt')
}

$filter = @{
    Id        = $allIds
    StartTime = $StartTime
}

if ($EvtxPath) {
    if (-not (Test-Path -LiteralPath $EvtxPath)) {
        throw "EvtxPath not found: $EvtxPath"
    }
    $filter['Path'] = (Resolve-Path -LiteralPath $EvtxPath).Path
    Write-Host "Querying evtx file '$($filter['Path'])' (WFP events, since $StartTime)..." -ForegroundColor Cyan
}
else {
    $filter['LogName'] = 'Security'
    Write-Host "Querying live Security log (WFP events, since $StartTime)..." -ForegroundColor Cyan
}

try {
    $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
}
catch [Exception] {
    if ($_.Exception.Message -match 'No events were found') {
        Write-Host "No matching events found in the given time range." -ForegroundColor Yellow
        return
    }
    throw
}

Write-Host "Retrieved $($events.Count) events. Parsing..." -ForegroundColor Cyan

$results = foreach ($evt in $events) {
    $xml = [xml]$evt.ToXml()
    $data = @{}
    foreach ($node in $xml.Event.EventData.Data) {
        $data[$node.Name] = $node.'#text'
    }

    $appRaw = $data['Application']
    if (-not $appRaw) { $appRaw = $data['ApplicationName'] }
    $app = Convert-DevicePath $appRaw

    $auditResult = ($evt.KeywordsDisplayNames | Where-Object { $_ -match 'Audit (Success|Failure)' } | Select-Object -First 1)
    if (-not $auditResult) { $auditResult = 'Unknown' }

    [pscustomobject]@{
        TimeCreated = $evt.TimeCreated
        RecordId    = $evt.RecordId
        EventId     = $evt.Id
        Category    = if ($evt.Id -in $packetDropIds) { 'Filtering Platform Packet Drop' } else { 'Filtering Platform Connection' }
        AuditResult = $auditResult
        Executable  = $app
        Direction   = $data['Direction']
        SourceIP    = $data['SourceAddress']
        SourcePort  = $data['SourcePort']
        DestIP      = $data['DestAddress']
        DestPort    = $data['DestPort']
        Protocol    = $data['Protocol']
    }
}

# Build the distinct-executable summary once; reuse for console + CSV.
$summary = $results |
    Where-Object { $_.Executable } |
    Group-Object Category, Executable, AuditResult |
    ForEach-Object {
        $latest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [pscustomobject]@{
            Category     = $_.Values[0]
            Executable   = $_.Values[1]
            AuditResult  = $_.Values[2]
            Count        = $_.Count
            LastSeen     = $latest.TimeCreated
            LastEventId  = $latest.EventId
            LastRecordId = $latest.RecordId
        }
    } |
    Sort-Object Category, LastSeen -Descending

Write-Host "`n=== Distinct executables (all categories) ===" -ForegroundColor Cyan
$summary |
    Group-Object Executable, AuditResult |
    ForEach-Object {
        $latest = $_.Group | Sort-Object LastSeen -Descending | Select-Object -First 1
        [pscustomobject]@{
            Executable   = $_.Values[0]
            AuditResult  = $_.Values[1]
            Count        = ($_.Group | Measure-Object Count -Sum).Sum
            LastSeen     = $latest.LastSeen
            LastEventId  = $latest.LastEventId
            LastRecordId = $latest.LastRecordId
        }
    } |
    Sort-Object LastSeen -Descending |
    Format-Table -AutoSize

Write-Host "`n=== Distinct executables by category ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if ($CsvPath) {
    $summary |
        Select-Object Category, Executable, AuditResult, Count,
            @{N='LastSeen';E={ Format-TimeForCsv $_.LastSeen }},
            LastEventId, LastRecordId |
        Export-Csv -Path $CsvPath -NoTypeInformation
    Write-Host "Distinct-executable summary exported to $CsvPath" -ForegroundColor Green
}

if ($AllEventsCsvPath) {
    $results |
        Select-Object @{N='TimeCreated';E={ Format-TimeForCsv $_.TimeCreated }}, * -ExcludeProperty TimeCreated |
        Export-Csv -Path $AllEventsCsvPath -NoTypeInformation
    Write-Host "All individual events exported to $AllEventsCsvPath" -ForegroundColor Green
}
