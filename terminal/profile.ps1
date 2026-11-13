# git-guard PowerShell-profil
# Laddas från $PROFILE av install-terminal.ps1 - behöver aldrig ändras.
# Egna tillägg lägger du i ~/.git-guard/terminal/my-commands.ps1 (skapas inte automatiskt,
# och skrivs aldrig över vid uppdatering).

$GGHome = if ($env:GIT_GUARD_HOME) { $env:GIT_GUARD_HOME } else { Join-Path $HOME '.git-guard' }

# --- Prompt (Oh My Posh) -----------------------------------------------------
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $theme = Join-Path $GGHome 'terminal/theme.omp.json'
    if ($env:GITGUARD_POSH_THEME) { $theme = $env:GITGUARD_POSH_THEME }
    elseif (-not (Test-Path -LiteralPath $theme) -and $env:POSH_THEMES_PATH) { $theme = Join-Path $env:POSH_THEMES_PATH 'atomic.omp.json' }
    if (Test-Path -LiteralPath $theme) { oh-my-posh init pwsh --config $theme | Invoke-Expression }
    else { oh-my-posh init pwsh | Invoke-Expression }
}

# --- Moduler -----------------------------------------------------------------
Import-Module posh-git       -ErrorAction SilentlyContinue   # tab completion för git
Import-Module Terminal-Icons -ErrorAction SilentlyContinue   # ikoner i ls/dir
try {
    Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ListView -ErrorAction Stop
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
} catch { }   # äldre PSReadLine (Windows PowerShell 5.1) saknar detta

# --- Hjälpfunktioner ---------------------------------------------------------
function Find-GitBash {
    if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { return 'bash' }
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    $candidates = @()
    if ($git) { $candidates += Join-Path (Split-Path (Split-Path $git -Parent) -Parent) 'bin\bash.exe' }
    $candidates += "$env:ProgramFiles\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'Hittar inte Git Bash (bash.exe). Är Git for Windows installerat?'
}

# Kör samma kontroller som git push gör - utan att pusha
function Invoke-GitGuard {
    $top = git rev-parse --show-toplevel 2>$null
    if (-not $top) { Write-Host 'Inte i ett git-repo' -ForegroundColor Yellow; return }
    $hook = Join-Path $GGHome 'hooks/pre-push'
    if (-not (Test-Path -LiteralPath $hook)) { Write-Host "git-guard är inte installerat ($hook saknas)" -ForegroundColor Yellow; return }
    $branch = git rev-parse --abbrev-ref HEAD
    $sha = git rev-parse HEAD
    $upstream = git rev-parse --abbrev-ref '@{u}' 2>$null
    $remote = if ($upstream) { $upstream.Split('/')[0] } else { 'origin' }
    $env:GITGUARD_DRYRUN = '1'
    try {
        "refs/heads/$branch $sha refs/heads/$branch 0000000000000000000000000000000000000000" |
            & (Find-GitBash) ($hook -replace '\\', '/') $remote
    } finally { Remove-Item Env:GITGUARD_DRYRUN -ErrorAction SilentlyContinue }
}

# Bara .NET-kontrollerna, på hela repot
function Invoke-GitGuardDotnet {
    $top = git rev-parse --show-toplevel 2>$null
    if (-not $top) { $top = (Get-Location).Path }
    & (Join-Path $GGHome 'checks/dotnet-check.ps1') -RepoRoot $top @args
}

function Switch-GitGuard {
    if (-not (git rev-parse --show-toplevel 2>$null)) { Write-Host 'Inte i ett git-repo' -ForegroundColor Yellow; return }
    $off = (git config --bool gitguard.disable) -eq 'true'
    git config gitguard.disable ((-not $off).ToString().ToLower())
    if ($off) { Write-Host 'git-guard PÅ i detta repo' -ForegroundColor Green }
    else { Write-Host 'git-guard AV i detta repo' -ForegroundColor Yellow }
}

function Remove-GoneBranches {
    git fetch -p
    git branch -vv | Select-String ': gone]' | ForEach-Object {
        $name = (($_.Line.TrimStart('*').Trim()) -split '\s+')[0]
        git branch -D $name
    }
}

# --- Egna kommandon (visas vid start och med 'aliases') ----------------------
$MyCommands = [ordered]@{
    'gs'     = @{ Cmd = { git status -sb };                    Desc = 'Kort git status' }
    'gl'     = @{ Cmd = { git log --oneline --graph --decorate -15 }; Desc = 'Senaste commits som graf' }
    'gp'     = @{ Cmd = { git push @args };                    Desc = 'Push (kör git-guard)' }
    'gpf'    = @{ Cmd = { git push --force-with-lease @args }; Desc = 'Säker force-push' }
    'gco'    = @{ Cmd = { git checkout @args };                Desc = 'Byt branch' }
    'gclean' = @{ Cmd = { Remove-GoneBranches };               Desc = 'Ta bort lokala brancher som är borta på remote' }
    'gg'     = @{ Cmd = { Invoke-GitGuard };                   Desc = 'Kör git-guard-kontrollerna utan att pusha' }
    'ggnet'  = @{ Cmd = { Invoke-GitGuardDotnet @args };       Desc = 'Kör bara .NET-kontrollerna på hela repot' }
    'guard'  = @{ Cmd = { Switch-GitGuard };                   Desc = 'Slå av/på git-guard i aktuellt repo' }
    'dt'     = @{ Cmd = { dotnet test --nologo -v q @args };   Desc = 'Kör .NET-tester' }
    'azs'    = @{ Cmd = { az account show -o table };          Desc = 'Aktiv Azure-subscription' }
}

# Egna tillägg, t.ex.  $MyCommands['kod'] = @{ Cmd = { code . }; Desc = 'Öppna VS Code här' }
$myExtra = Join-Path $GGHome 'terminal/my-commands.ps1'
if (Test-Path -LiteralPath $myExtra) { . $myExtra }

# Inbyggda alias (t.ex. gp = Get-ItemProperty, gl = Get-Location) går före funktioner och
# måste tas bort först, annars körs aliaset i stället för kommandot.
foreach ($k in $MyCommands.Keys) {
    if (Test-Path -LiteralPath "Alias:$k") { Remove-Item -LiteralPath "Alias:$k" -Force -ErrorAction SilentlyContinue }
    Set-Item "function:global:$k" $MyCommands[$k].Cmd
}

function aliases {
    Write-Host "`n  Mina kommandon" -ForegroundColor Cyan
    foreach ($k in $MyCommands.Keys) {
        Write-Host ("  {0,-8}" -f $k) -ForegroundColor Yellow -NoNewline
        Write-Host $MyCommands[$k].Desc -ForegroundColor DarkGray
    }
    $hp = git config --global core.hooksPath 2>$null
    if ($hp -and (Test-Path -LiteralPath (Join-Path $hp 'pre-push'))) {
        Write-Host '  git-guard: aktiv globalt' -ForegroundColor DarkGreen
    } else {
        Write-Host '  git-guard: inte aktiv globalt' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# Visa listan vid start, bara i Windows Terminal (inte i VS Code eller skript)
if ($env:WT_SESSION) { aliases }
