<#
.SYNOPSIS
    Sätter upp PowerShell-terminalen: Oh My Posh-prompt med git-status, Nerd Font,
    posh-git, Terminal-Icons och git-guard-profilen med egna kommandon.

.DESCRIPTION
    Kör i PowerShell 7 (pwsh):   .\install-terminal.ps1
    Skriptet kan köras flera gånger - det som redan finns hoppas över.

      -SkipApps     Installera inte program via winget (Oh My Posh, PowerShell 7)
      -SkipFont     Installera inte Nerd Font och ändra inte Windows Terminal
      -Theme <namn> Oh My Posh-tema (standard: atomic). Se https://ohmyposh.dev/docs/themes
                    Ett befintligt terminal/theme.omp.json skrivs bara över om -Theme anges.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipApps,
    [switch]$SkipFont,
    [string]$Theme = 'atomic',
    [string]$FontName = 'Meslo',
    [string]$FontFace = 'MesloLGM Nerd Font'
)

$ErrorActionPreference = 'Stop'
$IsWin  = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Source = $PSScriptRoot
$GGHome = if ($env:GIT_GUARD_HOME) { $env:GIT_GUARD_HOME } else { Join-Path $HOME '.git-guard' }

function Write-Stage([string]$m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Good([string]$m)  { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Note([string]$m)  { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Update-SessionPath {
    if ($IsWin) { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
}
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$wingetArgs = @('--accept-package-agreements', '--accept-source-agreements', '-e', '--silent', '-s', 'winget')

# --- 1. PowerShell 7 ---------------------------------------------------------
Write-Stage '1/6 PowerShell 7'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue) -and $hasWinget -and -not $SkipApps) {
        if ($PSCmdlet.ShouldProcess('PowerShell 7', 'winget install')) { winget install --id Microsoft.PowerShell @wingetArgs }
    }
    Write-Note 'Du kör Windows PowerShell 5.1. Öppna "PowerShell 7" (pwsh) och kör skriptet igen därifrån.'
    Write-Note 'Tips: i Windows Terminal, välj PowerShell som standardprofil under Inställningar > Start.'
    return
}
Write-Good "PowerShell $($PSVersionTable.PSVersion)"

# --- 2. git-guard-filer ------------------------------------------------------
Write-Stage '2/6 git-guard-filer'
$profileSrc = Join-Path $Source 'terminal/profile.ps1'
if ([IO.Path]::GetFullPath($Source).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($GGHome).TrimEnd('\', '/')) {
    if (-not (Test-Path -LiteralPath $profileSrc)) { throw "Hittar inte terminal/profile.ps1 bredvid skriptet ($Source)." }
    if ($PSCmdlet.ShouldProcess($GGHome, 'Kopiera git-guard')) {
        New-Item -ItemType Directory -Path $GGHome -Force | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -ne '.git' }) {
            Copy-Item -LiteralPath $item.FullName -Destination $GGHome -Recurse -Force
        }
    }
}
Write-Good "Filer i $GGHome"

# --- 3. Oh My Posh -----------------------------------------------------------
Write-Stage '3/6 Oh My Posh (prompt med git-status)'
if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    if ($SkipApps) { Write-Note 'Hoppar över (-SkipApps)' }
    elseif ($hasWinget) {
        if ($PSCmdlet.ShouldProcess('Oh My Posh', 'winget install')) { winget install --id JanDeDobbeleer.OhMyPosh @wingetArgs; Update-SessionPath }
    } elseif (Get-Command brew -ErrorAction SilentlyContinue) { brew install jandedobbeleer/oh-my-posh/oh-my-posh }
    else { Write-Note 'Installera manuellt: https://ohmyposh.dev/docs/installation' }
}
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) { Write-Good "Oh My Posh $(oh-my-posh version)" }

$themeFile = Join-Path $GGHome 'terminal/theme.omp.json'
$themeUrl = "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/$Theme.omp.json"
if ((Test-Path -LiteralPath $themeFile) -and -not $PSBoundParameters.ContainsKey('Theme')) {
    Write-Good 'Behåller ditt tema (terminal/theme.omp.json). Byt med: .\install-terminal.ps1 -Theme <namn>'
} elseif ($PSCmdlet.ShouldProcess($themeFile, "Hämta tema '$Theme'")) {
    try {
        # Ladda ned till en tempfil först så att en avbruten nedladdning inte förstör temat
        $tmpTheme = "$themeFile.download"
        Invoke-WebRequest -Uri $themeUrl -OutFile $tmpTheme -UseBasicParsing
        Move-Item -LiteralPath $tmpTheme -Destination $themeFile -Force
        Write-Good "Tema: $Theme"
    } catch {
        Remove-Item -LiteralPath "$themeFile.download" -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $themeFile) { Write-Note "Kunde inte hämta '$Theme' - behåller befintligt tema" }
        else { Write-Note "Kunde inte hämta tema '$Theme' - Oh My Posh standardtema används" }
    }
}

# --- 4. Nerd Font + Windows Terminal -----------------------------------------
Write-Stage '4/6 Typsnitt (Nerd Font för ikoner)'
if ($SkipFont) { Write-Note 'Hoppar över (-SkipFont)' }
elseif (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($FontName, 'oh-my-posh font install')) {
        oh-my-posh font install $FontName
        Write-Good "Typsnitt installerat: $FontFace"
    }
    $wtSettings = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { $IsWin -and (Test-Path -LiteralPath $_) }
    foreach ($file in $wtSettings) {
        try {
            $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if (-not $json.profiles.PSObject.Properties['defaults']) { $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
            $defaults = $json.profiles.defaults
            if (-not $defaults.PSObject.Properties['font']) { $defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) }
            if ($defaults.font.PSObject.Properties['face'] -and $defaults.font.face -eq $FontFace) { Write-Good 'Windows Terminal använder redan typsnittet'; continue }
            if ($PSCmdlet.ShouldProcess($file, "Sätt typsnitt '$FontFace'")) {
                Copy-Item -LiteralPath $file -Destination "$file.git-guard.bak" -Force
                $defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $FontFace -Force
                $json | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $file -Encoding utf8
                Write-Good "Windows Terminal: typsnitt satt (backup: settings.json.git-guard.bak)"
            }
        } catch {
            Write-Note "Kunde inte ändra $file automatiskt. Gör så här: Windows Terminal > Inställningar > Standardinställningar > Utseende > Teckensnitt = $FontFace"
        }
    }
    Write-Note "VS Code: lägg till  `"terminal.integrated.fontFamily`": `"$FontFace`"  i settings.json"
}

# --- 5. PowerShell-moduler ---------------------------------------------------
Write-Stage '5/6 Moduler (posh-git, Terminal-Icons)'
foreach ($m in @('posh-git', 'Terminal-Icons')) {
    if (Get-Module -ListAvailable -Name $m) { Write-Good "$m finns redan"; continue }
    if ($PSCmdlet.ShouldProcess($m, 'Install-Module')) {
        try { Install-Module $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop; Write-Good "$m installerad" }
        catch { Write-Note "Kunde inte installera $m`: $($_.Exception.Message)" }
    }
}

# --- 6. Profil ---------------------------------------------------------------
Write-Stage '6/6 PowerShell-profil'
$profileFile = $PROFILE.CurrentUserAllHosts
$line = '. (Join-Path $HOME ''.git-guard/terminal/profile.ps1'')   # git-guard-profile'
if ($env:GIT_GUARD_HOME) { $line = ". '$((Join-Path $GGHome 'terminal/profile.ps1'))'   # git-guard-profile" }
$existing = if (Test-Path -LiteralPath $profileFile) { Get-Content -LiteralPath $profileFile -Raw } else { '' }
if ($existing -match 'git-guard-profile') {
    Write-Good "Redan inkopplad i $profileFile"
} elseif ($PSCmdlet.ShouldProcess($profileFile, 'Lägg till git-guard-profilen')) {
    New-Item -ItemType Directory -Path (Split-Path $profileFile -Parent) -Force | Out-Null
    Add-Content -LiteralPath $profileFile -Value "`n$line" -Encoding utf8
    Write-Good "Inkopplad i $profileFile"
}

Write-Host "`nKlart! Stäng och öppna Windows Terminal igen." -ForegroundColor Green
Write-Host "Skriv 'aliases' för att se dina kommandon och 'gg' för att köra git-guard utan att pusha." -ForegroundColor DarkGray
