<#
.SYNOPSIS
  Generate an email-centric HTML report from a Forcepoint case export (PowerShell port of parse_export.py).

.DESCRIPTION
  Reads the standard case-export tree and writes a self-contained HTML report with one card per
  EMAIL record (channel 3, or SearchResults label), linking each attachment to a copy materialized
  under its original filename. Non-destructive; Windows PowerShell 5.1+ and PowerShell 7 compatible.

.PARAMETER Root
  Path to the CaseExport directory.

.PARAMETER Output
  Output HTML path (default: <Root>\report.html).

.PARAMETER AttachmentsDir
  Where to materialize renamed attachments (default: <Root>\attachments; pass '' to skip).

.EXAMPLE
  .\Parse-Export.ps1 ..\examples\demo_case
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Root,
    [string]$Output,
    [AllowEmptyString()][string]$AttachmentsDir
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path
if (-not (Test-Path -LiteralPath (Join-Path $rootPath 'UberManifest.json'))) {
    throw "$rootPath does not look like a CaseExport (no UberManifest.json)"
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

# Mirror Python's html.escape: & < > " plus ' (WebUtility.HtmlEncode leaves ' alone).
function Esc($Value) {
    $s = if ($null -eq $Value) { '' } else { "$Value" }
    [System.Net.WebUtility]::HtmlEncode($s).Replace("'", '&#x27;')
}

# Mirror json.dumps(indent=2, ensure_ascii=False) byte-for-byte.
function Json-EscString([string]$S) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $S.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append('\u' + ('{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function To-JsonPy($Obj, [int]$Level = 0) {
    $pad = ('  ' * ($Level + 1))
    $closePad = ('  ' * $Level)
    if ($null -eq $Obj) { return 'null' }
    if ($Obj -is [string]) { return (Json-EscString $Obj) }
    if ($Obj -is [bool]) { if ($Obj) { return 'true' } else { return 'false' } }
    if ($Obj -is [long] -or $Obj -is [int] -or $Obj -is [double] -or $Obj -is [decimal]) {
        return $Obj.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Obj -is [array] -or $Obj -is [System.Collections.IEnumerable]) {
        $items = @($Obj)
        if ($items.Count -eq 0) { return '[]' }
        $inner = @($items | ForEach-Object { $pad + (To-JsonPy $_ ($Level + 1)) })
        return "[`n" + ($inner -join ",`n") + "`n$closePad]"
    }
    $props = @($Obj.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $inner = @($props | ForEach-Object { $pad + (Json-EscString $_.Name) + ': ' + (To-JsonPy $_.Value ($Level + 1)) })
    return "{`n" + ($inner -join ",`n") + "`n$closePad}"
}

function Format-Ts($Ms) {
    if (-not $Ms) { return '-' }
    try { ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms)).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC') }
    catch { "$Ms" }
}

# Known attachment binaries: lowercase name -> actual filename. Directory listing is the source of truth.
$binDir = Join-Path (Join-Path $rootPath 'ccd') 'binary'
$known = @{}
if (Test-Path -LiteralPath $binDir) {
    Get-ChildItem -LiteralPath $binDir -File | ForEach-Object { $known[$_.Name.ToLower()] = $_.Name }
}

function Find-HashesInText([string]$Text) {
    # Ordinal substring scan of the entry's JSON text; order by first occurrence.
    $hits = @()
    foreach ($k in $known.Keys) {
        $i = $Text.IndexOf($k, [StringComparison]::Ordinal)
        if ($i -ge 0) { $hits += [pscustomobject]@{ Index = $i; Hash = $k } }
    }
    @($hits | Sort-Object Index | ForEach-Object { $_.Hash })
}

function Get-FileNameFromEntry($Entry) {
    foreach ($k in 'fileName', 'name', 'originalName', 'displayName', 'file_name') {
        $p = $Entry.PSObject.Properties[$k]
        if ($p -and $p.Value -is [string] -and $p.Value) { return $p.Value }
    }
    return $null
}

# ---- build model -----------------------------------------------------------
$searchById = @{}
$srAll = Read-JsonFile (Join-Path (Join-Path $rootPath 'searchresults') 'SearchResults.json')
if ($srAll) {
    foreach ($e in @($srAll)) {
        $eid = $e.evidencePK.evidenceId
        if ($eid) { $searchById[$eid] = $e }
    }
}

$emPath = Join-Path (Join-Path $rootPath 'evidences') 'EvidencesManifest.json'
$em = Read-JsonFile $emPath
if (-not $em) { throw "Cannot read $emPath" }

$emails = @()
$totalRecords = 0
foreach ($prop in $em.PSObject.Properties) {
    $recPath = [IO.Path]::Combine($rootPath, ($prop.Value -replace '/', [IO.Path]::DirectorySeparatorChar))
    $rec = Read-JsonFile $recPath
    if (-not $rec -or -not $rec.evidence) { continue }
    $totalRecords++
    $ev = $rec.evidence
    $eid = if ($ev.evidenceId) { $ev.evidenceId } else { $prop.Name }   # manifest key is canonical
    $srRec = $searchById[$eid]
    $isEmail = ($ev.channel -eq 3) -or ($srRec -and "$($srRec.channel)".ToUpper() -eq 'EMAIL')
    if (-not $isEmail) { continue }

    $atts = @(); $seen = @{}
    foreach ($fe in @($rec.evidenceFiles)) {
        if (-not $fe) { continue }
        $feRaw = ConvertTo-Json -InputObject $fe -Depth 30 -Compress
        foreach ($h in (Find-HashesInText $feRaw)) {
            if (-not $seen.ContainsKey($h)) {
                $seen[$h] = $true
                $atts += [pscustomobject]@{ Hash = $h; FileName = (Get-FileNameFromEntry $fe) }
            }
        }
    }
    $emails += [pscustomobject]@{ EvidenceId = $eid; Ev = $ev; Search = $srRec; Attachments = $atts }
}

# ---- materialize attachments under original filenames ----------------------
function Get-UniqueName([string]$Base, [string]$H, $Used) {
    if (-not $Used.ContainsKey($Base) -or $Used[$Base] -eq $H) { return $Base }
    $i = $Base.IndexOf('.')
    if ($i -ge 0) { $stem = $Base.Substring(0, $i); $dot = '.'; $ext = $Base.Substring($i + 1) }
    else { $stem = $Base; $dot = ''; $ext = '' }
    $n = 1
    while ($true) {
        $cand = if ($dot) { "$stem`_$n$dot$ext" } else { "$Base`_$n" }
        if (-not $Used.ContainsKey($cand) -or $Used[$cand] -eq $H) { return $cand }
        $n++
    }
}

$outPath = if ($Output) { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath (Split-Path -Parent $Output) -ErrorAction SilentlyContinue).Path + [IO.Path]::DirectorySeparatorChar + (Split-Path -Leaf $Output)) }
           else { Join-Path $rootPath 'report.html' }

$attDir = $null; $nameMap = @{}
if ($AttachmentsDir -eq '') { $attDir = $null }
elseif ($PSBoundParameters.ContainsKey('AttachmentsDir')) {
    # Resolve symlinks (e.g. macOS /tmp -> /private/tmp) like Python's Path.resolve().
    $p = [IO.Path]::GetFullPath($AttachmentsDir)
    if (Test-Path -LiteralPath $p) { $attDir = (Resolve-Path -LiteralPath $p).Path }
    else {
        $parent = Split-Path -Parent $p; $leaf = Split-Path -Leaf $p
        if (Test-Path -LiteralPath $parent) { $attDir = Join-Path (Resolve-Path -LiteralPath $parent).Path $leaf }
        else { $attDir = $p }
    }
}
else { $attDir = Join-Path $rootPath 'attachments' }

if ($attDir) {
    $used = @{}
    foreach ($e in $emails) {
        foreach ($a in $e.Attachments) {
            if ($nameMap.ContainsKey($a.Hash)) { continue }
            $base = if ($a.FileName) { $a.FileName } else { $a.Hash }
            $target = Get-UniqueName $base $a.Hash $used
            $src = Join-Path (Join-Path (Join-Path $rootPath 'ccd') 'binary') $known[$a.Hash]
            if (Test-Path -LiteralPath $src) {
                if (-not (Test-Path -LiteralPath $attDir)) { New-Item -ItemType Directory -Force -Path $attDir | Out-Null }
                Copy-Item -LiteralPath $src -Destination (Join-Path $attDir $target) -Force
            }
            $nameMap[$a.Hash] = $target; $used[$target] = $a.Hash
        }
    }
}

function Get-RelLink([string]$TargetFile) {
    # Relative link from the report file's own folder (mirrors os.path.relpath against out_path.parent).
    $baseUri = New-Object Uri(((Split-Path -Parent $outPath).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar))
    ($baseUri.MakeRelativeUri((New-Object Uri($TargetFile))).ToString() -replace '\\', '/' |
        ForEach-Object { [Uri]::UnescapeDataString($_) })
}

# ---- render HTML ------------------------------------------------------------
# Byte-identical to CSS in parse_export.py.
$css = @'
:root { --bg:#f6f7f9; --card:#fff; --ink:#1c2530; --muted:#6b7684;
        --line:#e2e6ea; --accent:#2b6cb0; --mono:#0f1720; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
       font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
.wrap { max-width:960px; margin:0 auto; padding:32px 20px 80px; }
header.report h1 { font-size:24px; margin:0 0 4px; }
header.report .sub { color:var(--muted); font-size:14px; }
.summary { display:flex; gap:12px; flex-wrap:wrap; margin:20px 0 8px; }
.stat { background:var(--card); border:1px solid var(--line); border-radius:8px;
        padding:10px 16px; min-width:120px; }
.stat .n { font-size:22px; font-weight:600; }
.stat .l { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px;
        padding:20px 22px; margin:18px 0; box-shadow:0 1px 2px rgba(16,24,40,.04); }
.card h2 { font-size:17px; margin:0 0 2px; }
.card .who { color:var(--muted); font-size:14px; margin-bottom:14px; }
table.meta { width:100%; border-collapse:collapse; font-size:13.5px; }
table.meta td { padding:5px 8px 5px 0; vertical-align:top; border-bottom:1px solid var(--line); }
table.meta tr:last-child td { border-bottom:none; }
table.meta td.k { color:var(--muted); width:170px; white-space:nowrap; }
code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
              font-size:12.5px; background:#eef1f4; padding:1px 5px; border-radius:4px; }
.tags { display:flex; flex-wrap:wrap; gap:6px; }
.tag { background:#eaf1fb; color:var(--accent); border-radius:20px; padding:2px 10px; font-size:12.5px; }
h3.att { font-size:14px; margin:20px 0 8px; text-transform:uppercase;
         letter-spacing:.04em; color:var(--muted); }
.attach { border-left:3px solid var(--accent); background:#fbfcfe; border-radius:0 8px 8px 0;
          padding:12px 16px; margin:10px 0; }
.attach .top { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap; }
.attach a.bin { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12.5px;
                color:var(--accent); text-decoration:none; word-break:break-all; }
.attach a.bin:hover { text-decoration:underline; }
.attach .fn { font-weight:600; }
.attach .te-link { font-size:12.5px; color:var(--muted); text-decoration:none; }
.attach .te-link:hover { color:var(--accent); text-decoration:underline; }
pre.te { margin:10px 0 0; padding:12px; background:#0f1720; color:#e6edf3;
         border-radius:8px; overflow:auto; max-height:340px; font-size:12.5px;
         font-family:ui-monospace,Menlo,Consolas,monospace; white-space:pre-wrap; }
.empty { color:var(--muted); font-style:italic; font-size:13.5px; }
footer.report { margin-top:40px; color:var(--muted); font-size:12.5px; text-align:center; }
'@

function Render-Tags($List) {
    if (-not $List -or @($List).Count -eq 0) { return '<span class="empty">—</span>' }
    '<div class="tags">' + ((@($List) | ForEach-Object { "<span class=`"tag`">$(Esc $_)</span>" }) -join '') + '</div>'
}

function Render-Attachment($Att) {
    $h = $Att.Hash
    $display = if ($nameMap.ContainsKey($h)) { $nameMap[$h] } elseif ($Att.FileName) { $Att.FileName } else { $h }
    $binUrl = if ($attDir) { Get-RelLink (Join-Path $attDir $display) } else { "ccd/binary/$h" }
    $tePath = Join-Path (Join-Path (Join-Path $rootPath 'ccd') 'textextract') "$h.json"
    $te = Read-JsonFile $tePath
    $teHtml = if ($null -eq $te) { '<div class="empty">no text extract</div>' }
              else { "<pre class='te'>$(Esc (To-JsonPy $te))</pre>" }
@"
<div class="attach"><div class="top"><span class="fn">$(Esc $display)</span> · <a class="bin" href="$(Esc $binUrl)" title="Open binary attachment">$(Esc $h)</a> <a class="te-link" href="ccd/textextract/$(Esc $h).json">textextract.json</a></div>$teHtml</div>
"@
}

function Render-Email($Email) {
    $ev = $Email.Ev
    $who = if ($Email.Search -and $Email.Search.personLabel) { $Email.Search.personLabel }
           elseif ($ev.applicationName) { $ev.applicationName } else { '—' }
    $date = Format-Ts $(if ($ev.dateId) { $ev.dateId } else { $ev.startDate })
    $rows = @(
        @('Date', "<code>$(Esc $date)</code>"),
        @('Evidence ID', "<code>$(Esc $Email.EvidenceId)</code>"),
        @('Channel / Activity', "$(Esc $ev.channel) / $(Esc $ev.activityCode)"),
        @('Application', (Esc $ev.applicationName)),
        @('User', "<code>$(Esc $ev.userId)</code>"),
        @('Agent', "<code>$(Esc $ev.agentId)</code>"),
        @('Match text', $(if ($ev.matchText) { Esc $ev.matchText } else { '<span class="empty">—</span>' })),
        @('Triggers', (Render-Tags $ev.triggerLabels)),
        @('Categories', (Render-Tags $ev.categoryLabels)),
        @('Groups', (Render-Tags $ev.groupLabels))
    )
    $meta = (($rows | ForEach-Object { "<tr><td class=`"k`">$($_[0])</td><td>$($_[1])</td></tr>" }) -join '')
    $atts = @($Email.Attachments)
    $attHtml = if ($atts.Count -gt 0) { (($atts | ForEach-Object { Render-Attachment $_ }) -join '') }
               else { '<div class="empty">No attachments captured for this record (evidenceFiles empty — placeholder or no files).</div>' }
@"
<section class="card"><h2>Email</h2><div class="who">$(Esc $who)</div><table class="meta">$meta</table><h3 class="att">Attachments ($($atts.Count))</h3>$attHtml</section>
"@
}

$case = Read-JsonFile (Join-Path $rootPath 'Case.json')
$nAtt = ($emails | ForEach-Object { @($_.Attachments).Count } | Measure-Object -Sum).Sum
if (-not $nAtt) { $nAtt = 0 }
$body = if ($emails.Count -gt 0) { (($emails | ForEach-Object { Render-Email $_ }) -join '') }
        else { '<section class="card"><div class="empty">No email records found. Once evidence records with channel 3 (EMAIL) and populated evidenceFiles are present, they will appear here.</div></section>' }
$generated = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Forcepoint Case Report — $(Esc $(if ($case.name) { $case.name } else { 'unnamed' }))</title>
<style>
$css
</style>
</head>
<body>
<div class="wrap">
<header class="report">
  <h1>Forcepoint Case Report</h1>
  <div class="sub">$(Esc $case.name) · case $(Esc $case.id) · generated $generated</div>
</header>

<div class="summary">
  <div class="stat"><div class="n">$($emails.Count)</div><div class="l">Email records</div></div>
  <div class="stat"><div class="n">$nAtt</div><div class="l">Attachments linked</div></div>
  <div class="stat"><div class="n">$($known.Count)</div><div class="l">Known binaries</div></div>
  <div class="stat"><div class="n">$totalRecords</div><div class="l">Total records</div></div>
</div>

$body

<footer class="report">Generated by Parse-Export.ps1 from a Forcepoint Investigations Workbench export.</footer>
</div>
</body>
</html>
"@

# UTF-8 without BOM, LF endings + trailing newline (matches Python write_text on all PowerShell versions).
[System.IO.File]::WriteAllText($outPath, ($html -replace "`r`n", "`n") + "`n")
Write-Host "Wrote $outPath  ($($emails.Count) email(s), $nAtt attachment(s), $($nameMap.Count) materialized -> $(if ($attDir) { $attDir } else { '(skipped)' }), $($known.Count) known binaries)"
