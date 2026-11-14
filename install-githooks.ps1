<#
.SYNOPSIS
    Installerar git-guard (pre-push-kontroller) globalt eller i valda repon.

.DESCRIPTION
    Kör utan parametrar för en enkel meny:   .\install-githooks.ps1

    Skriptet kopierar hela paketet till ~/.git-guard och kopplar sedan in hooken:
      -Global          core.hooksPath = ~/.git-guard/hooks (alla repon utan egen hooksPath)
      -Path <mapp>     Letar upp repon och lägger hooken i varje repos .git/hooks.
                       En befintlig pre-push döps om till pre-push.local och körs ändå.
      -Depth <n>       Hur djupt -Path letar efter repon (standard 3).
      -Interactive     Fråga för varje repo.
      -InstallTools    Installera sqlfluff, yamllint, actionlint och gitleaks (och PowerShell 7 om det saknas).
      -Uninstall       Ta bort hooken. Med -Purge tas även ~/.git-guard bort.
      -Force           Ersätt en global core.hooksPath som pekar någon annanstans (t.ex. husky).
      -WhatIf          Visa vad som skulle hända utan att ändra något.

    Kör skriptet igen när du fått en ny version - allt skrivs över och uppdateras.

.EXAMPLE
    .\install-githooks.ps1 -Global -InstallTools
.EXAMPLE
    .\install-githooks.ps1 -Path C:\src -Interactive
.EXAMPLE
    .\install-githooks.ps1 -Global -Uninstall -Purge
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Global,
    [string[]]$Path,
    [int]$Depth = 3,
    [switch]$Interactive,
    [switch]$InstallTools,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Marker   = '# git-guard pre-push hook'
$PassMarker = '# git-guard passthrough hook'
$IsWin    = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Source   = $PSScriptRoot
$GGHome   = if ($env:GIT_GUARD_HOME) { $env:GIT_GUARD_HOME } else { Join-Path $HOME '.git-guard' }
$HooksDir = Join-Path $GGHome 'hooks'

function Write-Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-Good([string]$m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Note([string]$m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

function Test-OurHook([string]$File) {
    (Test-Path -LiteralPath $File -PathType Leaf) -and
    ((Get-Content -LiteralPath $File -TotalCount 3 -ErrorAction SilentlyContinue) -contains $Marker)
}

function Get-GitValue([string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'   # PS 5.1 kastar annars fel vid stderr från git
    $out = & git @GitArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1).Trim() }
    return $null
}

function Set-Executable([string]$File) { if (-not $IsWin) { & chmod +x $File } }

# Bash-hooks måste ha LF-radslut (även i Git for Windows) - rättas automatiskt
function Copy-Hook([string]$From, [string]$To) {
    $dir = Split-Path $To -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = [IO.File]::ReadAllText($From) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($To, $text, (New-Object System.Text.UTF8Encoding $false))
    Set-Executable $To
}

# Kopierar alla hooks till ~/.git-guard/hooks med LF-radslut. En hook med samma namn som
# användaren lagt dit själv skrivs inte över (en git-lfs-hook får ersättas: passthrough-
# skriptet kör git lfs själv).
function Copy-AllHooks {
    foreach ($h in Get-ChildItem -LiteralPath (Join-Path $Source 'hooks') -File) {
        $dest = Join-Path $HooksDir $h.Name
        if (Test-Path -LiteralPath $dest) {
            $head = @(Get-Content -LiteralPath $dest -TotalCount 3 -ErrorAction SilentlyContinue)
            $ours = ($head -contains $Marker) -or ($head -contains $PassMarker)
            $isLfs = [bool](Select-String -LiteralPath $dest -Pattern 'git lfs|git-lfs' -Quiet -ErrorAction SilentlyContinue)
            if (-not $ours -and -not $isLfs) {
                Write-Note "Behåller din egen hooks/$($h.Name) i $HooksDir (git-guard:s version kopieras inte)"
                continue
            }
        }
        Copy-Hook $h.FullName $dest
    }
}

function Install-Package {
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\', '/') -eq [IO.Path]::GetFullPath($GGHome).TrimEnd('\', '/')) {
        Write-Good "Kör från $GGHome - inget att kopiera"
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'hooks/pre-push'))) {
        throw "Hittar inte hooks/pre-push bredvid skriptet ($Source). Packa upp hela git-guard-mappen först."
    }
    if ($PSCmdlet.ShouldProcess($GGHome, 'Kopiera git-guard')) {
        New-Item -ItemType Directory -Path $GGHome -Force | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -notin @('.git', 'hooks') }) {
            Copy-Item -LiteralPath $item.FullName -Destination $GGHome -Recurse -Force
        }
        Copy-AllHooks
        Write-Good "Kopierat till $GGHome"
    }
}

# pip install --user lägger programmet i Pythons användarmapp (Scripts), som ofta saknas i PATH.
# Då hittar hooken inte programmet. Visa i så fall exakt vad som ska läggas till.
function Test-UserScriptsInPath([string]$Py, [string]$Tool) {
    $ErrorActionPreference = 'Continue'
    $scripts = (& $Py -c "import os, sysconfig; print(sysconfig.get_path('scripts', os.name + '_user'))" 2>$null | Select-Object -First 1)
    if (-not $scripts) { return }
    $scripts = $scripts.Trim()
    $inPath = @($env:Path -split [IO.Path]::PathSeparator | Where-Object { $_.TrimEnd('\', '/') -eq $scripts.TrimEnd('\', '/') }).Count -gt 0
    if (-not $inPath -and -not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        Write-Note "$Tool installerades i $scripts, men den mappen finns inte i PATH."
        Write-Note "Rätta: lägg till mappen i PATH (Inställningar > System > Om > Avancerade systeminställningar > Miljövariabler),"
        Write-Note "       eller installera pipx (py -m pip install --user pipx; py -m pipx ensurepath) och kör -InstallTools igen."
    }
}

function Install-Tools {
    Write-Info "`nInstallerar verktyg"
    $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $wingetArgs = @('--accept-package-agreements', '--accept-source-agreements', '-e', '--silent')

    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        if ($hasWinget -and $PSCmdlet.ShouldProcess('PowerShell 7', 'winget install')) {
            winget install --id Microsoft.PowerShell @wingetArgs
        } else { Write-Note 'Installera PowerShell 7: https://aka.ms/powershell' }
    }
    if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        if ($hasWinget -and $PSCmdlet.ShouldProcess('gitleaks', 'winget install')) {
            winget install --id Gitleaks.Gitleaks @wingetArgs
        } elseif (Get-Command brew -ErrorAction SilentlyContinue) { brew install gitleaks }
        else { Write-Note 'Installera gitleaks: https://github.com/gitleaks/gitleaks' }
    }
    if (-not (Get-Command actionlint -ErrorAction SilentlyContinue)) {
        if ($hasWinget -and $PSCmdlet.ShouldProcess('actionlint', 'winget install')) {
            winget install --id rhysd.actionlint @wingetArgs
        } elseif (Get-Command brew -ErrorAction SilentlyContinue) { brew install actionlint }
        else { Write-Note 'Installera actionlint: https://github.com/rhysd/actionlint' }
    }
    $pyTools = @(@('sqlfluff', 'yamllint') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    $py = @('py', 'python', 'python3') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    $hasPipx = [bool](Get-Command pipx -ErrorAction SilentlyContinue)
    if ($pyTools.Count -gt 0 -and -not $hasPipx -and -not $py) {
        if ($hasWinget) { Write-Note "Python saknas ($($pyTools -join ', ')). Kör: winget install -e --id Python.Python.3.12   och sedan skriptet igen" }
        else { Write-Note "Installera Python och kör: pip install $($pyTools -join ' ')" }
        $pyTools = @()
    }
    foreach ($tool in $pyTools) {
        if ($hasPipx -and $PSCmdlet.ShouldProcess($tool, 'pipx install')) {
            # pipx lägger programmet i en mapp som redan finns i PATH (pipx ensurepath)
            pipx install $tool
        } elseif (-not $hasPipx -and $PSCmdlet.ShouldProcess($tool, 'pip install')) {
            & $py -m pip install --user --upgrade $tool
            Test-UserScriptsInPath $py $tool
        }
    }
    # Hämta nya PATH-värden så att nyinstallerade verktyg hittas direkt
    if ($IsWin) {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}

function Show-Tools {
    Write-Info "`nVerktyg som git-guard använder (saknade hoppas över):"
    $tools = [ordered]@{
        git      = 'krävs'
        dotnet   = '.NET-kontroller'
        pwsh     = 'rekommenderas för .NET-kontrollerna (annars Windows PowerShell)'
        sqlfluff = 'SQL-lint'
        yamllint = 'YAML-syntax och regler'
        actionlint = 'GitHub Actions-workflows'
        gitleaks = 'hemlighetssökning'
    }
    foreach ($t in $tools.Keys) {
        if (Get-Command $t -ErrorAction SilentlyContinue) { Write-Host "  [x] $t" -ForegroundColor Green -NoNewline }
        else { Write-Host "  [ ] $t" -ForegroundColor DarkGray -NoNewline }
        Write-Host "  - $($tools[$t])" -ForegroundColor DarkGray
    }
    $missing = @('sqlfluff', 'yamllint', 'actionlint', 'gitleaks', 'pwsh') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    if ($missing) { Write-Host "  Installera det som saknas: .\install-githooks.ps1 -InstallTools" -ForegroundColor DarkGray }
}

# --- Meny om inga parametrar angetts ----------------------------------------
if (-not $Global -and -not $Path -and -not $InstallTools) {
    Write-Info 'git-guard - installation'
    Write-Host '  1) Installera globalt för alla repon (rekommenderas)'
    Write-Host '  2) Installera i utvalda repon i en mapp'
    Write-Host '  3) Installera verktyg (sqlfluff, yamllint, actionlint, gitleaks, PowerShell 7)'
    Write-Host '  4) Avinstallera globalt'
    switch ((Read-Host 'Välj 1-4').Trim()) {
        '1' { $Global = $true; $InstallTools = ((Read-Host 'Installera även verktyg? [J/n]') -notmatch '^n') }
        '2' { $Path = @(Read-Host 'Mapp att söka i (t.ex. C:\src)'); $Interactive = $true }
        '3' { $InstallTools = $true }
        '4' { $Global = $true; $Uninstall = $true }
        default { Write-Host 'Avbryter.'; return }
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git hittades inte i PATH.' }

# --- Avinstallation globalt --------------------------------------------------
if ($Uninstall -and $Global) {
    $current = Get-GitValue @('config', '--global', 'core.hooksPath')
    if ($current -and ([IO.Path]::GetFullPath($current) -eq [IO.Path]::GetFullPath($HooksDir) -or (Test-OurHook (Join-Path $current 'pre-push')))) {
        if ($PSCmdlet.ShouldProcess('global git config', 'unset core.hooksPath')) { git config --global --unset core.hooksPath }
        Write-Good 'core.hooksPath borttagen'
    }
    if ($Purge -and (Test-Path -LiteralPath $GGHome) -and $PSCmdlet.ShouldProcess($GGHome, 'Ta bort')) {
        Remove-Item -LiteralPath $GGHome -Recurse -Force
        Write-Good "$GGHome borttagen"
    }
    Write-Info 'git-guard avinstallerad globalt.'
    return
}

if (-not $Uninstall) { Install-Package }
if ($InstallTools) { Install-Tools }

# --- Globalt -----------------------------------------------------------------
if ($Global) {
    $gitPath = $HooksDir -replace '\\', '/'
    $current = Get-GitValue @('config', '--global', 'core.hooksPath')
    $isOurs  = $current -and (($current -replace '\\', '/').TrimEnd('/') -eq $gitPath.TrimEnd('/') -or (Test-OurHook (Join-Path $current 'pre-push')))
    if ($current -and -not $isOurs -and -not $Force) {
        throw "core.hooksPath är redan satt globalt till '$current'. Kör med -Force för att ersätta."
    }
    if ($PSCmdlet.ShouldProcess('global git config', "core.hooksPath = $gitPath")) {
        git config --global core.hooksPath $gitPath
        Write-Good "Global hook aktiv: $gitPath"
        Write-Note 'Repon med egen core.hooksPath (t.ex. husky) använder inte den globala hooken.'
        Write-Note 'Repots egna hooks i .git/hooks (pre-commit, commit-msg, git-lfs m.fl.) körs fortfarande via git-guard.'
    }
}

# --- Per repo ----------------------------------------------------------------
if ($Path) {
    $hookSource = Join-Path $HooksDir 'pre-push'
    $repos = foreach ($root in $Path) {
        $resolved = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
        if (-not $resolved) { Write-Warning "Finns inte: $root"; continue }
        Get-ChildItem -LiteralPath $resolved -Filter '.git' -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|bin|obj)[\\/]' } |
            ForEach-Object { Split-Path $_.FullName -Parent }
    }
    $repos = @($repos | Sort-Object -Unique)
    if ($repos.Count -eq 0) { Write-Warning 'Inga git-repon hittades.'; return }
    Write-Info "`nHittade $($repos.Count) repo(n)."

    $yesToAll = $false
    $result = foreach ($repo in $repos) {
        $name = Split-Path $repo -Leaf
        if ($Interactive -and -not $yesToAll) {
            $verb = if ($Uninstall) { 'Avinstallera i' } else { 'Installera i' }
            $answer = "$(Read-Host "$verb $repo ? [j]a / [n]ej / [a]lla / [q]avbryt")".Trim().ToLower()
            if ($answer -match '^(q|avbryt)$') { break }
            if ($answer -match '^(a|alla)$') { $yesToAll = $true }
            elseif ($answer -notmatch '^(j|ja|y|yes)$') { [pscustomobject]@{ Repo = $name; Resultat = 'Hoppade över' }; continue }
        }

        $commonDir = Get-GitValue @('-C', $repo, 'rev-parse', '--git-common-dir')
        if (-not $commonDir) { [pscustomobject]@{ Repo = $name; Resultat = 'Inte ett giltigt repo' }; continue }
        if (-not [IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $repo $commonDir }
        $target = Join-Path $commonDir 'hooks/pre-push'
        $local  = Join-Path $commonDir 'hooks/pre-push.local'

        $localHooksPath = Get-GitValue @('-C', $repo, 'config', '--local', 'core.hooksPath')
        if ($localHooksPath -and -not $Uninstall) {
            [pscustomobject]@{ Repo = $name; Resultat = "Hoppade över: egen core.hooksPath ($localHooksPath)" }; continue
        }

        if ($Uninstall) {
            $status = 'Ingen git-guard-hook'
            if ((Test-OurHook $target) -and $PSCmdlet.ShouldProcess($target, 'Ta bort')) {
                Remove-Item -LiteralPath $target
                $status = 'Borttagen'
                if (Test-Path -LiteralPath $local) { Move-Item -LiteralPath $local -Destination $target; $status = 'Borttagen, pre-push.local återställd' }
            }
            [pscustomobject]@{ Repo = $name; Resultat = $status }; continue
        }

        $status = 'Installerad'
        if (Test-Path -LiteralPath $target) {
            if (Test-OurHook $target) { $status = 'Uppdaterad' }
            elseif (Test-Path -LiteralPath $local) {
                [pscustomobject]@{ Repo = $name; Resultat = 'Hoppade över: både pre-push och pre-push.local finns' }; continue
            }
            elseif ($PSCmdlet.ShouldProcess($target, 'Döp om befintlig hook till pre-push.local')) {
                Move-Item -LiteralPath $target -Destination $local
                $status = 'Installerad (gammal hook -> pre-push.local)'
            }
        }
        if ($PSCmdlet.ShouldProcess($target, 'Installera pre-push')) { Copy-Hook $hookSource $target }
        else { $status = "WhatIf: $status" }
        [pscustomobject]@{ Repo = $name; Resultat = $status }
    }
    $result | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $globalPath = Get-GitValue @('config', '--global', 'core.hooksPath')
    if ($globalPath -and -not $Uninstall) {
        Write-Note "core.hooksPath är satt globalt ($globalPath) - då används den globala hooken i stället för .git/hooks."
    }
}

if (-not $Uninstall) {
    Show-Tools
    Write-Info "`nKlart! Testa i ett repo:  git push   (eller 'gg' om du installerat terminalprofilen)"
}
