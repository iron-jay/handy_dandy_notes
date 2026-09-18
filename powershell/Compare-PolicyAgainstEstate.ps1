<#
.SYNOPSIS
    Takes one policy, lists every setting it defines, and reports for each whether any
    policy in the other estate also sets it - and to what value.

.DESCRIPTION
    The estate-wide matrix tells you the overall shape of a merge. This is the view you
    want when working through it one profile at a time: "here is what GUF-Windows-Baseline
    sets, and here is where each of those settings already lives on the DOR side."

    Each setting is classified:
      Match           set in the other estate with the same value
      Differs         set in the other estate with a different value
      Split           set in more than one policy in the other estate
      Not in <estate> nothing in the other estate sets it

.PARAMETER PolicyName
    The source policy. Exact name, or a fragment - if several match you get the list.

.PARAMETER TheirsPrefix
    Literal name prefix for the estate to check against. Default '[dor]'.
    Literal, so square brackets are safe.

.PARAMETER TheirsFilter
    Wildcard alternative to -TheirsPrefix, PowerShell -like syntax.

.PARAMETER DifferencesOnly
    Console output shows only Differs, Split and Not-in rows. The CSV is always complete.

.PARAMETER OutputPath
    Optional. Folder to write a CSV of the full result.

.EXAMPLE
    Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All
    .\Compare-PolicyAgainstEstate.ps1 -PolicyName 'guf-win11-security-baseline'

.EXAMPLE
    .\Compare-PolicyAgainstEstate.ps1 -PolicyName 'guf-bitlocker' -DifferencesOnly -OutputPath .\merge

.NOTES
    PowerShell 7+, Microsoft.Graph.Authentication. Read-only.
    Activate your Intune role in PIM first or the policy list returns empty.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PolicyName,
    [string]$TheirsPrefix = '[dor]',
    [string]$TheirsFilter,
    [string]$TheirsLabel = 'DOR',
    [switch]$DifferencesOnly,
    [switch]$FriendlyNames,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ---

function Test-Key {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    return ($null -ne $Object.PSObject.Properties[$Key])
}

function Get-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri)
    $results = @()
    $next = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable
        if (Test-Key $page 'value') { $results += $page.value } else { $results += $page }
        $next = if (Test-Key $page '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
    }
    # leading comma keeps an empty array from unrolling to $null.
    # never wrap a call to this in @() - that nests the array one level too deep.
    return , $results
}

function Get-SettingValue {
    param($SettingValue)
    if ($null -eq $SettingValue) { return '' }
    $type = if (Test-Key $SettingValue '@odata.type') { $SettingValue.'@odata.type' } else { '' }
    if ($type -match 'Secret') { return '<secret:redacted>' }
    if (Test-Key $SettingValue 'value') { return [string]$SettingValue.value }
    return ''
}

function ConvertTo-FlatSetting {
    param($Instance, [string]$Prefix = '')

    $out = [System.Collections.Generic.List[object]]::new()
    $did = if (Test-Key $Instance 'settingDefinitionId') { $Instance.settingDefinitionId } else { '<unknown>' }
    $path = if ($Prefix) { "$Prefix/$did" } else { $did }

    if (Test-Key $Instance 'simpleSettingValue') {
        $out.Add([pscustomobject]@{ Path = $path; Value = [string](Get-SettingValue $Instance.simpleSettingValue) })
    }
    elseif (Test-Key $Instance 'choiceSettingValue') {
        $cv = $Instance.choiceSettingValue
        $out.Add([pscustomobject]@{ Path = $path; Value = [string]$cv.value })
        if (Test-Key $cv 'children') {
            foreach ($child in $cv.children) {
                foreach ($r in (ConvertTo-FlatSetting -Instance $child -Prefix $path)) { $out.Add($r) }
            }
        }
    }
    elseif (Test-Key $Instance 'simpleSettingCollectionValue') {
        $vals = @($Instance.simpleSettingCollectionValue | ForEach-Object { [string](Get-SettingValue $_) } | Sort-Object)
        $out.Add([pscustomobject]@{ Path = $path; Value = '[' + ($vals -join '; ') + ']' })
    }
    elseif (Test-Key $Instance 'choiceSettingCollectionValue') {
        foreach ($cv in $Instance.choiceSettingCollectionValue) {
            $out.Add([pscustomobject]@{ Path = $path; Value = [string]$cv.value })
            if (Test-Key $cv 'children') {
                foreach ($child in $cv.children) {
                    foreach ($r in (ConvertTo-FlatSetting -Instance $child -Prefix $path)) { $out.Add($r) }
                }
            }
        }
    }
    elseif (Test-Key $Instance 'groupSettingCollectionValue') {
        $members = @()
        foreach ($member in $Instance.groupSettingCollectionValue) {
            $sub = [System.Collections.Generic.List[object]]::new()
            if (Test-Key $member 'children') {
                foreach ($child in $member.children) {
                    foreach ($r in (ConvertTo-FlatSetting -Instance $child -Prefix '')) { $sub.Add($r) }
                }
            }
            $sorted = @($sub | Sort-Object Path, Value)
            $members += , [pscustomobject]@{
                Rows = $sorted
                Key  = (($sorted | ForEach-Object { "$($_.Path)=$($_.Value)" }) -join '|')
            }
        }
        $i = 0
        foreach ($member in ($members | Sort-Object Key)) {
            $i++
            foreach ($row in $member.Rows) {
                $out.Add([pscustomobject]@{ Path = "$path[$i]/$($row.Path)"; Value = $row.Value })
            }
        }
    }
    else {
        $out.Add([pscustomobject]@{ Path = $path; Value = '<unparsed instance type>' })
    }

    return $out
}

# --- settings catalog definition registry -----------------------------------
# Populated from $expand=settingDefinitions. Maps settingDefinitionId to its
# display name, and for choice settings to its option display names.
$script:DefMap = @{}

function Register-SettingDefinitions {
    param($Definitions)
    foreach ($d in $Definitions) {
        if (-not (Test-Key $d 'id')) { continue }
        $id = [string]$d.id
        if ($script:DefMap.ContainsKey($id)) { continue }

        $display = if ((Test-Key $d 'displayName') -and $d.displayName) { [string]$d.displayName }
        elseif ((Test-Key $d 'name') -and $d.name) { [string]$d.name }
        else { $id }

        $options = @{}
        if (Test-Key $d 'options') {
            foreach ($o in $d.options) {
                $itemId = if (Test-Key $o 'itemId') { [string]$o.itemId } else { '' }
                $oName = if ((Test-Key $o 'displayName') -and $o.displayName) { [string]$o.displayName }
                elseif (Test-Key $o 'name') { [string]$o.name }
                else { $itemId }
                if ($itemId) { $options[$itemId] = $oName }
            }
        }
        $script:DefMap[$id] = @{ DisplayName = $display; Options = $options }
    }
}

function Split-SettingSegment {
    param([string]$Segment)
    if ($Segment -match '^(.*)\[(\d+)\]$') {
        return @{ Id = $Matches[1]; Index = "[$($Matches[2])]" }
    }
    return @{ Id = $Segment; Index = '' }
}

function ConvertTo-FriendlyPath {
    param([string]$Path)
    $parts = foreach ($segment in ($Path -split '/')) {
        $bits = Split-SettingSegment -Segment $segment
        $name = if ($script:DefMap.ContainsKey($bits.Id)) { $script:DefMap[$bits.Id].DisplayName } else { $bits.Id }
        "$name$($bits.Index)"
    }
    return ($parts -join ' > ')
}

function ConvertTo-FriendlyValue {
    param([string]$Path, [string]$Value)
    if (-not $Value) { return $Value }
    $segments = @($Path -split '/')
    $bits = Split-SettingSegment -Segment $segments[-1]
    if (-not $script:DefMap.ContainsKey($bits.Id)) { return $Value }
    $options = $script:DefMap[$bits.Id].Options
    if ($options -and $options.ContainsKey($Value)) { return $options[$Value] }
    return $Value
}

function Get-PolicySettings {
    param([Parameter(Mandatory)]$Policy, [switch]$FriendlyNames)
    $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($Policy.id)')/settings"
    if ($FriendlyNames) { $uri += "?`$expand=settingDefinitions" }
    $settings = Get-GraphPaged -Uri $uri
    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($setting in $settings) {
        if (Test-Key $setting 'settingDefinitions') { Register-SettingDefinitions $setting.settingDefinitions }
        $instance = if (Test-Key $setting 'settingInstance') { $setting.settingInstance } else { $setting }
        foreach ($row in (ConvertTo-FlatSetting -Instance $instance)) { $flat.Add($row) }
    }
    return , $flat
}

# ------------------------------------------------------------------- main ---

Write-Host 'Reading policy list...' -ForegroundColor Cyan
$allPolicies = Get-GraphPaged -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name,platforms'

# --- resolve the source policy
$exact = @($allPolicies | Where-Object { $_.name -eq $PolicyName })
$source = if ($exact.Count -eq 1) { $exact[0] } else {
    $partial = @($allPolicies | Where-Object { $_.name -like "*$PolicyName*" })
    if ($partial.Count -eq 1) { $partial[0] }
    elseif ($partial.Count -eq 0) { $null }
    else {
        Write-Host "`n'$PolicyName' matched $($partial.Count) policies - be more specific:" -ForegroundColor Yellow
        $partial | ForEach-Object { Write-Host "  $($_.name)" }
        return
    }
}
if (-not $source) {
    Write-Host "`nNo policy matched '$PolicyName'." -ForegroundColor Red
    return
}

# --- resolve the comparison estate
if ($TheirsFilter) {
    $theirs = @($allPolicies | Where-Object { $_.name -like $TheirsFilter })
    $criteria = "names like '$TheirsFilter'"
}
else {
    # literal: -like would read [ ] as a character class
    $theirs = @($allPolicies | Where-Object { $_.name.StartsWith($TheirsPrefix, [StringComparison]::OrdinalIgnoreCase) })
    $criteria = "names starting '$TheirsPrefix'"
}
$theirs = @($theirs | Where-Object { $_.id -ne $source.id })

Write-Host "Source   : $($source.name)" -ForegroundColor White
Write-Host "Compared : $($theirs.Count) ${TheirsLabel} policies ($criteria)"
if ($theirs.Count -eq 0) {
    Write-Host "`nNothing to compare against." -ForegroundColor Red
    return
}

# --- flatten the source
$sourceFlat = Get-PolicySettings -Policy $source -FriendlyNames:$FriendlyNames
Write-Host "`n$($source.name) defines $($sourceFlat.Count) settings." -ForegroundColor Cyan

# --- index the other estate
$theirsIndex = @{}
foreach ($p in $theirs) {
    Write-Host "  reading $($p.name)..."
    foreach ($row in (Get-PolicySettings -Policy $p -FriendlyNames:$FriendlyNames)) {
        if (-not $theirsIndex.ContainsKey($row.Path)) {
            $theirsIndex[$row.Path] = [System.Collections.Generic.List[object]]::new()
        }
        $theirsIndex[$row.Path].Add([pscustomobject]@{ Policy = $p.name; Value = $row.Value })
    }
}

# --- classify each source setting
$report = [System.Collections.Generic.List[object]]::new()
foreach ($row in ($sourceFlat | Sort-Object Path)) {
    $hits = if ($theirsIndex.ContainsKey($row.Path)) { $theirsIndex[$row.Path] } else { $null }
    $hitVals = @(if ($hits) { $hits | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object })

    $status =
    if (-not $hits -or $hitVals.Count -eq 0) { "Not in ${TheirsLabel}" }
    elseif ($hits.Count -gt 1) {
        # a split is only benign if every copy agrees with the source
        if ($hitVals.Count -gt 1 -or $hitVals[0] -ne $row.Value) { 'Split - differs' } else { 'Split' }
    }
    elseif ($hitVals[0] -eq $row.Value) { 'Match' }
    else { 'Differs' }

    $showVals = if ($FriendlyNames) { @($hitVals | ForEach-Object { ConvertTo-FriendlyValue -Path $row.Path -Value $_ }) } else { $hitVals }
    $showSource = if ($FriendlyNames) { ConvertTo-FriendlyValue -Path $row.Path -Value $row.Value } else { $row.Value }

    $rowData = [ordered]@{ Setting = $row.Path }
    if ($FriendlyNames) { $rowData['Setting name'] = ConvertTo-FriendlyPath -Path $row.Path }
    $rowData['Source value'] = $showSource
    $rowData['Status'] = $status
    $rowData["$TheirsLabel value"] = ($showVals -join ' || ')
    $rowData["$TheirsLabel policy"] = if ($hits) { (($hits | ForEach-Object { $_.Policy } | Select-Object -Unique) -join '; ') } else { '' }
    $report.Add([pscustomobject]$rowData)
}

# --- console output
$order = @('Differs', 'Split - differs', 'Split', "Not in ${TheirsLabel}", 'Match')
$colour = @{
    'Differs'              = 'Red'
    'Split - differs'      = 'Red'
    'Split'                = 'Yellow'
    "Not in ${TheirsLabel}" = 'Cyan'
    'Match'                = 'Green'
}

foreach ($status in $order) {
    $group = @($report | Where-Object Status -eq $status)
    if ($group.Count -eq 0) { continue }
    if ($DifferencesOnly -and $status -eq 'Match') { continue }

    Write-Host "`n$status ($($group.Count))" -ForegroundColor $colour[$status]
    Write-Host ('-' * 60)
    foreach ($r in $group) {
        $theirValue = $r.($TheirsLabel + ' value')
        $theirPolicy = $r.($TheirsLabel + ' policy')
        if ($FriendlyNames) {
            Write-Host "  $($r.'Setting name')"
            Write-Host "      id: $($r.Setting)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  $($r.Setting)"
        }
        Write-Host "      source: $($r.'Source value')"
        if ($status -ne "Not in ${TheirsLabel}") {
            Write-Host "      ${TheirsLabel}: $theirValue  [$theirPolicy]"
        }
    }
}

# --- summary
$matched = @($report | Where-Object { $_.Status -ne "Not in ${TheirsLabel}" }).Count
$differing = @($report | Where-Object { $_.Status -in @('Differs', 'Split - differs') }).Count
$unique = @($report | Where-Object Status -eq "Not in ${TheirsLabel}").Count

Write-Host "`n$('=' * 60)"
Write-Host "$($source.name)" -ForegroundColor White
Write-Host "  $($report.Count) settings defined"
Write-Host "  $matched also set somewhere in ${TheirsLabel}, of which $differing disagree"
Write-Host "  $unique not set anywhere in ${TheirsLabel}"

if ($OutputPath) {
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $safe = ($source.name -replace '[\\/:*?"<>|\[\]]', '_')
    $csv = Join-Path $OutputPath "$safe-vs-${TheirsLabel}.csv"
    $report | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8
    Write-Host "`nCSV: $csv" -ForegroundColor Green
}
