<#
.SYNOPSIS
    Testsvit för git-guard. Fungerar i Windows PowerShell 5.1 och PowerShell 7 (Windows/Linux/macOS).

.DESCRIPTION
    .\tests\run-tests.ps1            statiska kontroller + alla funktionstester (kräver dotnet och nätverk)
    .\tests\run-tests.ps1 -Quick     bara statiska kontroller (syntax, BOM, radslut, dokumentation)
    .\tests\run-tests.ps1 -Only drift,format    bara vissa scenarier (namn eller del av namn)
    .\tests\run-tests.ps1 -Keep      behåll testrepona (sökvägen skrivs ut)

    Funktionstesterna skapar tillfälliga repon med en lokal "remote", gör commits och kör hooken
    precis som git push gör (stdin med refs). Din egen git config påverkas inte: testerna kör med
    en egen GIT_CONFIG_GLOBAL.
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [string[]]$Only,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
# Utdata från bash/git är UTF-8. Utan detta läser Windows PowerShell 5.1 å, ä och ö fel.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent
$IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$E = [char]27

function Write-Pass([string]$m) { $script:Passed++; Write-Host "$E[32m  ok   $m$E[0m" }
function Write-Fail([string]$m) { $script:Failed++; Write-Host "$E[31m  FEL  $m$E[0m" }
function Write-SkipT([string]$m) { $script:Skipped++; Write-Host "$E[90m  --   $m$E[0m" }
function Write-Section([string]$m) { Write-Host "`n$E[36m== $m$E[0m" }

# -Only a,b kommer in som en sträng när skriptet körs med -File
$Only = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Test-Selected([string]$Name) {
    if ($Only.Count -eq 0) { return $true }
    foreach ($o in $Only) { if ($Name -like "*$o*") { return $true } }
    return $false
}

# =============================================================================
# Statiska kontroller
# =============================================================================
Write-Section 'Statiska kontroller'

$bash = $null
if ($IsWin) {
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    $cands = @()
    if ($git) { $cands += Join-Path (Split-Path (Split-Path $git -Parent) -Parent) 'bin\bash.exe' }
    $cands += "$env:ProgramFiles\Git\bin\bash.exe"
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { $bash = $c; break } }
} else {
    $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
}
if (-not $bash) { Write-Fail 'Hittar inte bash (Git Bash)'; exit 1 }

$hookFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'hooks') -File)
foreach ($h in $hookFiles) {
    $bytes = [IO.File]::ReadAllBytes($h.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Write-Fail "hooks/$($h.Name): har BOM (ska vara UTF-8 utan BOM)" }
    elseif ([Array]::IndexOf($bytes, [byte]13) -ge 0) { Write-Fail "hooks/$($h.Name): har CRLF (ska vara LF)" }
    else { Write-Pass "hooks/$($h.Name): UTF-8 utan BOM, LF" }
    & $bash -n ($h.FullName -replace '\\', '/') 2>&1 | ForEach-Object { Write-Host "       $_" }
    if ($LASTEXITCODE -eq 0) { Write-Pass "hooks/$($h.Name): bash -n" } else { Write-Fail "hooks/$($h.Name): bash -n" }
}
$line2 = (Get-Content -LiteralPath (Join-Path $Root 'hooks/pre-push') -TotalCount 2)[1]
if ($line2 -eq '# git-guard pre-push hook') { Write-Pass 'markörraden står på rad 2 i hooks/pre-push' } else { Write-Fail "rad 2 i hooks/pre-push är '$line2'" }

# Obs: -Include ignoreras med -LiteralPath i Windows PowerShell 5.1, därför Where-Object
foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    $rel = $f.FullName.Substring($Root.Length + 1) -replace '\\', '/'
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { Write-Fail "${rel}: saknar BOM (krävs för Windows PowerShell 5.1)" }
    $text = [IO.File]::ReadAllText($f.FullName)
    # Tankstreck och typografiska citattecken (skrivna som teckenkoder så att filen själv är ren)
    $bad = '[' + [char]0x2013 + [char]0x2014 + [char]0x201C + [char]0x201D + [char]0x2018 + [char]0x2019 + ']'
    if ($text -match $bad) { Write-Fail "${rel}: innehåller tankstreck eller typografiska citattecken" }
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs) { Write-Fail "${rel}: parse-fel: $($errs[0].Message) (rad $($errs[0].Extent.StartLineNumber))" }
    else { Write-Pass "${rel}: BOM och parse ($($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor))" }
}

# Textfiler: LF och inga tab-tecken (.gitattributes kräver LF, .editorconfig mellanslag)
foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.Extension -in @('.md', '.yml', '.json', '.ps1') -and $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    $rel = $f.FullName.Substring($Root.Length + 1) -replace '\\', '/'
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) { Write-Fail "${rel}: har CR (ska vara LF)" }
    elseif ([Array]::IndexOf($bytes, [byte]9) -ge 0) { Write-Fail "${rel}: har tab-tecken" }
    else { Write-Pass "${rel}: LF, inga tab-tecken" }
}

# Dokumentation i synk: varje gitguard-inställning finns i README och i help.ps1,
# varje kommando i $MyCommands finns i README
$readme = [IO.File]::ReadAllText((Join-Path $Root 'README.md'))
$help = [IO.File]::ReadAllText((Join-Path $Root 'terminal/help.ps1'))
$keys = New-Object System.Collections.Generic.HashSet[string]
$hookText = [IO.File]::ReadAllText((Join-Path $Root 'hooks/pre-push'))
foreach ($m in [regex]::Matches($hookText, '\bcfg(?:_bool|_enum)?\s+(\w+)')) { [void]$keys.Add($m.Groups[1].Value) }
foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { ($_.Extension -eq '.ps1' -or $_.Name -eq 'pre-push') -and $_.FullName -notmatch '[\\/](\.git|tests)[\\/]' })) {
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), 'gitguard\.(\w+)')) { [void]$keys.Add($m.Groups[1].Value) }
}
foreach ($k in ($keys | Sort-Object)) {
    if ($readme -notmatch "gitguard\.$k\b") { Write-Fail "inställningen gitguard.$k saknas i README" }
    elseif ($help -notmatch "Key = '$k'") { Write-Fail "inställningen gitguard.$k saknas i `$GGSettings (terminal/help.ps1)" }
    elseif ($hookText -notmatch "gitguard\.$k\b" -and $k -notin @('startup', 'repoRoots')) { Write-Fail "inställningen gitguard.$k saknas i hookens header" }
    else { Write-Pass "gitguard.$k dokumenterad" }
}
$profileText = [IO.File]::ReadAllText((Join-Path $Root 'terminal/profile.ps1'))
foreach ($m in [regex]::Matches($profileText, "(?m)^\s*'([\w-]+)'\s*=\s*@\{\s*Group")) {
    $k = $m.Groups[1].Value
    if ($readme -match "``$k[`` ]") { Write-Pass "kommandot $k finns i README" } else { Write-Fail "kommandot $k saknas i README" }
}

if ($Quick) {
    Write-Host "`n$($script:Passed) ok, $($script:Failed) fel, $($script:Skipped) överhoppade"
    if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
}

# =============================================================================
# Funktionstester
# =============================================================================
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Write-Fail 'dotnet saknas - kan inte köra funktionstesterna (använd -Quick)'; exit 1 }

$Work = Join-Path ([IO.Path]::GetTempPath()) ("git-guard-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work | Out-Null
$gitCfg = Join-Path $Work 'gitconfig'
[IO.File]::WriteAllText($gitCfg, "[user]`n`tname = git-guard-test`n`temail = test@example.invalid`n[init]`n`tdefaultBranch = main`n[core]`n`tautocrlf = false`n")
$env:GIT_CONFIG_GLOBAL = $gitCfg
$env:GIT_GUARD_HOME = $Root
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
Remove-Item Env:SKIP_TESTS, Env:GITGUARD_DRYRUN, Env:GITGUARD_VERBOSE -ErrorAction SilentlyContinue
$Tfm = "net$((& dotnet --version).Split('.')[0]).0"
$HookPath = (Join-Path $Root 'hooks/pre-push') -replace '\\', '/'
Write-Section "Funktionstester ($Work, $Tfm, $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"

function Set-File([string]$Path, [string]$Text) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
}

function Invoke-Git([string]$Repo) {
    $o = & git -C $Repo @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') misslyckades: $o" }
    $o
}

# Nytt repo med lokal remote. Basen (filerna i $Files) committas och pushas utan hook.
function New-TestRepo([string]$Name, [hashtable]$Files) {
    $repo = Join-Path $Work $Name
    $remote = "$repo.remote"
    & git init -q --bare $remote 2>&1 | Out-Null
    & git init -q -b main $repo 2>&1 | Out-Null
    Invoke-Git $repo remote add origin ($remote -replace '\\', '/') | Out-Null
    Set-File (Join-Path $repo '.gitignore') "bin/`nobj/`n"
    if ($Files) { foreach ($k in $Files.Keys) { Set-File (Join-Path $repo $k) $Files[$k] } }
    Invoke-Git $repo add -A | Out-Null
    Invoke-Git $repo commit -qm base | Out-Null
    Invoke-Git $repo push -q origin main | Out-Null
    return $repo
}

function Add-Commit([string]$Repo, [hashtable]$Files, [string]$Message = 'ändring') {
    foreach ($k in $Files.Keys) { Set-File (Join-Path $Repo $k) $Files[$k] }
    Invoke-Git $Repo add -A | Out-Null
    Invoke-Git $Repo commit -qm $Message | Out-Null
}

# Kör hooken som git push gör. Returnerar @{ Exit; Out } (utan ANSI-färger)
function Invoke-Hook([string]$Repo, [hashtable]$Env = @{}) {
    $sha = (Invoke-Git $Repo rev-parse HEAD | Select-Object -First 1).Trim()
    $old = (Invoke-Git $Repo rev-parse origin/main | Select-Object -First 1).Trim()
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    Push-Location $Repo
    try {
        $out = "refs/heads/main $sha refs/heads/main $old" | & $bash $HookPath origin ($Repo + '.remote') 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $text = ($out -join "`n") -replace "$E\[[0-9;]*m", ''
    return @{ Exit = $code; Out = $text }
}

function Assert-Hook([string]$Name, $Result, [int]$Exit, [string[]]$Contains = @(), [string[]]$NotContains = @()) {
    $problems = @()
    if ($Result.Exit -ne $Exit) { $problems += "exitkod $($Result.Exit), väntade $Exit" }
    foreach ($c in $Contains) { if (-not $Result.Out.Contains($c)) { $problems += "saknar '$c'" } }
    foreach ($c in $NotContains) { if ($Result.Out.Contains($c)) { $problems += "innehåller '$c'" } }
    if ($problems.Count -eq 0) { Write-Pass $Name }
    else {
        Write-Fail "$Name - $($problems -join '; ')"
        ($Result.Out -split "`n") | Select-Object -Last 40 | ForEach-Object { Write-Host "$E[90m       | $_$E[0m" }
    }
}

function Get-Csproj([string]$Items = '', [string]$Props = '') {
    return @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>$Tfm</TargetFramework>$Props</PropertyGroup>
  <ItemGroup>$Items</ItemGroup>
</Project>
"@
}
$cs = "namespace Lib;`n`npublic class Class1`n{`n    public int Add(int a, int b) => a + b;`n}`n"
$csEdit = "namespace Lib;`n`npublic class Class1`n{`n    public int Add(int a, int b) => a + b;`n`n    public int Sub(int a, int b) => a - b;`n}`n"
# Snabbare: inga tester och ingen formatering i scenarier som bara gäller projektfilerna
function Set-Fast([string]$Repo) { Invoke-Git $Repo config gitguard.skipTests true | Out-Null; Invoke-Git $Repo config gitguard.format off | Out-Null }

$scenarios = [ordered]@{}

$scenarios['rent repo'] = {
    $r = New-TestRepo 'clean' @{ 'Lib/Lib.csproj' = (Get-Csproj); 'Lib/Class1.cs' = $cs }
    Add-Commit $r @{ 'Lib/Class1.cs' = $csEdit }
    Assert-Hook 'rent repo: allt grönt' (Invoke-Hook $r) 0 @('Alla kontroller ok', 'Sammanfattning', 'Formatering ok')
    Assert-Hook 'rent repo: andra körningen använder cachen' (Invoke-Hook $r) 0 @('redan kontrollerat')
}

$scenarios['versionsdrift'] = {
    $r = New-TestRepo 'drift' @{
        'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />')
        'B/B.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />') }
    Set-Fast $r
    Add-Commit $r @{ 'B/B.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.1" />') }
    Assert-Hook 'versionsdrift i ändrat projekt: fel' (Invoke-Hook $r) 1 @('finns i olika versioner', 'Rätta:') @('(fanns redan)')
}

$scenarios['gammal drift'] = {
    $r = New-TestRepo 'olddrift' @{
        'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />'); 'A/Class1.cs' = $cs
        'B/B.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.1" />') }
    Set-Fast $r
    Add-Commit $r @{ 'A/Class1.cs' = $csEdit }
    Assert-Hook 'drift som fanns innan: varning, pushen går igenom' (Invoke-Hook $r) 0 @('(fanns redan)', 'existingIssues')
    Invoke-Git $r config gitguard.existingIssues error | Out-Null
    Assert-Hook 'drift som fanns innan med existingIssues=error: fel' (Invoke-Hook $r) 1 @('finns i olika versioner')
}

$scenarios['dll och nuget'] = {
    $r = New-TestRepo 'dllnuget' @{ 'lib/Newtonsoft.Json.dll' = 'x'; 'A/A.csproj' = (Get-Csproj) }
    Set-Fast $r
    Add-Commit $r @{ 'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" /><Reference Include="Newtonsoft.Json"><HintPath>..\lib\Newtonsoft.Json.dll</HintPath></Reference>') }
    Assert-Hook 'DLL + NuGet för samma bibliotek: fel' (Invoke-Hook $r) 1 @('både som DLL och som NuGet-paket')
}

$scenarios['dll-konflikt'] = {
    $r = New-TestRepo 'dllconflict' @{ 'lib/v1/Foo.dll' = 'x'; 'lib/v2/Foo.dll' = 'x'; 'A/A.csproj' = (Get-Csproj); 'B/B.csproj' = (Get-Csproj) }
    Set-Fast $r
    Add-Commit $r @{
        'A/A.csproj' = (Get-Csproj '<Reference Include="Foo, Version=1.0.0.0"><HintPath>..\lib\v1\Foo.dll</HintPath></Reference>')
        'B/B.csproj' = (Get-Csproj '<Reference Include="Foo, Version=2.0.0.0"><HintPath>..\lib\v2\Foo.dll</HintPath></Reference>') }
    Assert-Hook 'samma DLL i olika versioner: fel' (Invoke-Hook $r) 1 @('refereras i olika versioner')
    Add-Commit $r @{ 'B/B.csproj' = (Get-Csproj '<Reference Include="Foo, Version=1.0.0.0"><HintPath>..\lib\v2\Foo.dll</HintPath></Reference>') }
    Assert-Hook 'samma DLL-version från olika mappar: bara varning' (Invoke-Hook $r) 0 @('från olika mappar') @('refereras i olika versioner')
}

$scenarios['packages.config'] = {
    $pc = '<?xml version="1.0" encoding="utf-8"?><packages><package id="Newtonsoft.Json" version="13.0.3" targetFramework="net48" /></packages>'
    $old = '<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003"><ItemGroup><Reference Include="Newtonsoft.Json, Version=13.0.0.0"><HintPath>..\packages\Newtonsoft.Json.13.0.3\lib\{0}\Newtonsoft.Json.dll</HintPath></Reference></ItemGroup></Project>'
    $r = New-TestRepo 'pkgconfig' @{
        'packages/Newtonsoft.Json.13.0.3/lib/net45/Newtonsoft.Json.dll' = 'x'; 'packages/Newtonsoft.Json.13.0.3/lib/netstandard2.0/Newtonsoft.Json.dll' = 'x'
        'Legacy/Legacy.csproj' = ($old -f 'net45'); 'Legacy/packages.config' = $pc; 'Legacy/A.cs' = $cs
        'Legacy2/Legacy2.csproj' = ($old -f 'netstandard2.0'); 'Legacy2/packages.config' = $pc }
    Invoke-Git $r config gitguard.skipTests true | Out-Null
    Invoke-Git $r config gitguard.format off | Out-Null
    Add-Commit $r @{ 'Legacy/Legacy.csproj' = (($old -f 'net45') + "`n") }
    $res = Invoke-Hook $r
    Assert-Hook 'packages.config: inget DLL+NuGet-fel eller DLL-konflikt' $res $res.Exit @('använder packages.config') @('både som DLL och som NuGet-paket', 'refereras i olika versioner', 'från olika mappar')
}

$scenarios['villkorad drift'] = {
    $items = '</ItemGroup><ItemGroup Condition="''$(TargetFramework)'' == ''netstandard2.0''"><PackageReference Include="Newtonsoft.Json" Version="13.0.1" /></ItemGroup><ItemGroup Condition="''$(TargetFramework)'' == ''' + $Tfm + '''"><PackageReference Include="Newtonsoft.Json" Version="13.0.3" />'
    $proj = (Get-Csproj $items) -replace "<TargetFramework>$Tfm</TargetFramework>", "<TargetFrameworks>$Tfm;netstandard2.0</TargetFrameworks>"
    $r = New-TestRepo 'multitfm' @{ 'A/A.csproj' = (Get-Csproj) }
    Set-Fast $r
    Add-Commit $r @{ 'A/A.csproj' = $proj }
    Assert-Hook 'olika versioner per TargetFramework: ingen drift' (Invoke-Hook $r) 0 @() @('finns i olika versioner')
}

$scenarios['cpm opt-out'] = {
    $r = New-TestRepo 'cpm' @{
        'Directory.Packages.props' = '<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup><ItemGroup><PackageVersion Include="Newtonsoft.Json" Version="13.0.3" /></ItemGroup></Project>'
        'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" />') }
    Set-Fast $r
    Add-Commit $r @{ 'B/B.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />' '<ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>') }
    Assert-Hook 'projekt som valt bort CPM: inget CPM-fel' (Invoke-Hook $r) 0 @() @('Central Package Management används')
    Add-Commit $r @{ 'C/C.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />') }
    Assert-Hook 'Version= trots CPM: fel' (Invoke-Hook $r) 1 @('Central Package Management används', 'Rätta:')
}

$scenarios['låsfil'] = {
    $props = '<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>'
    $r = New-TestRepo 'lockfile' @{ 'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.1" />' $props) }
    & dotnet restore (Join-Path $r 'A/A.csproj') -v q 2>&1 | Out-Null
    Invoke-Git $r add -A | Out-Null; Invoke-Git $r commit -qm lock | Out-Null; Invoke-Git $r push -q origin main | Out-Null
    Set-Fast $r
    Add-Commit $r @{ 'A/A.csproj' = (Get-Csproj '<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />' $props) }
    Assert-Hook 'ändrad version utan ny låsfil: fel (NU1004)' (Invoke-Hook $r) 1 @('packages.lock.json är i osynk')
}

$scenarios['transitiv drift'] = {
    $r = New-TestRepo 'transitive' @{ 'A/A.csproj' = (Get-Csproj); 'B/B.csproj' = (Get-Csproj) }
    Set-Fast $r
    Add-Commit $r @{
        'A/A.csproj' = (Get-Csproj '<PackageReference Include="Microsoft.Extensions.Logging" Version="8.0.0" />')
        'B/B.csproj' = (Get-Csproj '<PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="6.0.0" />') }
    Assert-Hook 'transitivt beroende i olika versioner: varning' (Invoke-Hook $r) 0 @('löses till olika versioner', 'Microsoft.Extensions.DependencyInjection.Abstractions')
}

$scenarios['formatering'] = {
    $r = New-TestRepo 'format' @{ 'Lib/Lib.csproj' = (Get-Csproj); 'Lib/Class1.cs' = $cs }
    Invoke-Git $r config gitguard.skipTests true | Out-Null
    Add-Commit $r @{ 'Lib/Class1.cs' = "namespace Lib;`n`npublic class Class1`n{`n    public int Add(int a,int b)   =>   a + b;`n}`n" }
    Assert-Hook 'felaktiga mellanslag i ändrad .cs: fel' (Invoke-Hook $r) 1 @('Formateringen avviker', 'Rätta: dotnet format whitespace')
}

$scenarios['tester'] = {
    $test = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>$Tfm</TargetFramework><IsPackable>false</IsPackable></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
</Project>
"@
    $tests = "using Xunit;`nnamespace T;`npublic class Tests`n{`n    [Fact] public void Fast() => Assert.True(true);`n    [Fact, Trait(`"Category`", `"Integration`")] public void Db() => Assert.Fail(`"ingen databas`");`n}`n"
    $r = New-TestRepo 'tests' @{ 'T/T.csproj' = $test; 'T/Tests.cs' = $tests }
    Invoke-Git $r config gitguard.format off | Out-Null
    Add-Commit $r @{ 'T/Tests.cs' = ($tests + "`n") }
    Assert-Hook 'test som failar: fel' (Invoke-Hook $r) 1 @('Tester misslyckades', 'testFilter')
    Invoke-Git $r config gitguard.testFilter 'Category!=Integration' | Out-Null
    Assert-Hook 'gitguard.testFilter hoppar över integrationstestet' (Invoke-Hook $r) 0 @('filter: Category!=Integration', 'Tester ok')
}

$scenarios['bara sql'] = {
    $r = New-TestRepo 'sqlonly' @{ 'Lib/Lib.csproj' = (Get-Csproj) }
    Add-Commit $r @{ 'db/q.sql' = "SELECT 1;`n" }
    Assert-Hook 'bara SQL ändrad: .NET hoppas över' (Invoke-Hook $r) 0 @('Inga .NET-relevanta filer ändrade')
}

$scenarios['dokumentation'] = {
    $r = New-TestRepo 'docs' @{ 'Lib/Lib.csproj' = (Get-Csproj) }
    Add-Commit $r @{ 'README.md' = "# Hej`n" }
    Assert-Hook 'bara dokumentation: inga .NET-steg' (Invoke-Hook $r) 0 @('bara dokumentation ändrad') @('dotnet restore')
}

$scenarios['skyddad branch'] = {
    $r = New-TestRepo 'protected' @{}
    Invoke-Git $r config gitguard.protectedBranches 'main master' | Out-Null
    Add-Commit $r @{ 'README.md' = "x`n" }
    Assert-Hook 'push till skyddad branch: fel' (Invoke-Hook $r) 1 @("Direkt push till 'main' är blockerad", 'Rätta:')
}

$scenarios['konfliktmarkörer'] = {
    $r = New-TestRepo 'conflict' @{}
    Add-Commit $r @{ 'a.txt' = "<<<<<<< HEAD`nx`n=======`ny`n>>>>>>> other`n" }
    Assert-Hook 'kvarglömda konfliktmarkörer: fel' (Invoke-Hook $r) 1 @('Konfliktmarkörer hittade')
}

$scenarios['arbetskatalog'] = {
    $r = New-TestRepo 'dirty' @{}
    Add-Commit $r @{ 'a.txt' = "x`n" }
    Set-File (Join-Path $r 'a.txt') "lokal ändring`n"
    Assert-Hook 'ocommittad ändring i pushad fil: varning' (Invoke-Hook $r) 0 @('Ocommittade ändringar i filer som pushas')
}

$scenarios['torrkörning'] = {
    $r = New-TestRepo 'dryrun' @{}
    $hook = Join-Path $r '.git/hooks/pre-push'
    Set-File $hook "#!/bin/sh`necho REPOHOOK-KORDES`n"
    if (-not $IsWin) { & chmod +x $hook }
    Add-Commit $r @{ 'a.txt' = "x`n" }
    Assert-Hook 'gg (torrkörning) kör inte repots hook' (Invoke-Hook $r @{ GITGUARD_DRYRUN = '1' }) 0 @('körs inte vid torrkörning') @('REPOHOOK-KORDES')
    Assert-Hook 'riktig push kör repots hook' (Invoke-Hook $r) 0 @('REPOHOOK-KORDES')
}

$scenarios['passthrough'] = {
    $r = New-TestRepo 'passthrough' @{}
    $hook = Join-Path $r '.git/hooks/commit-msg'
    Set-File $hook "#!/bin/sh`ngrep -q '^[A-Z]' `"`$1`" || { echo 'stor bokstav'; exit 1; }`n"
    if (-not $IsWin) { & chmod +x $hook }
    Set-File (Join-Path $r 'a.txt') "x`n"
    & git -C $r add -A 2>&1 | Out-Null
    & git -C $r -c "core.hooksPath=$((Join-Path $Root 'hooks') -replace '\\', '/')" commit -qm 'liten bokstav' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Pass 'repots commit-msg körs via git-guard (global hooksPath)' } else { Write-Fail 'repots commit-msg kördes inte via passthrough' }
}

$scenarios['hemligheter'] = {
    if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { Write-SkipT 'hemligheter: gitleaks saknas'; return }
    $r = New-TestRepo 'secrets' @{}
    Add-Commit $r @{ 'config.txt' = "aws_access_key_id = AKIAZ7Q3M5XWKB4TNPLR`naws_secret_access_key = 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`n" } 'lägg till'
    Add-Commit $r @{ 'config.txt' = "aws_access_key_id =`n" } 'ta bort'
    Assert-Hook 'hemlighet tillagd och borttagen i historiken: fel' (Invoke-Hook $r) 1 @('möjliga hemligheter')
}

foreach ($name in $scenarios.Keys) {
    if (-not (Test-Selected $name)) { continue }
    $t0 = Get-Date
    try { & $scenarios[$name] }
    catch { Write-Fail "${name}: $($_.Exception.Message)" }
    Write-Host "$E[90m       (${name}: $([int]((Get-Date) - $t0).TotalSeconds)s)$E[0m"
}

Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
if ($Keep) { Write-Host "`nTestrepona finns kvar i $Work" }
else { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n$($script:Passed) ok, $($script:Failed) fel, $($script:Skipped) överhoppade"
if ($script:Failed -gt 0) { exit 1 }
exit 0
