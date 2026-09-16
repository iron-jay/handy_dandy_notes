<#
.SYNOPSIS
    Compares two estates of Intune Settings Catalog policies at settingDefinitionId level
    and produces a merge-planning workbook: what is set, where it is set, and where the
    two estates disagree.

.DESCRIPTION
    Built for the case where you inherit configuration profiles from another team and need
    to roll them into a single common set alongside your own.

    Every policy in an estate is flattened into (settingPath -> value) pairs, so the unit
    of comparison is the setting, not the profile. That is what lets you compare two
    estates that split settings across profiles differently.

    Outputs, written to -OutputPath:
      settings-matrix.csv   one row per setting: verdict, both values, source policies
      duplicates.csv        settings defined in more than one policy in the SAME estate
      policy-overlap.csv    per-policy-pair overlap counts - use this to shape the merge
      summary.html          the matrix, colour-coded, with drag-resizable columns

.EXAMPLE
    # Both estates in one tenant, matched on literal name prefixes
    Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All, Group.Read.All
    .\Compare-IntuneSettingsEstate.ps1 -OursPrefix 'guf' -OursLabel GUF `
        -TheirsPrefix '[dor]' -TheirsLabel DOR -IncludeAssignments -OutputPath .\merge

.EXAMPLE
    # Estates in different tenants: export one, then compare
    .\Compare-IntuneSettingsEstate.ps1 -Mode Export -OursFilter '*' -OutputPath .\theirs
    .\Compare-IntuneSettingsEstate.ps1 -OursPrefix 'guf' -TheirsPath .\theirs -OutputPath .\merge

.NOTES
    PowerShell 7+, Microsoft.Graph.Authentication. Read-only: never writes to Intune.
    Activate your Intune role in PIM first, or the policy list returns empty.
    Use -OursPrefix / -TheirsPrefix for literal matching. -OursFilter / -TheirsFilter use
    -like, where [ ] are character-class metacharacters: '[dor]*' matches names starting
    d, o or r, NOT names starting '[dor]'.
#>

[CmdletBinding()]
param(
    [ValidateSet('Export', 'Compare')]
    [string]$Mode = 'Compare',

    # literal prefix match (recommended - no wildcard parsing)
    [string]$OursPrefix,
    [string]$TheirsPrefix,

    # wildcard match, PowerShell -like syntax
    [string]$OursFilter,
    [string]$TheirsFilter,

    # folders of exported JSON, for cross-tenant comparison
    [string]$OursPath,
    [string]$TheirsPath,

    [switch]$IncludeAssignments,

    [string]$OutputPath = '.\intune-merge',
    [string]$OursLabel = 'Ours',
    [string]$TheirsLabel = 'Theirs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ---

<#
    Graph responses and ConvertFrom-Json -AsHashtable return different dictionary types
    depending on PowerShell version and code path: Hashtable, OrderedDictionary, or
    OrderedHashtable. Not all expose ContainsKey(), but all implement IDictionary, so
    test keys through Contains() instead.
#>
function Test-Key {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    return ($null -ne $Object.PSObject.Properties[$Key])
}

function Get-HtmlSafe {
    param([string]$Text)
    if (-not $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
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
    # leading comma prevents PowerShell unrolling an empty array to $null on return
    return , $results
}

$script:GroupNameCache = @{}
function Resolve-GroupName {
    param([string]$GroupId)
    if (-not $GroupId) { return '(unknown group)' }
    if ($script:GroupNameCache.ContainsKey($GroupId)) { return $script:GroupNameCache[$GroupId] }
    try {
        $g = Invoke-MgGraphRequest -Method GET -OutputType Hashtable `
            -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=displayName"
        $name = $g.displayName
    }
    catch { $name = $GroupId }   # no Group.Read.All, or the group is gone
    $script:GroupNameCache[$GroupId] = $name
    return $name
}

function Get-SettingValue {
    param($SettingValue)
    if ($null -eq $SettingValue) { return '' }
    $type = if (Test-Key $SettingValue '@odata.type') { $SettingValue.'@odata.type' } else { '' }
    if ($type -match 'Secret') { return '<secret:redacted>' }
    if (Test-Key $SettingValue 'value') { return [string]$SettingValue.value }
    return ''
}

<#
    Recursively flattens a settingInstance into objects with Path and Value.

    Group setting collections (firewall rules, Defender exclusions) are canonicalised:
    members are sorted by content before indexing, so two estates declaring the same
    rules in a different order do not register as differences.
#>
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

function Get-EstateFromGraph {
    param(
        [string]$Filter,
        [string]$Prefix,
        [Parameter(Mandatory)][string]$Label,
        [switch]$IncludeAssignments
    )

    $criteria = if ($Prefix) { "names starting '$Prefix'" } else { "names like '$Filter'" }
    Write-Host "[$Label] reading policies from tenant..." -ForegroundColor Cyan
    $policies = Get-GraphPaged -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name,description,platforms,technologies,templateReference'

    if ($Prefix) {
        # literal match: -like would read [ ] as a character class
        $policies = @($policies | Where-Object { $_.name.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
    }
    else {
        $policies = @($policies | Where-Object { $_.name -like $Filter })
    }
    Write-Host "[$Label] $($policies.Count) policies matched $criteria"

    $estate = @()
    foreach ($p in $policies) {
        $settings = @(Get-GraphPaged -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($p.id)')/settings")

        $targets = @()
        if ($IncludeAssignments) {
            try {
                $assignments = @(Get-GraphPaged -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($p.id)')/assignments")
                foreach ($a in $assignments) {
                    $t = $a.target
                    $odata = if (Test-Key $t '@odata.type') { $t.'@odata.type' } else { '' }
                    $name = switch -Wildcard ($odata) {
                        '*allDevicesAssignmentTarget' { 'All devices' }
                        '*allLicensedUsersAssignmentTarget' { 'All users' }
                        '*exclusionGroupAssignmentTarget' { 'EXCLUDE-' + (Resolve-GroupName $t.groupId) }
                        '*groupAssignmentTarget' { Resolve-GroupName $t.groupId }
                        default { $odata }
                    }
                    if ((Test-Key $t 'deviceAndAppManagementAssignmentFilterId') -and $t.deviceAndAppManagementAssignmentFilterId) {
                        $name += " (filtered - $($t.deviceAndAppManagementAssignmentFilterType))"
                    }
                    $targets += $name
                }
            }
            catch {
                Write-Warning "  could not read assignments for '$($p.name)' - $($_.Exception.Message)"
            }
        }

        # plain @{}, not [ordered]@{} - OrderedDictionary has no ContainsKey()
        $estate += , @{
            id          = $p.id
            name        = $p.name
            description = if (Test-Key $p 'description') { $p.description } else { '' }
            platforms   = if (Test-Key $p 'platforms') { $p.platforms } else { '' }
            assignments = $targets
            settings    = $settings
        }
        $assignText = if ($targets.Count) { " -> $($targets -join ', ')" } else { '' }
        Write-Host "  - $($p.name) ($($settings.Count) top-level settings)$assignText"
    }
    return , $estate
}

function Get-EstateFromDisk {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

    $files = @(Get-ChildItem -Path $Path -Filter '*.json' -File)
    Write-Host "[$Label] $($files.Count) JSON files in $Path" -ForegroundColor Cyan
    $estate = @()
    foreach ($f in $files) {
        $json = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json -AsHashtable
        if ($json -is [System.Collections.IList]) { foreach ($p in $json) { $estate += , $p } }
        elseif (Test-Key $json 'value') { foreach ($p in $json.value) { $estate += , $p } }
        else {
            if (-not (Test-Key $json 'name')) { $json['name'] = $f.BaseName }
            $estate += , $json
        }
    }
    return , $estate
}

<# Flattens an estate into an index: settingPath -> list of @{Policy;Value} #>
function ConvertTo-EstateIndex {
    param($Estate)
    $index = @{}
    foreach ($policy in $Estate) {
        if (-not (Test-Key $policy 'settings')) {
            $who = if (Test-Key $policy 'name') { $policy.name } else { 'unnamed policy' }
            Write-Warning "Skipping '$who' - no settings array found."
            continue
        }
        foreach ($setting in $policy.settings) {
            $instance = if (Test-Key $setting 'settingInstance') { $setting.settingInstance } else { $setting }
            foreach ($row in (ConvertTo-FlatSetting -Instance $instance)) {
                if (-not $index.ContainsKey($row.Path)) {
                    $index[$row.Path] = [System.Collections.Generic.List[object]]::new()
                }
                $index[$row.Path].Add([pscustomobject]@{ Policy = $policy.name; Value = $row.Value })
            }
        }
    }
    return $index
}

function Format-Cell {
    param($Entries)
    if (-not $Entries) { return '' }
    return (($Entries | ForEach-Object { $_.Value } | Select-Object -Unique) -join ' || ')
}

function Format-Sources {
    param($Entries)
    if (-not $Entries) { return '' }
    return (($Entries | ForEach-Object { $_.Policy } | Select-Object -Unique) -join '; ')
}

# ------------------------------------------------------------------- main ---

if ($OursLabel -eq $TheirsLabel) {
    Write-Host 'OursLabel and TheirsLabel must differ - they become column names.' -ForegroundColor Red
    return
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

if ($Mode -eq 'Export') {
    if (-not ($OursFilter -or $OursPrefix)) {
        Write-Host "Export needs -OursPrefix or -OursFilter (use '*' for everything)." -ForegroundColor Red
        return
    }
    $estate = @(Get-EstateFromGraph -Filter $OursFilter -Prefix $OursPrefix -Label 'Export' -IncludeAssignments:$IncludeAssignments)
    foreach ($p in $estate) {
        $safe = ($p.name -replace '[\\/:*?"<>|]', '_')
        $p | ConvertTo-Json -Depth 40 | Set-Content -Path (Join-Path $OutputPath "$safe.json") -Encoding utf8
    }
    Write-Host "`nExported $($estate.Count) policies to $OutputPath" -ForegroundColor Green
    return
}

# --- load both estates
if ($OursPath) { $oursEstate = Get-EstateFromDisk -Path $OursPath -Label $OursLabel }
elseif ($OursFilter -or $OursPrefix) { $oursEstate = Get-EstateFromGraph -Filter $OursFilter -Prefix $OursPrefix -Label $OursLabel -IncludeAssignments:$IncludeAssignments }
else {
    Write-Host 'No source for the first estate. Specify -OursPrefix, -OursFilter or -OursPath.' -ForegroundColor Red
    return
}

if ($TheirsPath) { $theirsEstate = Get-EstateFromDisk -Path $TheirsPath -Label $TheirsLabel }
elseif ($TheirsFilter -or $TheirsPrefix) { $theirsEstate = Get-EstateFromGraph -Filter $TheirsFilter -Prefix $TheirsPrefix -Label $TheirsLabel -IncludeAssignments:$IncludeAssignments }
else {
    Write-Host 'No source for the second estate. Specify -TheirsPrefix, -TheirsFilter or -TheirsPath.' -ForegroundColor Red
    return
}

$oursEstate = @($oursEstate)
$theirsEstate = @($theirsEstate)

# --- policy -> assignment targets, for judging whether a conflict is live
$assignmentByPolicy = @{}
foreach ($p in ($oursEstate + $theirsEstate)) {
    if ((Test-Key $p 'assignments') -and $p.assignments) { $assignmentByPolicy[$p.name] = @($p.assignments) }
}

$oursIndex = ConvertTo-EstateIndex -Estate $oursEstate
$theirsIndex = ConvertTo-EstateIndex -Estate $theirsEstate

# --- build the matrix
$allPaths = @($oursIndex.Keys) + @($theirsIndex.Keys) | Select-Object -Unique | Sort-Object
$matrix = [System.Collections.Generic.List[object]]::new()
$duplicates = [System.Collections.Generic.List[object]]::new()

foreach ($path in $allPaths) {
    $o = if ($oursIndex.ContainsKey($path)) { $oursIndex[$path] } else { $null }
    $t = if ($theirsIndex.ContainsKey($path)) { $theirsIndex[$path] } else { $null }

    # @() wraps the whole if-statement: an empty branch result would otherwise be $null
    $oVals = @(if ($o) { $o | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object })
    $tVals = @(if ($t) { $t | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object })

    $notes = @()
    if ($o -and $o.Count -gt 1) {
        $notes += "set in $($o.Count) ${OursLabel} policies"
        $duplicates.Add([pscustomobject][ordered]@{
                Estate      = $OursLabel
                Setting     = $path
                Policies    = (Format-Sources $o)
                Values      = (Format-Cell $o)
                Conflicting = ($oVals.Count -gt 1)
            })
    }
    if ($t -and $t.Count -gt 1) {
        $notes += "set in $($t.Count) ${TheirsLabel} policies"
        $duplicates.Add([pscustomobject][ordered]@{
                Estate      = $TheirsLabel
                Setting     = $path
                Policies    = (Format-Sources $t)
                Values      = (Format-Cell $t)
                Conflicting = ($tVals.Count -gt 1)
            })
    }

    $verdict =
    if (-not $t) { "Only ${OursLabel}" }
    elseif (-not $o) { "Only ${TheirsLabel}" }
    elseif (($oVals -join '||') -eq ($tVals -join '||')) { 'Identical' }
    else { 'Value conflict' }

    # a value conflict only bites devices if both sides hit the same target
    $sharedTargets = ''
    if ($verdict -eq 'Value conflict' -and $assignmentByPolicy.Count -gt 0) {
        $oTargets = @($o | ForEach-Object { if ($assignmentByPolicy.ContainsKey($_.Policy)) { $assignmentByPolicy[$_.Policy] } } | Select-Object -Unique)
        $tTargets = @($t | ForEach-Object { if ($assignmentByPolicy.ContainsKey($_.Policy)) { $assignmentByPolicy[$_.Policy] } } | Select-Object -Unique)
        $both = @($oTargets | Where-Object { $tTargets -contains $_ -and $_ -notlike 'EXCLUDE-*' })
        if ($both.Count -gt 0) {
            $sharedTargets = ($both -join '; ')
            $verdict = 'LIVE conflict'
        }
    }

    $matrix.Add([pscustomobject][ordered]@{
            Setting               = $path
            Verdict               = $verdict
            "$OursLabel value"    = (Format-Cell $o)
            "$OursLabel policy"   = (Format-Sources $o)
            "$TheirsLabel value"  = (Format-Cell $t)
            "$TheirsLabel policy" = (Format-Sources $t)
            Notes                 = ($notes -join '; ')
            'Shared targets'      = $sharedTargets
            'Merge decision'      = ''
            'Target policy'       = ''
        })
}

# --- policy overlap: which of their policies map onto which of ours
$overlap = [System.Collections.Generic.List[object]]::new()
$oursByPolicy = @{}
foreach ($path in $oursIndex.Keys) {
    foreach ($e in $oursIndex[$path]) {
        if (-not $oursByPolicy.ContainsKey($e.Policy)) { $oursByPolicy[$e.Policy] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$oursByPolicy[$e.Policy].Add($path)
    }
}
$theirsByPolicy = @{}
foreach ($path in $theirsIndex.Keys) {
    foreach ($e in $theirsIndex[$path]) {
        if (-not $theirsByPolicy.ContainsKey($e.Policy)) { $theirsByPolicy[$e.Policy] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$theirsByPolicy[$e.Policy].Add($path)
    }
}
foreach ($tp in ($theirsByPolicy.Keys | Sort-Object)) {
    $theirSet = $theirsByPolicy[$tp]
    $matched = $false
    foreach ($op in ($oursByPolicy.Keys | Sort-Object)) {
        $shared = @($theirSet | Where-Object { $oursByPolicy[$op].Contains($_) })
        if ($shared.Count -gt 0) {
            $matched = $true
            $overlap.Add([pscustomobject][ordered]@{
                    "$TheirsLabel policy"   = $tp
                    "$TheirsLabel settings" = $theirSet.Count
                    "$OursLabel policy"     = $op
                    'Shared settings'       = $shared.Count
                    'Coverage of theirs %'  = [math]::Round(100 * $shared.Count / $theirSet.Count, 1)
                })
        }
    }
    if (-not $matched) {
        $overlap.Add([pscustomobject][ordered]@{
                "$TheirsLabel policy"   = $tp
                "$TheirsLabel settings" = $theirSet.Count
                "$OursLabel policy"     = '(no overlap - net new)'
                'Shared settings'       = 0
                'Coverage of theirs %'  = 0
            })
    }
}

# --- write outputs
$matrix | Export-Csv -Path (Join-Path $OutputPath 'settings-matrix.csv') -NoTypeInformation -Encoding utf8
$duplicates | Export-Csv -Path (Join-Path $OutputPath 'duplicates.csv') -NoTypeInformation -Encoding utf8
$overlap | Sort-Object 'Shared settings' -Descending | Export-Csv -Path (Join-Path $OutputPath 'policy-overlap.csv') -NoTypeInformation -Encoding utf8

$counts = $matrix | Group-Object Verdict | Sort-Object Name

$css = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b2a4a}
h1{color:#14284b;border-bottom:3px solid #2e5c9a;padding-bottom:6px}
h2{color:#2e5c9a;margin-top:28px}
table{border-collapse:collapse;width:100%;font-size:12px;margin-top:8px;table-layout:fixed}
th{background:#14284b;color:#fff;text-align:left;padding:6px;position:sticky;top:0}
th .grip{position:absolute;top:0;right:0;width:6px;height:100%;cursor:col-resize;user-select:none}
th:hover .grip{background:#4d7fc4}
td{border-bottom:1px solid #dde3ec;padding:5px;vertical-align:top;word-break:break-word}
tr:nth-child(even){background:#f5f8fc}
.v-identical{background:#e8f5e9}
.v-conflict{background:#fdecea}
.v-live{background:#f9636b;color:#fff;font-weight:600}
.v-ours{background:#fff8e1}
.v-theirs{background:#e7f0fb}
.k{font-weight:600}
.summary td{font-size:14px}
</style>
'@

$js = @'
<script>
document.querySelectorAll("th").forEach(function (th) {
  var grip = document.createElement("div");
  grip.className = "grip";
  th.appendChild(grip);
  var startX = 0, startW = 0;
  function move(e) { th.style.width = Math.max(60, startW + e.pageX - startX) + "px"; }
  function stop() {
    document.removeEventListener("mousemove", move);
    document.removeEventListener("mouseup", stop);
  }
  grip.addEventListener("mousedown", function (e) {
    startX = e.pageX; startW = th.offsetWidth;
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", stop);
    e.preventDefault();
  });
  grip.addEventListener("dblclick", function () { th.style.width = ""; });
});
</script>
'@

$rows = foreach ($r in $matrix) {
    $cls = switch ($r.Verdict) {
        'Identical' { 'v-identical' }
        'Value conflict' { 'v-conflict' }
        'LIVE conflict' { 'v-live' }
        default { if ($r.Verdict -like "Only $OursLabel*") { 'v-ours' } else { 'v-theirs' } }
    }
    $cSetting = Get-HtmlSafe $r.Setting
    $cOurVal = Get-HtmlSafe $r.($OursLabel + ' value')
    $cOurPol = Get-HtmlSafe $r.($OursLabel + ' policy')
    $cThrVal = Get-HtmlSafe $r.($TheirsLabel + ' value')
    $cThrPol = Get-HtmlSafe $r.($TheirsLabel + ' policy')
    $cShared = Get-HtmlSafe $r.'Shared targets'
    $cNotes = Get-HtmlSafe $r.Notes
    "<tr class='$cls'><td class='k'>$cSetting</td><td>$($r.Verdict)</td><td>$cOurVal</td><td>$cOurPol</td><td>$cThrVal</td><td>$cThrPol</td><td>$cShared</td><td>$cNotes</td></tr>"
}

$summaryRows = ($counts | ForEach-Object { "<tr><td>$($_.Name)</td><td><b>$($_.Count)</b></td></tr>" }) -join ''
$generated = Get-Date -Format 'dd MMM yyyy HH:mm'
$newline = "`n"

$html = @"
<html><head><meta charset='utf-8'>$css</head><body>
<h1>Intune settings catalog merge analysis</h1>
<p>Generated $generated &mdash; ${OursLabel}: $($oursEstate.Count) policies, $($oursIndex.Count) distinct settings &middot; ${TheirsLabel}: $($theirsEstate.Count) policies, $($theirsIndex.Count) distinct settings</p>
<h2>Summary</h2><table class='summary'>$summaryRows</table>
<h2>Setting matrix</h2>
<table><tr><th>Setting</th><th>Verdict</th><th>${OursLabel} value</th><th>${OursLabel} policy</th><th>${TheirsLabel} value</th><th>${TheirsLabel} policy</th><th>Shared targets</th><th>Notes</th></tr>
$($rows -join $newline)
</table>
$js
</body></html>
"@

$html | Set-Content -Path (Join-Path $OutputPath 'summary.html') -Encoding utf8

Write-Host "`nDone. Written to $OutputPath" -ForegroundColor Green
$counts | Format-Table Name, Count -AutoSize
