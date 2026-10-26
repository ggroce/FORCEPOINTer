<#
.SYNOPSIS
  Create per-email attachment folders from a Forcepoint case export (PowerShell port of extract_email_folders.py).

.DESCRIPTION
  Emails are grouped by agent time: every email sharing the same timestamp goes into ONE folder named
  "<yyyy-MM-dd_HHmmss> - from <senders> - to <recipients>", containing that group's attachments under
  their original filenames. Same-named attachments are stored once; with -KeepAllVersions, same-named
  files whose CONTENT differs (SHA-256) are kept side by side as "name [8-char hash].ext".
  With -ExtractZips, .zip attachments are extracted into <folder>\extractions\<zip-name>/ using 7-Zip
  ONLY (auto-detected on PATH and in standard Windows install dirs; skipped with a warning if absent).
  Non-destructive. Windows PowerShell 5.1+ and PowerShell 7 compatible.

.PARAMETER Root
  Path to the CaseExport directory.

.PARAMETER Output
  Output root for the folders (default: <Root>\emails_by_date).

.EXAMPLE
  .\Extract-EmailFolders.ps1 ..\examples\demo_case -KeepAllVersions -ExtractZips
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Root,
    [string]$Output,
    [switch]$KeepAllVersions,
    [switch]$ExtractZips
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path
if (-not (Test-Path -LiteralPath (Join-Path $rootPath 'UberManifest.json'))) {
    throw "$rootPath does not look like a CaseExport (no UberManifest.json)"
}

$emailRegex = [regex]'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
$fromKeys = 'from', 'sender', 'originator', 'mailFrom', 'fromAddress'
$toKeys = 'to', 'recipient', 'recipients', 'rcptTo', 'toAddress'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Sanitize([string]$Name) {
    $n = ($Name -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim(' ', '.')
    if ($n.Length -gt 120) { return $n.Substring(0, 120) }
    $n
}

function Get-AgentTime($Ev) {
    foreach ($k in 'agentTime', 'startDate', 'dateId') {
        $v = $Ev.$k
        if ($v -is [long] -and $v -ne 0) { return [long]$v }
        if ($v -is [double] -and $v -ne 0) { return [long]$v }
    }
    return 0
}

function Get-TsDirname($Ms) {
    if (-not $Ms) { return 'unknown-time' }
    ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms)).ToUniversalTime().ToString('yyyy-MM-dd_HHmmss')
}

function Get-FieldAddress($Ev, $Keys) {
    foreach ($k in $Keys) {
        $p = $Ev.PSObject.Properties[$k]
        if (-not $p) { continue }
        $v = $p.Value
        $s = if ($v -is [System.Array]) { ($v | ForEach-Object { "$_" }) -join ' ' } else { "$v" }
        $m = $emailRegex.Match($s)
        if ($m.Success) { return $m.Value }
    }
    return $null
}

function Get-Parties($Ev, [string]$RawText) {
    $frm = Get-FieldAddress $Ev $fromKeys
    $to = Get-FieldAddress $Ev $toKeys
    if (-not ($frm -and $to)) {
        $found = @(); $seenLower = @{}
        foreach ($m in $emailRegex.Matches($RawText)) {
            $a = $m.Value
            if (-not $seenLower.ContainsKey($a.ToLower())) { $seenLower[$a.ToLower()] = $true; $found += $a }
        }
        if (-not $frm -and $found.Count -ge 1) { $frm = $found[0] }
        if (-not $to -and $found.Count -ge 2) { $to = $found[1] }
    }
    return @($frm, $to)
}

function Get-ContentHash([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ($sha.ComputeHash([IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Find-7Zip {
    foreach ($n in '7z', '7zz', '7za', '7zip', '7z.exe', '7zz.exe', '7za.exe', '7zip.exe') {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    if ($env:OS -eq 'Windows_NT') {
        foreach ($dir in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
            $p = Join-Path (Join-Path $dir '7-Zip') '7z.exe'
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

function Extract-Zip7z([string]$Archive, [string]$Dest, [string]$SevenZip) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    & $SevenZip x -y -bso0 -bsp0 "-o$Dest" $Archive 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---- build model (same rules as the Python tools) ---------------------------
$searchById = @{}
$srAll = Read-JsonFile (Join-Path (Join-Path $rootPath 'searchresults') 'SearchResults.json')
if ($srAll) { foreach ($e in @($srAll)) { $eid = $e.evidencePK.evidenceId; if ($eid) { $searchById[$eid] = $e } } }

$em = Read-JsonFile (Join-Path (Join-Path $rootPath 'evidences') 'EvidencesManifest.json')
if (-not $em) { throw 'Cannot read EvidencesManifest.json' }

$binDir = Join-Path (Join-Path $rootPath 'ccd') 'binary'
$knownNames = @{}
if (Test-Path -LiteralPath $binDir) {
    Get-ChildItem -LiteralPath $binDir -File | ForEach-Object { $knownNames[$_.Name.ToLower()] = $_.Name }
}

function Get-FileNameFromEntry($Entry) {
    foreach ($k in 'fileName', 'name', 'originalName', 'displayName', 'file_name') {
        $p = $Entry.PSObject.Properties[$k]
        if ($p -and $p.Value -is [string] -and $p.Value) { return $p.Value }
    }
    return $null
}

$emails = @()
foreach ($prop in $em.PSObject.Properties) {
    $recPath = [IO.Path]::Combine($rootPath, ($prop.Value -replace '/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $recPath)) { continue }
    $rec = Read-JsonFile $recPath
    if (-not $rec -or -not $rec.evidence) { continue }
    $ev = $rec.evidence
    $eid = if ($ev.evidenceId) { $ev.evidenceId } else { $prop.Name }
    $srRec = $searchById[$eid]
    if (-not (($ev.channel -eq 3) -or ($srRec -and "$($srRec.channel)".ToUpper() -eq 'EMAIL'))) { continue }

    $atts = @(); $seen = @{}
    foreach ($fe in @($rec.evidenceFiles)) {
        if (-not $fe) { continue }
        $feRaw = ConvertTo-Json -InputObject $fe -Depth 30 -Compress
        $hits = @()
        foreach ($k in $knownNames.Keys) {
            $i = $feRaw.IndexOf($k, [StringComparison]::Ordinal)
            if ($i -ge 0) { $hits += [pscustomobject]@{ Index = $i; Hash = $k } }
        }
        foreach ($h in ($hits | Sort-Object Index | ForEach-Object { $_.Hash })) {
            if (-not $seen.ContainsKey($h)) { $seen[$h] = $true; $atts += [pscustomobject]@{ Hash = $h; FileName = (Get-FileNameFromEntry $fe) } }
        }
    }
    $raw = Get-Content -LiteralPath $recPath -Raw -Encoding UTF8
    $emails += [pscustomobject]@{ EvidenceId = $eid; Ev = $ev; Attachments = $atts; Raw = $raw }
}

# ---- 7-Zip backend (only if requested, no fallback) --------------------------
$sevenZip = $null
if ($ExtractZips) {
    $sevenZip = Find-7Zip
    if (-not $sevenZip) {
        Write-Warning '--extract-zips requested but 7-Zip was not found (PATH and standard install locations checked) - zip attachments will NOT be extracted.'
    }
}

# ---- group by agent time, write folders --------------------------------------
$outDir = if ($Output) { $Output } else { Join-Path $rootPath 'emails_by_date' }
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$groups = @{}
foreach ($e in $emails) {
    $ts = Get-TsDirname (Get-AgentTime $e.Ev)
    if (-not $groups.ContainsKey($ts)) { $groups[$ts] = @() }
    $groups[$ts] += $e
}

$made = 0; $copied = 0; $extracted = 0; $zipFailures = @()
foreach ($ts in ($groups.Keys | Sort-Object)) {
    $group = $groups[$ts]
    $frms = @(); $tos = @(); $parties = @()
    foreach ($e in $group) {
        $p = Get-Parties $e.Ev $e.Raw
        $parties += , $p
        if ($p[0] -and $frms -notcontains $p[0]) { $frms += $p[0] }
        if ($p[1] -and $tos -notcontains $p[1]) { $tos += $p[1] }
    }
    $base = Sanitize ("{0} - from {1} - to {2}" -f $ts, $(if ($frms.Count) { $frms -join ',' } else { 'unknown' }), $(if ($tos.Count) { $tos -join ',' } else { 'unknown' }))
    $ids = @($group | ForEach-Object { $_.EvidenceId })

    # Reuse folder on re-runs (idempotent); suffix _N for distinct groups with the same name.
    $folder = Join-Path $outDir $base
    $n = 1
    while (Test-Path -LiteralPath $folder) {
        $prev = Read-JsonFile (Join-Path $folder '.manifest.json')
        if ($prev -and ((@($prev.evidenceIds) | Sort-Object) -join '|') -eq (($ids | Sort-Object) -join '|')) { break }
        $n++; $folder = Join-Path $outDir ("{0}_{1}" -f $base, $n)
    }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    $manifest = [ordered]@{
        timestamp   = $ts
        evidenceIds = $ids
        emails      = @($group | ForEach-Object -Begin { $i = 0 } -Process {
            @{ evidenceId = $_.EvidenceId; agentTime = (Get-AgentTime $_.Ev); from = $parties[$i][0]; to = $parties[$i][1] }; $i++
        })
    }
    Set-Content -LiteralPath (Join-Path $folder '.manifest.json') -Value ($manifest | ConvertTo-Json -Depth 6) -Encoding UTF8

    $present = @{}
    foreach ($e in $group) {
        foreach ($att in $e.Attachments) {
            $src = Join-Path (Join-Path (Join-Path $rootPath 'ccd') 'binary') $knownNames[$att.Hash]
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $chash = Get-ContentHash $src
            $name = Sanitize $(if ($att.FileName) { $att.FileName } else { $att.Hash })
            if ($present.ContainsKey($name)) {
                if ($present[$name] -eq $chash) { continue }          # byte-identical copy exists
                if (-not $KeepAllVersions) { continue }               # default: first copy wins
                $i = $name.IndexOf('.')
                if ($i -ge 0) { $stem = $name.Substring(0, $i); $dot = '.'; $ext = $name.Substring($i + 1) }
                else { $stem = $name; $dot = ''; $ext = '' }
                $tag = ' [' + $att.Hash.Substring(0, [Math]::Min(8, $att.Hash.Length)) + ']'
                $cand = "$stem$tag$dot$ext"; $k = 2
                while ($present.ContainsKey($cand) -and $present[$cand] -ne $chash) { $cand = "$stem$tag ($k)$dot$ext"; $k++ }
                $name = $cand
            }
            $present[$name] = $chash
            Copy-Item -LiteralPath $src -Destination (Join-Path $folder $name) -Force
            $copied++
            if ($sevenZip -and $name.ToLower().EndsWith('.zip')) {
                $stemName = [IO.Path]::GetFileNameWithoutExtension($name)
                $dest = Join-Path (Join-Path $folder 'extractions') (Sanitize $(if ($stemName) { $stemName } else { 'archive' }))
                if (Extract-Zip7z (Join-Path $folder $name) $dest $sevenZip) { $extracted++ }
                else { $zipFailures += "$base/$name" }
            }
        }
    }
    $made++
}

$summary = "Wrote $made time-grouped email folder(s), $copied attachment file(s) under $outDir"
if ($ExtractZips) { $summary += ", $extracted zip(s) extracted via 7-Zip" + $(if ($sevenZip) { " ($sevenZip)" } else { '' }) }
Write-Host $summary
foreach ($f in $zipFailures) { Write-Warning "7-Zip failed to extract $f" }
