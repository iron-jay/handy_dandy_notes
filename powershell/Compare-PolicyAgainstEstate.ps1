<#
.SYNOPSIS
    Takes a CSV list of source policies and compares each one, setting by setting,
    against a CSV-defined target estate.

.DESCRIPTION
    The per-policy drill-down answers "where does this one policy's content live on the
    other side". This runs that same comparison across a whole list - feed it your [DOR]
    policies and your guf policies and it walks every DOR policy in turn.

    The target estate is read once and indexed, then reused for every source policy, so
    the cost is one pass over each estate regardless of how many comparisons you run.

    Each setting in each source policy is classified:
      Match            set in the target estate with the same value
      Differs          set in the target estate with a different value
      Split            set in more than one target policy, all agreeing with the source
      Split - differs  set in more than one target policy, and they disagree
      Not in <target>  nothing in the target estate sets it

    Outputs, written to -OutputPath:
      rollup.csv            one row per source policy: counts and coverage %
      all-settings.csv      every setting from every source policy, with its verdict
      per-policy\<name>.csv the same rows split by source policy

.PARAMETER SourceListCsv
    CSV of the policies to walk through (the [DOR] side). Needs a PolicyName or PolicyId
    column; a single-column file is treated as names.

.PARAMETER TargetListCsv
    CSV of the estate to compare against (the guf side). Same format.

.PARAMETER Detailed
    Print every setting to the console as it goes. Off by default - with a long source
    list the console output is unreadable and the CSVs are the real deliverable.

.EXAMPLE
    Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All
    .\Compare-PolicySetAgainstEstate.ps1 -SourceListCsv .\dor.csv -TargetListCsv .\guf.csv `
        -SourceLabel DOR -TargetLabel GUF -FriendlyNames -OutputPath .\merge

.NOTES
    PowerShell 7+, Microsoft.Graph.Authentication. Read-only.
    Activate your Intune role in PIM first or the policy list returns empty.
    Both CSVs can be produced by running the estate script with -Mode Template and
    splitting the result, or written by hand with a single PolicyName column.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceListCsv,
    [Parameter(Mandatory)][string]$TargetListCsv,

    [string]$SourceLabel = 'DOR',
    [string]$TargetLabel = 'GUF',

    [switch]$FriendlyNames,
    [switch]$Detailed,

    [string]$OutputPath = '.\merge'
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

# --- settings catalog definition registry -----------------------------------
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

<#
    Reads a policy list CSV. Uses PolicyId where present, else PolicyName. A file with a
    single column of any name is treated as a list of policy names, so a hand-written
    one-column CSV works without ceremony.
#>
function Get-PolicyNameList {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

    if (-not (Test-Path $Path)) {
        Write-Host "[$Label] list not found: $Path" -ForegroundColor Red
        return $null
    }
    $rows = @(Import-Csv -Path $Path)
    if ($rows.Count -eq 0) {
        Write-Host "[$Label] list is empty: $Path" -ForegroundColor Red
        return $null
    }

    $columns = @($rows[0].PSObject.Properties.Name)
    $nameCol = if ($columns -contains 'PolicyName') { 'PolicyName' }
    elseif ($columns.Count -eq 1) { $columns[0] }
    else { $null }
    $idCol = if ($columns -contains 'PolicyId') { 'PolicyId' } else { $null }

    if (-not $nameCol -and -not $idCol) {
        Write-Host "[$Label] $Path needs a PolicyName or PolicyId column." -ForegroundColor Red
        return $null
    }

    $names = [System.Collections.Generic.List[string]]::new()
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $rows) {
        $id = if ($idCol) { ([string]$row.$idCol).Trim() } else { '' }
        $name = if ($nameCol) { ([string]$row.$nameCol).Trim() } else { '' }
        if ($id) { $ids.Add($id) }
        elseif ($name) { $names.Add($name) }
    }
    if ($names.Count -eq 0 -and $ids.Count -eq 0) {
        Write-Host "[$Label] no usable rows in $Path." -ForegroundColor Red
        return $null
    }
    return @{ Names = $names; Ids = $ids }
}

<# Resolves a name/id list against the tenant's policies, warning on anything missing. #>
function Resolve-Policies {
    param($AllPolicies, $List, [Parameter(Mandatory)][string]$Label)

    $wantedIds = @{}
    foreach ($i in $List.Ids) { $wantedIds[$i] = $true }
    $wantedNames = @{}
    foreach ($n in $List.Names) { $wantedNames[$n.ToLowerInvariant()] = $true }

    $matched = @($AllPolicies | Where-Object {
            $wantedIds.ContainsKey([string]$_.id) -or
            $wantedNames.ContainsKey(([string]$_.name).Trim().ToLowerInvariant())
        })

    $foundIds = @{}
    $foundNames = @{}
    foreach ($p in $matched) {
        $foundIds[[string]$p.id] = $true
        $foundNames[([string]$p.name).Trim().ToLowerInvariant()] = $true
    }
    foreach ($i in $List.Ids) {
        if (-not $foundIds.ContainsKey($i)) { Write-Warning "[$Label] no policy with id '$i'." }
    }
    foreach ($n in $List.Names) {
        if (-not $foundNames.ContainsKey($n.ToLowerInvariant())) { Write-Warning "[$Label] no policy named '$n'." }
    }
    return , $matched
}

# ------------------------------------------------------------------- main ---

$sourceList = Get-PolicyNameList -Path $SourceListCsv -Label $SourceLabel
if (-not $sourceList) { return }
$targetList = Get-PolicyNameList -Path $TargetListCsv -Label $TargetLabel
if (-not $targetList) { return }

Write-Host 'Reading policy list...' -ForegroundColor Cyan
$allPolicies = Get-GraphPaged -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name,platforms'

$sourcePolicies = Resolve-Policies -AllPolicies $allPolicies -List $sourceList -Label $SourceLabel
$targetPolicies = Resolve-Policies -AllPolicies $allPolicies -List $targetList -Label $TargetLabel

Write-Host "${SourceLabel}: $($sourcePolicies.Count) policies to walk"
Write-Host "${TargetLabel}: $($targetPolicies.Count) policies to compare against"
if ($sourcePolicies.Count -eq 0 -or $targetPolicies.Count -eq 0) {
    Write-Host "`nBoth sides need at least one policy." -ForegroundColor Red
    return
}

# --- index the target estate once, then reuse it for every source policy
Write-Host "`nIndexing ${TargetLabel}..." -ForegroundColor Cyan
$targetIndex = @{}
foreach ($p in $targetPolicies) {
    Write-Host "  $($p.name)"
    foreach ($row in (Get-PolicySettings -Policy $p -FriendlyNames:$FriendlyNames)) {
        if (-not $targetIndex.ContainsKey($row.Path)) {
            $targetIndex[$row.Path] = [System.Collections.Generic.List[object]]::new()
        }
        $targetIndex[$row.Path].Add([pscustomobject]@{ Policy = $p.name; Value = $row.Value })
    }
}
Write-Host "  $($targetIndex.Count) distinct settings indexed"

$notInLabel = "Not in ${TargetLabel}"

# --- walk the source policies
$allRows = [System.Collections.Generic.List[object]]::new()
$rollup = [System.Collections.Generic.List[object]]::new()

$perPolicyDir = Join-Path $OutputPath 'per-policy'
if (-not (Test-Path $perPolicyDir)) { New-Item -ItemType Directory -Path $perPolicyDir -Force | Out-Null }

Write-Host "`nComparing ${SourceLabel} policies..." -ForegroundColor Cyan
foreach ($sp in ($sourcePolicies | Sort-Object { $_.name })) {

    $sourceFlat = Get-PolicySettings -Policy $sp -FriendlyNames:$FriendlyNames
    $policyRows = [System.Collections.Generic.List[object]]::new()

    foreach ($row in ($sourceFlat | Sort-Object Path)) {
        $hits = if ($targetIndex.ContainsKey($row.Path)) { $targetIndex[$row.Path] } else { $null }
        $hitVals = @(if ($hits) { $hits | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object })

        $status =
        if (-not $hits -or $hitVals.Count -eq 0) { $notInLabel }
        elseif ($hits.Count -gt 1) {
            if ($hitVals.Count -gt 1 -or $hitVals[0] -ne $row.Value) { 'Split - differs' } else { 'Split' }
        }
        elseif ($hitVals[0] -eq $row.Value) { 'Match' }
        else { 'Differs' }

        $showVals = if ($FriendlyNames) { @($hitVals | ForEach-Object { ConvertTo-FriendlyValue -Path $row.Path -Value $_ }) } else { $hitVals }
        $showSource = if ($FriendlyNames) { ConvertTo-FriendlyValue -Path $row.Path -Value $row.Value } else { $row.Value }

        $rowData = [ordered]@{ "$SourceLabel policy" = $sp.name; Setting = $row.Path }
        if ($FriendlyNames) { $rowData['Setting name'] = ConvertTo-FriendlyPath -Path $row.Path }
        $rowData["$SourceLabel value"] = $showSource
        $rowData['Status'] = $status
        $rowData["$TargetLabel value"] = ($showVals -join ' || ')
        $rowData["$TargetLabel policy"] = if ($hits) { (($hits | ForEach-Object { $_.Policy } | Select-Object -Unique) -join '; ') } else { '' }
        $rowData['Merge decision'] = ''

        $obj = [pscustomobject]$rowData
        $policyRows.Add($obj)
        $allRows.Add($obj)
    }

    $total = $policyRows.Count
    $match = @($policyRows | Where-Object Status -eq 'Match').Count
    $differs = @($policyRows | Where-Object Status -eq 'Differs').Count
    $split = @($policyRows | Where-Object { $_.Status -like 'Split*' }).Count
    $missing = @($policyRows | Where-Object Status -eq $notInLabel).Count
    $covered = $total - $missing
    $coverage = if ($total -gt 0) { [math]::Round(100 * $covered / $total, 1) } else { 0 }

    $rollup.Add([pscustomobject][ordered]@{
            "$SourceLabel policy"  = $sp.name
            Settings               = $total
            Match                  = $match
            Differs                = $differs
            Split                  = $split
            "$notInLabel"          = $missing
            'Coverage %'           = $coverage
        })

    $colour = if ($differs -gt 0) { 'Red' } elseif ($missing -eq $total) { 'Cyan' } else { 'Green' }
    Write-Host ("  {0,-45} {1,4} settings  {2,3}% covered  {3} differ" -f $sp.name, $total, $coverage, $differs) -ForegroundColor $colour

    if ($Detailed) {
        foreach ($r in ($policyRows | Where-Object { $_.Status -ne 'Match' })) {
            $label = if ($FriendlyNames) { $r.'Setting name' } else { $r.Setting }
            Write-Host "      [$($r.Status)] $label"
        }
    }

    $safe = ($sp.name -replace '[\\/:*?"<>|\[\]]', '_')
    $policyRows | Export-Csv -Path (Join-Path $perPolicyDir "$safe.csv") -NoTypeInformation -Encoding utf8
}

# --- outputs
$allRows | Export-Csv -Path (Join-Path $OutputPath 'all-settings.csv') -NoTypeInformation -Encoding utf8
$rollup | Sort-Object 'Coverage %' | Export-Csv -Path (Join-Path $OutputPath 'rollup.csv') -NoTypeInformation -Encoding utf8

Write-Host "`n$('=' * 70)"
$rollup | Sort-Object 'Coverage %' | Format-Table -AutoSize

$totalSettings = $allRows.Count
$totalDiffers = @($allRows | Where-Object { $_.Status -in @('Differs', 'Split - differs') }).Count
$totalMissing = @($allRows | Where-Object Status -eq $notInLabel).Count

Write-Host "$totalSettings settings across $($sourcePolicies.Count) ${SourceLabel} policies"
Write-Host "  $totalDiffers disagree with ${TargetLabel}"
Write-Host "  $totalMissing not set anywhere in ${TargetLabel}"
Write-Host "`nWritten to $OutputPath" -ForegroundColor Green
