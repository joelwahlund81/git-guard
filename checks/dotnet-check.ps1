<#
.SYNOPSIS
    git-guard: .NET-kontroller som körs från pre-push-hooken.

.DESCRIPTION
    Körs automatiskt av hooken - behöver aldrig ändras. Fungerar i PowerShell 7 (pwsh)
    och Windows PowerShell 5.1. Kan också köras manuellt i ett repo:

        pwsh ~/.git-guard/checks/dotnet-check.ps1 -RepoRoot .

    Kontroller:
      1. Projektfiler: samma NuGet-paket i olika versioner, DLL-referens + NuGet för
         samma bibliotek, olika DLL-versioner/sökvägar, saknade DLL:er, flytande
         versioner, packages.config, Central Package Management-regler
      2. dotnet restore (--locked-mode om packages.lock.json finns)
      3. Transitiva beroenden (tredjepartsbibliotek) via obj/project.assets.json:
         nedgraderingar, versionskonflikter, sårbara paket, olika upplösta versioner
      4. dotnet format på ändrade filer
      5. dotnet build: referenskonflikter (MSB3277), olösta referenser (MSB3245)
      6. dotnet test

    -Detailed visar varje dotnet-kommando och hela utdatan.

    -ExistingIssues warn: problem i projektfiler som pushen inte rör (de fanns redan) blir
    varningar i stället för fel. Hooken skickar gitguard.existingIssues (standard warn).
    Körs skriptet manuellt (ggnet) räknas allt som fel, som tidigare.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '.',
    [string]$ChangedFilesPath,
    [ValidateSet('error', 'warn')]
    [string]$DriftLevel = 'error',
    [switch]$SkipTests,
    [switch]$SkipFormat,
    [switch]$SkipBuild,
    [ValidateSet('error', 'warn')]
    [string]$ExistingIssues = 'error',
    # whitespace: snabb (dotnet format whitespace --folder, laddar inte solutionen)
    # style: whitespace + kodstil + analyzers enligt .editorconfig (laddar hela solutionen)
    [ValidateSet('whitespace', 'style')]
    [string]$FormatMode = 'whitespace',
    # Visa varje dotnet-kommando och hela utdatan (gitguard.verbose / GITGUARD_VERBOSE=1)
    [switch]$Detailed
)

# 'Continue': Windows PowerShell 5.1 avbryter annars när dotnet skriver till stderr
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Variable PSStyle -ErrorAction SilentlyContinue)) {
    $PSStyle.OutputRendering = 'Ansi'
}
Set-Location -LiteralPath $RepoRoot -ErrorAction Stop
$script:RootPrefix = (Get-Location).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

# --- Utskrift ----------------------------------------------------------------
$E = [char]27
$script:ErrorCount = 0
$script:WarnCount = 0
function Write-Step([string]$m) { Write-Host "$E[36m▸ $m$E[0m" }
function Write-Ok([string]$m)   { Write-Host "$E[32m✓ $m$E[0m" }
function Write-Bad([string]$m)  { $script:ErrorCount++; Write-Host "$E[31m✗ $m$E[0m" }
function Write-Warn2([string]$m){ $script:WarnCount++;  Write-Host "$E[33m! $m$E[0m" }
function Write-Detail([string]$m) {
    if ($script:RootPrefix) { $m = $m.Replace($script:RootPrefix, '').Replace(($script:RootPrefix -replace '\\', '/'), '') }
    $m = $m -replace '\s*\[[^\[\]]+\.(csproj|fsproj|vbproj|sln|slnx)\]\s*$', ''
    $m = $m -replace '\s*\[\.\]\s*$', ''   # dotnet format --folder
    Write-Host "$E[90m    $m$E[0m"
}
function Write-Issue([string]$Level, [string]$m) {
    if ($Level -eq 'error') { Write-Bad $m } else { Write-Warn2 $m }
}
function Write-Skip([string]$m) { Write-Host "$E[90m- $m$E[0m" }

# Med -Detailed: mer utdata från dotnet och inga avkortade fellistor
$Verb = if ($Detailed) { 'minimal' } else { 'q' }
$MaxLines = if ($Detailed) { 100000 } else { 15 }
function Invoke-Dotnet([string[]]$DnArgs) {
    if ($Detailed) { Write-Host "$E[90m    `$ dotnet $($DnArgs -join ' ')$E[0m" }
    $o = @(& dotnet @DnArgs 2>&1 | ForEach-Object { "$_" })
    if ($Detailed) { $o | ForEach-Object { Write-Detail $_ } }
    return $o
}
$started = Get-Date

function Get-NuLabel([string]$Code) {
    switch -Regex ($Code) {
        'NU1605' { return 'Nedgradering av paket (ett beroende kräver en högre version)' }
        'NU1608' { return 'Paketversion utanför beroendets tillåtna intervall' }
        'NU1107' { return 'Versionskonflikt mellan beroenden' }
        'NU1603' { return 'Beroende löstes till en högre version än begärt' }
        'NU1701' { return 'Paket för .NET Framework används i ett modernt projekt' }
        'NU190[1-4]' { return 'Sårbart paket' }
        'NU1004' { return 'packages.lock.json är i osynk' }
        'NU1101|NU1102|NU1103' { return 'Paket eller version hittades inte' }
        'NU1301' { return 'Kunde inte nå paketkällan' }
        default { return 'NuGet' }
    }
}

# --- Hjälpfunktioner ---------------------------------------------------------
$ExcludeRx = '[\\/](bin|obj|node_modules|\.git|\.vs|TestResults)[\\/]|[\\/]packages[\\/][^\\/]+\.\d+\.\d+'

# Filer i repot hämtas med git ls-files (spårade + nya, inte ignorerade). Det är mycket snabbare
# än att gå igenom hela mappträdet med node_modules, bin och obj. Utan git: Get-ChildItem.
$script:GitFiles = $null
function Get-GitFileList {
    if ($null -ne $script:GitFiles) { return $script:GitFiles }
    $script:GitFiles = @()
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $o = @(& git -c core.quotePath=false ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0) { $script:GitFiles = @($o | Where-Object { $_ } | Select-Object -Unique) }
        else { $script:GitFiles = $false }
    } else { $script:GitFiles = $false }
    return $script:GitFiles
}
function Get-RepoFile([string[]]$Include) {
    $list = Get-GitFileList
    if ($list -is [array]) {
        foreach ($rel in $list) {
            $leaf = Split-Path $rel -Leaf
            $hit = $false
            foreach ($pat in $Include) { if ($leaf -like $pat) { $hit = $true; break } }
            if (-not $hit) { continue }
            $full = Join-Path (Get-Location).Path $rel
            if ($full -match $ExcludeRx) { continue }
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item -and -not $item.PSIsContainer) { $item }
        }
        return
    }
    Get-ChildItem -Path . -Recurse -File -Include $Include -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $ExcludeRx }
}

function Get-Rel([string]$Path) {
    $root = (Get-Location).Path.TrimEnd('\', '/')
    if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
    }
    return $Path -replace '\\', '/'
}

function Read-Xml([string]$Path) {
    try { return [xml](Get-Content -LiteralPath $Path -Raw) }
    catch { Write-Warn2 "Kunde inte läsa XML: $(Get-Rel $Path)"; return $null }
}

function Get-Nodes($Xml, [string]$Name) {
    if (-not $Xml) { return @() }
    return @($Xml.SelectNodes("//*[local-name()='$Name']"))
}

function Get-AttrOrChild($Node, [string]$Name) {
    $v = $Node.GetAttribute($Name)
    if ($v) { return $v.Trim() }
    $child = $Node.SelectSingleNode("*[local-name()='$Name']")
    if ($child) { return $child.InnerText.Trim() }
    return ''
}

# Enkla MSBuild-egenskaper ($(Name)) från Directory.*.props och projektet självt
$GlobalProps = @{}
function Add-Props($Xml, [hashtable]$Target) {
    foreach ($pg in (Get-Nodes $Xml 'PropertyGroup')) {
        foreach ($p in $pg.ChildNodes) {
            if ($p.NodeType -eq 'Element' -and -not $p.HasAttribute('Condition')) { $Target[$p.LocalName] = $p.InnerText.Trim() }
        }
    }
}
function Expand-Props([string]$Value, [hashtable]$Local) {
    if ($Value -notmatch '\$\(') { return $Value }
    return [regex]::Replace($Value, '\$\(([^)]+)\)', {
        param($m)
        $k = $m.Groups[1].Value
        if ($Local.ContainsKey($k)) { return $Local[$k] }
        if ($GlobalProps.ContainsKey($k)) { return $GlobalProps[$k] }
        return $m.Value
    })
}

# --- Hitta projekt och mål ---------------------------------------------------
$projects = @(Get-RepoFile @('*.csproj', '*.fsproj', '*.vbproj'))
if ($projects.Count -eq 0) { Write-Ok 'Inga .NET-projekt'; exit 0 }

$solutions = @(Get-ChildItem -Path (Join-Path (Get-Location).Path '*') -File -Include '*.sln', '*.slnx' -Force -ErrorAction SilentlyContinue)
if ($solutions.Count -eq 0) {
    $solutions = @(Get-ChildItem -Path . -File -Recurse -Depth 2 -Include '*.sln', '*.slnx' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $ExcludeRx })
}
if ($solutions.Count -gt 0) {
    $targets = @($solutions[0].FullName)
    if ($solutions.Count -gt 1) { Write-Detail "Flera solutions hittades, använder $(Get-Rel $solutions[0].FullName)" }
} else {
    $targets = @($projects | ForEach-Object { $_.FullName })
}
Write-Step ".NET: $($projects.Count) projekt ($((($targets | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))"

$changed = @()
if ($ChangedFilesPath -and (Test-Path -LiteralPath $ChangedFilesPath)) {
    $changed = @(Get-Content -LiteralPath $ChangedFilesPath | Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' })
}

# --- Nya eller gamla problem? ------------------------------------------------
# Ett problem räknas som nytt om pushen ändrar någon av filerna det gäller (projektet,
# dess packages.config/packages.lock.json) eller en fil som påverkar alla projekt.
$changedSet = @{}
foreach ($c in $changed) { $changedSet[$c.ToLower()] = $true }
$sharedTouched = @($changed | Where-Object {
    $_ -match '(^|/)(directory\.(build|packages)\.(props|targets)|global\.json|nuget\.config)$' }).Count -gt 0
$script:OldIssues = 0

function Test-Touched([string[]]$Sources) {
    if (-not $ChangedFilesPath -or $ExistingIssues -eq 'error' -or $sharedTouched) { return $true }
    foreach ($src in $Sources) {
        if (-not $src) { continue }
        $f = ($src -replace ' \(packages\.config\)$', '').ToLower()
        $dir = if ($f.Contains('/')) { $f.Substring(0, $f.LastIndexOf('/') + 1) } else { '' }
        foreach ($cand in @($f, "${dir}packages.lock.json", "${dir}packages.config")) {
            if ($changedSet.ContainsKey($cand)) { return $true }
        }
    }
    return $false
}

# Write-RefIssue: som Write-Issue, men ett fel i filer som pushen inte rör blir en varning
function Write-RefIssue([string]$Level, [string[]]$Sources, [string]$m) {
    if ($Level -eq 'error' -and -not (Test-Touched $Sources)) {
        $script:OldIssues++
        if ($m.EndsWith(':')) { Write-Warn2 ($m.TrimEnd(':') + ' (fanns redan):') } else { Write-Warn2 "$m (fanns redan)" }
    } else {
        Write-Issue $Level $m
    }
}

# =============================================================================
# 1. Projektfiler
# =============================================================================
Write-Step 'Analyserar paket- och DLL-referenser'

$packageProps = @(Get-RepoFile @('Directory.Packages.props'))
$buildProps   = @(Get-RepoFile @('Directory.Build.props', 'Directory.Build.targets'))
$cpmEnabled = $false
$centralVersions = @{}   # id -> version
foreach ($f in @($buildProps + $packageProps)) {
    $x = Read-Xml $f.FullName
    Add-Props $x $GlobalProps
}
foreach ($f in $packageProps) {
    $x = Read-Xml $f.FullName
    foreach ($n in (Get-Nodes $x 'ManagePackageVersionsCentrally')) { if ($n.InnerText.Trim() -eq 'true') { $cpmEnabled = $true } }
    foreach ($n in (Get-Nodes $x 'PackageVersion')) {
        $id = $n.GetAttribute('Include')
        if ($id) { $centralVersions[$id.ToLower()] = Expand-Props (Get-AttrOrChild $n 'Version') @{} }
    }
}
if ($GlobalProps['ManagePackageVersionsCentrally'] -eq 'true') { $cpmEnabled = $true }

$pkgRefs = New-Object System.Collections.Generic.List[object]   # Id, Version, Source, Kind
$dllRefs = New-Object System.Collections.Generic.List[object]   # Name, Version, HintPath, Source

$refFiles = @($projects) + @($buildProps)
foreach ($p in $refFiles) {
    $x = Read-Xml $p.FullName
    if (-not $x) { continue }
    $rel = Get-Rel $p.FullName
    $local = @{}; Add-Props $x $local
    # Ett projekt kan välja bort Central Package Management själv
    $projCpm = $cpmEnabled
    if ($local['ManagePackageVersionsCentrally'] -eq 'false') { $projCpm = $false }
    elseif ($local['ManagePackageVersionsCentrally'] -eq 'true') { $projCpm = $true }

    foreach ($n in (Get-Nodes $x 'PackageReference')) {
        $id = $n.GetAttribute('Include')
        if (-not $id) { continue }          # Update= räknas inte
        $ver      = Expand-Props (Get-AttrOrChild $n 'Version') $local
        $override = Expand-Props (Get-AttrOrChild $n 'VersionOverride') $local
        # Villkor (t.ex. per TargetFramework) från ItemGroup och själva referensen
        $cond = @($n.ParentNode.GetAttribute('Condition'), $n.GetAttribute('Condition')) | Where-Object { $_ }
        $cond = (($cond -join '&') -replace '\s+', '').ToLower()

        if ($projCpm) {
            if ($ver) {
                Write-RefIssue 'error' @($rel) "$rel`: $id har Version='$ver' men Central Package Management används"
                Write-Detail "Rätta: ta bort Version= här och lägg <PackageVersion Include=`"$id`" Version=`"$ver`" /> i Directory.Packages.props"
            }
            if ($override) {
                Write-Warn2 "$rel`: $id använder VersionOverride='$override' (avviker från central version)"
                $ver = $override
            } elseif ($centralVersions.ContainsKey($id.ToLower())) {
                $ver = $centralVersions[$id.ToLower()]
            } elseif (-not $ver) {
                Write-RefIssue 'error' @($rel) "$rel`: $id saknar PackageVersion i Directory.Packages.props"
                Write-Detail "Rätta: lägg till <PackageVersion Include=`"$id`" Version=`"<version>`" /> i Directory.Packages.props"
            }
        }
        if ($ver -match '\*|^[\[\(]') { Write-Warn2 "$rel`: $id har flytande/intervall-version '$ver' - lås till en exakt version" }
        $pkgRefs.Add([pscustomobject]@{ Id = $id; Version = $ver; Source = $rel; Kind = 'PackageReference'; Condition = $cond })
    }

    foreach ($n in (Get-Nodes $x 'Reference')) {
        $inc = $n.GetAttribute('Include')
        $hint = Get-AttrOrChild $n 'HintPath'
        if (-not $inc -or -not $hint) { continue }   # ramverksreferenser utan HintPath ignoreras
        $name = ($inc -split ',')[0].Trim()
        $ver = ''
        if ($inc -match 'Version=([^,\s]+)') { $ver = $Matches[1] }
        $hint = Expand-Props $hint $local
        $full = $hint
        if ($hint -notmatch '\$\(') {
            $full = [IO.Path]::GetFullPath((Join-Path (Split-Path $p.FullName -Parent) ($hint -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)))
            if (-not (Test-Path -LiteralPath $full)) {
                Write-RefIssue 'error' @($rel) "$rel`: DLL saknas: $hint"
                Write-Detail 'Rätta: committa DLL:en, rätta HintPath eller byt till ett NuGet-paket'
            }
        }
        $dllRefs.Add([pscustomobject]@{ Name = $name; Version = $ver; HintPath = $hint; FullPath = $full.ToLower(); RealPath = $full; Source = $rel })
        if ($hint -match '(^|[\\/])packages[\\/]') {
            Write-Warn2 "$rel`: $name refereras via packages\-mappen (gammal packages.config-stil) - byt till PackageReference"
        }
    }

    $pc = Join-Path (Split-Path $p.FullName -Parent) 'packages.config'
    if ($p.Extension -ne '.props' -and $p.Extension -ne '.targets' -and (Test-Path -LiteralPath $pc)) {
        Write-Warn2 "$rel`: använder packages.config - migrera till PackageReference (Visual Studio: högerklicka packages.config > Migrate)"
        $pcx = Read-Xml $pc
        foreach ($n in (Get-Nodes $pcx 'package')) {
            $pkgRefs.Add([pscustomobject]@{ Id = $n.GetAttribute('id'); Version = $n.GetAttribute('version'); Source = "$rel (packages.config)"; Kind = 'packages.config'; Condition = '' })
        }
    }
}

# 1a. Samma paket i olika versioner. Referenser med olika villkor (t.ex. en version per
#     TargetFramework) jämförs inte med varandra - det är avsiktligt.
$drift = @($pkgRefs | Where-Object { $_.Id -and $_.Version } | Group-Object { "$($_.Id.ToLower())|$($_.Condition)" } |
    Where-Object { @($_.Group | Select-Object -ExpandProperty Version -Unique).Count -gt 1 })
foreach ($g in $drift) {
    $first = $g.Group[0].Id
    Write-RefIssue $DriftLevel @($g.Group | ForEach-Object { $_.Source }) "NuGet-paketet $first finns i olika versioner:"
    foreach ($vg in ($g.Group | Group-Object Version | Sort-Object Name)) {
        Write-Detail ("{0,-14} {1}" -f $vg.Name, (($vg.Group | Select-Object -ExpandProperty Source -Unique) -join ', '))
    }
    Write-Detail 'Rätta: använd samma Version överallt (eller Central Package Management, se README)'
}

# 1b. Samma bibliotek som både DLL och NuGet
$pkgIds = @{}
foreach ($r in $pkgRefs) { if ($r.Id) { $pkgIds[$r.Id.ToLower()] = $r } }
foreach ($d in $dllRefs) {
    $key = $d.Name.ToLower()
    $file = [IO.Path]::GetFileNameWithoutExtension(($d.HintPath -replace '\\', '/')).ToLower()
    $hit = $null
    if ($pkgIds.ContainsKey($key)) { $hit = $pkgIds[$key] } elseif ($pkgIds.ContainsKey($file)) { $hit = $pkgIds[$file] }
    # packages.config-stil: DLL:en ligger i paketets egen mapp (packages\Id.1.2.3\lib\...).
    # Det är NuGet som refererar den, inte en extra DLL.
    if ($hit -and $d.HintPath -match ('(^|[\\/])packages[\\/]' + [regex]::Escape($hit.Id) + '\.\d')) { $hit = $null }
    if ($hit) {
        Write-RefIssue 'error' @($d.Source, $hit.Source) "$($d.Name) refereras både som DLL och som NuGet-paket:"
        Write-Detail "DLL:   $($d.Source) -> $($d.HintPath)"
        Write-Detail "NuGet: $($hit.Source) -> $($hit.Id) $($hit.Version)"
        Write-Detail "Rätta: ta bort <Reference Include=`"$($d.Name)`"> i $($d.Source) och använd NuGet-paketet"
    }
}

# 1c. Samma DLL med olika versioner eller sökvägar.
#     Fel när versionerna skiljer sig. Bara olika sökväg (t.ex. lib\net45 och lib\netstandard2.0
#     i samma paket, eller en kopia med samma version) är en varning.
function Get-DllVersion($Ref) {
    if ($Ref.Version) { return $Ref.Version }
    if ($Ref.HintPath -match '\$\(' -or -not (Test-Path -LiteralPath $Ref.RealPath)) { return '' }
    try { return [Reflection.AssemblyName]::GetAssemblyName($Ref.RealPath).Version.ToString() }
    catch { return '' }
}
function Get-DllLocation($Ref) {
    # DLL:er i en NuGet-paketmapp räknas till paketmappen, inte till lib\<tfm>
    if ($Ref.FullPath -match '^(.*[\\/]packages[\\/][^\\/]+)[\\/]') { return $Matches[1] }
    return $Ref.FullPath
}
foreach ($g in ($dllRefs | Group-Object { $_.Name.ToLower() })) {
    if ($g.Count -lt 2) { continue }
    foreach ($r in $g.Group) { $r | Add-Member -NotePropertyName EffVersion -NotePropertyValue (Get-DllVersion $r) -Force }
    $versions  = @($g.Group | Where-Object { $_.EffVersion } | ForEach-Object { $_.EffVersion } | Select-Object -Unique)
    $locations = @($g.Group | ForEach-Object { Get-DllLocation $_ } | Select-Object -Unique)
    if ($versions.Count -gt 1) {
        Write-RefIssue 'error' @($g.Group | ForEach-Object { $_.Source }) "DLL:en $($g.Group[0].Name) refereras i olika versioner:"
    } elseif ($locations.Count -gt 1) {
        Write-Warn2 "DLL:en $($g.Group[0].Name) refereras från olika mappar (samma eller okänd version):"
    } else { continue }
    foreach ($r in $g.Group) { Write-Detail ("{0,-12} {1} ({2})" -f $(if ($r.EffVersion) { $r.EffVersion } else { '?' }), $r.HintPath, $r.Source) }
    Write-Detail 'Rätta: låt alla projekt peka på samma DLL (en gemensam lib-mapp) eller byt till ett NuGet-paket'
}

if ($pkgRefs.Count -gt 0 -and -not $cpmEnabled -and $projects.Count -ge 3 -and $drift.Count -gt 0) {
    Write-Detail 'Tips: Central Package Management (Directory.Packages.props) gör att versioner bara anges på ett ställe.'
}
if ($script:ErrorCount -eq 0 -and $script:WarnCount -eq 0) {
    Write-Ok "Referenser ok ($($pkgRefs.Count) paket, $($dllRefs.Count) DLL-referenser)"
}

# =============================================================================
# 2. Restore
# =============================================================================
$lockFiles = @(Get-RepoFile @('packages.lock.json'))
$restoreOk = $true
foreach ($t in $targets) {
    $dnArgs = @('restore', $t, '--nologo', '-v', $Verb)
    if ($lockFiles.Count -gt 0) { $dnArgs += '--locked-mode' }
    Write-Step ("dotnet restore" + $(if ($lockFiles.Count -gt 0) { ' --locked-mode' } else { '' }))
    $out = Invoke-Dotnet $dnArgs
    if ($LASTEXITCODE -ne 0) {
        $restoreOk = $false
        if ($lockFiles.Count -gt 0 -and ($out -match 'NU1004')) {
            Write-Bad 'packages.lock.json är i osynk med projektfilerna'
            Write-Detail 'Rätta: dotnet restore --force-evaluate   och committa packages.lock.json'
        } else {
            $codes = @($out | ForEach-Object { if ($_ -match 'error (NU\d{4})') { $Matches[1] } } | Select-Object -Unique)
            if ($codes.Count -gt 0) {
                foreach ($c in $codes) { Write-Bad "$(Get-NuLabel $c) ($c)" }
            } else {
                Write-Bad "dotnet restore misslyckades för $(Split-Path $t -Leaf)"
            }
        }
        $out | Where-Object { $_ -match 'error' } |
            ForEach-Object { ($_ -replace '^.*?error (NU\d{4}: )?', '' -replace 'Warning As Error: ', '').Trim() } |
            Select-Object -Unique -First $MaxLines | ForEach-Object { Write-Detail $_ }
    }
}
if ($restoreOk) { Write-Ok 'Restore ok' }

# Projekt som saknar låsfil när andra har det
if ($lockFiles.Count -gt 0) {
    foreach ($p in $projects) {
        if (-not (Test-Path -LiteralPath (Join-Path $p.DirectoryName 'packages.lock.json'))) {
            Write-Warn2 "$(Get-Rel $p.FullName) saknar packages.lock.json (sätt RestorePackagesWithLockFile i Directory.Build.props)"
        }
    }
}

# =============================================================================
# 3. Transitiva beroenden (tredjepartsbibliotek)
# =============================================================================
if ($restoreOk) {
    Write-Step 'Analyserar transitiva beroenden'
    $errorCodes = @('NU1605', 'NU1107', 'NU1903', 'NU1904', 'NU1106')
    $logSeen = [ordered]@{}   # kod|paket|meddelande -> @{ Log; Projects; Sources }
    $resolved = @{}   # "tfm|id" -> @{ version -> [projekt] }
    $issuesBefore = $script:ErrorCount + $script:WarnCount

    foreach ($p in $projects) {
        $assets = Join-Path $p.DirectoryName 'obj/project.assets.json'
        if (-not (Test-Path -LiteralPath $assets)) { continue }
        try { $json = Get-Content -LiteralPath $assets -Raw | ConvertFrom-Json }
        catch { Write-Warn2 "Kunde inte läsa $(Get-Rel $assets) (stora filer kräver pwsh 7)"; continue }
        $projName = $p.BaseName

        foreach ($log in @($json.logs)) {
            if (-not $log) { continue }
            $key = "$($log.code)|$($log.libraryId)|$($log.message)"
            if (-not $logSeen.Contains($key)) {
                $logSeen[$key] = @{ Log = $log; Projects = New-Object System.Collections.Generic.List[string]; Sources = New-Object System.Collections.Generic.List[string] }
            }
            $logSeen[$key].Projects.Add($projName)
            $logSeen[$key].Sources.Add((Get-Rel $p.FullName))
        }

        foreach ($tfm in @($json.targets.PSObject.Properties)) {
            foreach ($lib in @($tfm.Value.PSObject.Properties)) {
                if ($lib.Value.type -ne 'package') { continue }
                $parts = $lib.Name -split '/'
                $k = "$($tfm.Name)|$($parts[0].ToLower())"
                if (-not $resolved.ContainsKey($k)) { $resolved[$k] = @{ Id = $parts[0]; Tfm = $tfm.Name; Versions = @{} } }
                $vers = $resolved[$k].Versions
                if (-not $vers.ContainsKey($parts[1])) { $vers[$parts[1]] = New-Object System.Collections.Generic.List[string] }
                $vers[$parts[1]].Add($projName)
            }
        }
    }

    foreach ($entry in $logSeen.Values) {
        $log = $entry.Log
        $level = if ($errorCodes -contains $log.code -or $log.level -eq 'Error') { 'error' } else { 'warn' }
        $what = Get-NuLabel $log.code
        Write-RefIssue $level @($entry.Sources) "$what ($($log.code)) i $(($entry.Projects | Select-Object -Unique) -join ', '):"
        Write-Detail ($log.message -replace '\s+', ' ')
        if ($log.code -match 'NU190[1-4]') { Write-Detail "Rätta: uppdatera paketet $($log.libraryId) till en version utan sårbarheten (dotnet list package --vulnerable --include-transitive)" }
        elseif ($log.code -eq 'NU1605') { Write-Detail 'Rätta: höj den direkta PackageReference till den version som beroendet kräver' }
        elseif ($log.code -eq 'NU1107') { Write-Detail 'Rätta: lägg till en direkt PackageReference med en version som passar alla beroenden' }
    }

    $transDrift = @($resolved.Values | Where-Object { $_.Versions.Count -gt 1 } | Sort-Object Id)
    if ($transDrift.Count -gt 0) {
        Write-Warn2 "$($transDrift.Count) tredjepartspaket löses till olika versioner i olika projekt:"
        foreach ($d in ($transDrift | Select-Object -First 12)) {
            $desc = ($d.Versions.Keys | Sort-Object | ForEach-Object { "$_ ($(($d.Versions[$_] | Select-Object -Unique) -join ', '))" }) -join '  vs  '
            Write-Detail "$($d.Id) [$($d.Tfm)]: $desc"
        }
        if ($transDrift.Count -gt 12) { Write-Detail "... och $($transDrift.Count - 12) till" }
        Write-Detail 'Rätta: lägg till en direkt PackageReference (eller PackageVersion) med samma version överallt.'
    }
    if (($script:ErrorCount + $script:WarnCount) -eq $issuesBefore) { Write-Ok 'Transitiva beroenden ok' }
}

# =============================================================================
# 4. Formatering (bara ändrade filer)
# =============================================================================
$codeFiles = @($changed | Where-Object { $_ -match '\.(cs|vb|fs)$' -and (Test-Path -LiteralPath $_) })
if ($SkipFormat) {
    Write-Skip 'Hoppar över formatering (gitguard.skipFormat)'
} elseif ($codeFiles.Count -eq 0) {
    if ($ChangedFilesPath) { Write-Skip 'Formatering: inga ändrade .cs/.vb/.fs-filer' }
} elseif ($FormatMode -eq 'style' -and -not $restoreOk) {
    Write-Skip 'Hoppar över formatering eftersom restore misslyckades'
}
if (-not $SkipFormat -and $codeFiles.Count -gt 0 -and $FormatMode -eq 'whitespace') {
    # Snabb variant: läser bara filerna och .editorconfig, laddar inte solutionen och kräver ingen restore
    Write-Step "dotnet format whitespace: $($codeFiles.Count) fil(er)"
    $out = Invoke-Dotnet (@('format', 'whitespace', '.', '--folder', '--verify-no-changes', '-v', $Verb, '--include') + $codeFiles)
    if ($LASTEXITCODE -ne 0) {
        Write-Bad 'Formateringen avviker (mellanslag, indrag eller radslut)'
        $out | Where-Object { $_ -match '(error|warning) ' } | Select-Object -Unique -First $MaxLines | ForEach-Object { Write-Detail $_.Trim() }
        Write-Detail ('Rätta: dotnet format whitespace --folder --include ' + ($codeFiles -join ' ') + '   och committa')
    } else {
        Write-Ok 'Formatering ok'
    }
}
if (-not $SkipFormat -and $codeFiles.Count -gt 0 -and $FormatMode -eq 'style' -and $restoreOk) {
    $hasEditorConfig = (Test-Path -LiteralPath '.editorconfig')
    $mode = if ($hasEditorConfig) { 'style + whitespace (.editorconfig)' } else { 'whitespace' }
    Write-Step "dotnet format: $($codeFiles.Count) fil(er), $mode"
    $fmtOk = $true
    foreach ($t in $targets) {
        $dnArgs = @('format', $t)
        if (-not $hasEditorConfig) { $dnArgs += 'whitespace' }
        $dnArgs += @('--verify-no-changes', '--no-restore', '-v', $Verb, '--include') + $codeFiles
        $out = Invoke-Dotnet $dnArgs
        if ($LASTEXITCODE -ne 0) {
            $fmtOk = $false
            Write-Bad 'Formateringen avviker'
            $out | Where-Object { $_ -match '(error|warning) ' } | Select-Object -Unique -First $MaxLines | ForEach-Object { Write-Detail $_.Trim() }
            Write-Detail ('Rätta: dotnet format' + $(if (-not $hasEditorConfig) { ' whitespace' } else { '' }) + ' och committa')
        }
    }
    if ($fmtOk) { Write-Ok 'Formatering ok' }
}

# =============================================================================
# 5. Build - referenskonflikter
# =============================================================================
$buildOk = $false
$allRefIssues = 0
if ($SkipBuild) { Write-Skip 'Hoppar över build (-SkipBuild)' }
elseif (-not $restoreOk) { Write-Skip 'Hoppar över build eftersom restore misslyckades' }
if (-not $SkipBuild -and $restoreOk) {
    Write-Step 'dotnet build'
    $buildOk = $true
    foreach ($t in $targets) {
        $out = Invoke-Dotnet @('build', $t, '--no-restore', '--nologo', '-v', $Verb, '-clp:NoSummary')
        $code = $LASTEXITCODE
        $refIssues = @($out | Where-Object { $_ -match 'warning (MSB3277|MSB3245|MSB3243|MSB3274|MSB3275)' } |
            ForEach-Object { ($_).Trim() } | Select-Object -Unique)
        $allRefIssues += $refIssues.Count
        foreach ($i in $refIssues) {
            $label = switch -Regex ($i) {
                'MSB3277' { 'Referenskonflikt: olika versioner av samma assembly'; break }
                'MSB3245' { 'Referens kunde inte hittas'; break }
                'MSB3243' { 'Olöslig referenskonflikt'; break }
                default   { 'Inkompatibel referens' }
            }
            $src = @()
            if ($i -match '\[([^\[\]]+\.(csproj|fsproj|vbproj))\]\s*$') { $src = @(Get-Rel $Matches[1]) }
            Write-RefIssue 'error' $src $label
            Write-Detail ($i -replace '^.*?warning ', '')
        }
        if ($code -ne 0) {
            $buildOk = $false
            Write-Bad "Bygget misslyckades: $(Split-Path $t -Leaf)"
            $out | Where-Object { $_ -match ': error ' } | ForEach-Object { ($_).Trim() } |
                Select-Object -Unique -First $MaxLines | ForEach-Object { Write-Detail $_ }
        }
    }
    if ($buildOk -and $allRefIssues -eq 0) { Write-Ok 'Build ok, inga referenskonflikter' }
}

# =============================================================================
# 6. Tester
# =============================================================================
if (-not $SkipTests) {
    $testProjects = @($projects | Where-Object {
        $c = Get-Content -LiteralPath $_.FullName -Raw
        $c -match 'Microsoft\.NET\.Test\.Sdk|<IsTestProject>\s*true' })
    if ($testProjects.Count -eq 0) {
        Write-Detail 'Inga testprojekt hittades'
    } elseif (-not $restoreOk -or (-not $SkipBuild -and -not $buildOk)) {
        Write-Warn2 'Hoppar över tester eftersom restore/build misslyckades'
    } else {
        Write-Step "dotnet test ($($testProjects.Count) testprojekt)"
        foreach ($t in $targets) {
            $dnArgs = @('test', $t, '--nologo', '-v', $Verb)
            if (-not $SkipBuild) { $dnArgs += '--no-build' } else { $dnArgs += '--no-restore' }
            if ($Detailed) { Write-Host "$E[90m    `$ dotnet $($dnArgs -join ' ')$E[0m" }
            & dotnet @dnArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
            if ($LASTEXITCODE -ne 0) { Write-Bad 'Tester misslyckades' } else { Write-Ok 'Tester ok' }
        }
    }
}

# =============================================================================
if ($script:OldIssues -gt 0) {
    Write-Detail "$($script:OldIssues) problem markerade (fanns redan) gäller filer som pushen inte ändrar och stoppar inte pushen."
    Write-Detail 'Vill du att de stoppar: git config gitguard.existingIssues error'
}
$secs = [int]((Get-Date) - $started).TotalSeconds
if ($script:ErrorCount -gt 0) {
    Write-Host "$E[31m.NET: $script:ErrorCount fel, $script:WarnCount varningar (${secs}s)$E[0m"
    exit 1
}
Write-Host "$E[32m.NET: inga fel, $script:WarnCount varningar (${secs}s)$E[0m"
exit 0
