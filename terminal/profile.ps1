# git-guard PowerShell-profil
# Laddas från $PROFILE av install-terminal.ps1 - behöver aldrig ändras.
# Egna tillägg lägger du i ~/.git-guard/terminal/my-commands.ps1 (skapa den med 'ggedit').
# Den filen skrivs aldrig över vid uppdatering.
#
# Allt definieras globalt (function global:, $global:) så att 'reload' och 'ggupdate' kan
# ladda om profilen inifrån en funktion.

$global:GGHome = if ($env:GIT_GUARD_HOME) { $env:GIT_GUARD_HOME } else { Join-Path $HOME '.git-guard' }
$ggTerminal = Join-Path $GGHome 'terminal'

# --- Prompt (Oh My Posh) -----------------------------------------------------
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $theme = Join-Path $ggTerminal 'theme.omp.json'
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

# --- Hjälpfunktioner för git-guard -------------------------------------------
function global:Find-GitBash {
    if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { return 'bash' }
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    $candidates = @()
    if ($git) { $candidates += Join-Path (Split-Path (Split-Path $git -Parent) -Parent) 'bin\bash.exe' }
    $candidates += "$env:ProgramFiles\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'Hittar inte Git Bash (bash.exe). Är Git for Windows installerat?'
}

# Kör samma kontroller som git push gör - utan att pusha
function global:Invoke-GitGuard {
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
function global:Invoke-GitGuardDotnet {
    $top = git rev-parse --show-toplevel 2>$null
    if (-not $top) { $top = (Get-Location).Path }
    & (Join-Path $GGHome 'checks/dotnet-check.ps1') -RepoRoot $top @args
}

function global:Switch-GitGuard {
    if (-not (git rev-parse --show-toplevel 2>$null)) { Write-Host 'Inte i ett git-repo' -ForegroundColor Yellow; return }
    $off = (git config --bool gitguard.disable) -eq 'true'
    if ($off) {
        git config --unset gitguard.disable
        Write-Host 'git-guard PÅ i detta repo. Stäng av igen: guard' -ForegroundColor Green
    } else {
        git config gitguard.disable true
        Write-Host 'git-guard AV i detta repo (inga kontroller vid push). Slå på igen: guard' -ForegroundColor Yellow
    }
}

function global:Remove-GoneBranches {
    git fetch -p
    git branch -vv | Select-String ': gone]' | ForEach-Object {
        $name = (($_.Line.TrimStart('*').Trim()) -split '\s+')[0]
        git branch -D $name
    }
}

# Fler kommandon (git, .NET, Azure), navigering och hjälp
foreach ($part in @('commands.ps1', 'navigation.ps1', 'help.ps1')) {
    $file = Join-Path $ggTerminal $part
    if (Test-Path -LiteralPath $file) { . $file }
}

# --- Kommandon (visas med 'gghelp kommandon') ---------------------------------
# Cmd = vad som körs, Desc = kort text, Help = längre text med exempel (valfri),
# Group = rubrik i listan (valfri, standard 'Egna').
$global:MyCommands = [ordered]@{
    # git
    'gs'      = @{ Group = 'git'; Cmd = { git status -sb }; Desc = 'Kort git status' }
    'gl'      = @{ Group = 'git'; Cmd = { git log --oneline --graph --decorate -15 @args }; Desc = 'Senaste commits som graf' }
    'gd'      = @{ Group = 'git'; Cmd = { git diff @args }; Desc = 'Visa ändringar som inte är stagade' }
    'gds'     = @{ Group = 'git'; Cmd = { git diff --staged @args }; Desc = 'Visa det som är stagat (kommer med i nästa commit)' }
    'gsw'     = @{ Group = 'git'; Cmd = { param([Parameter(Position = 0)][string]$Branch, [Parameter(ValueFromRemainingArguments = $true)]$Rest) git switch $Branch @Rest }; Desc = 'Byt branch (tab kompletterar)'; Help = "Exempel: gsw feature/login`n         gsw -      (tillbaka till förra branchen)" }
    'gco'     = @{ Group = 'git'; Cmd = { git checkout @args }; Desc = 'git checkout' }
    'gnb'     = @{ Group = 'git'; Cmd = { New-GGBranch @args }; Desc = 'Ny branch från senaste main/master på servern'; Help = "Hämtar senaste standardbranchen från servern och skapar en ny branch från den.`nExempel: gnb feature/login" }
    'gsync'   = @{ Group = 'git'; Cmd = { Sync-GGBranch }; Desc = 'Hämta och lägg din branch ovanpå senaste main/master'; Help = "git fetch + git rebase --autostash origin/<standardbranch>.`nVid konflikt: lös, git add, git rebase --continue (eller git rebase --abort)." }
    'gamend'  = @{ Group = 'git'; Cmd = { Invoke-GGAmend @args }; Desc = 'Lägg stagade ändringar i senaste commit (samma meddelande)' }
    'gundo'   = @{ Group = 'git'; Cmd = { Undo-GGCommit }; Desc = 'Ångra senaste commit men behåll ändringarna'; Help = 'git reset --soft HEAD~1. Frågar först om commiten redan är pushad.' }
    'gst'     = @{ Group = 'git'; Cmd = { git stash push @args }; Desc = 'Lägg undan ändringar (stash)' }
    'gstp'    = @{ Group = 'git'; Cmd = { git stash pop @args }; Desc = 'Ta tillbaka undanlagda ändringar' }
    'gp'      = @{ Group = 'git'; Cmd = { git push @args }; Desc = 'Push (kör git-guard)' }
    'gpnt'    = @{ Group = 'git'; Cmd = { Invoke-GGPushNoTests @args }; Desc = 'Push utan tester, bara den här gången'; Help = 'Sätter SKIP_TESTS bara för den här pushen. Övriga kontroller körs som vanligt.' }
    'gpf'     = @{ Group = 'git'; Cmd = { git push --force-with-lease @args }; Desc = 'Säker force-push (efter rebase/amend)' }
    'gpr'     = @{ Group = 'git'; Cmd = { Open-GGPullRequest }; Desc = 'Öppna "skapa PR" i webbläsaren (Azure DevOps/GitHub)'; Help = "Bygger länken från remote-URL:en. Pusha branchen först (gp -u origin HEAD)." }
    'gweb'    = @{ Group = 'git'; Cmd = { Open-GGRepoWeb }; Desc = 'Öppna repot (aktuell branch) i webbläsaren' }
    'gclean'  = @{ Group = 'git'; Cmd = { Remove-GoneBranches }; Desc = 'Ta bort lokala brancher som är borta på servern' }
    # .NET
    'db'      = @{ Group = '.NET'; Cmd = { dotnet build @args }; Desc = 'dotnet build' }
    'dr'      = @{ Group = '.NET'; Cmd = { dotnet run @args }; Desc = 'dotnet run' }
    'dw'      = @{ Group = '.NET'; Cmd = { dotnet watch @args }; Desc = 'dotnet watch' }
    'dt'      = @{ Group = '.NET'; Cmd = { dotnet test --nologo -v q @args }; Desc = 'dotnet test' }
    'dclean'  = @{ Group = '.NET'; Cmd = { Remove-GGBinObj @args }; Desc = 'Ta bort alla bin/ och obj/ i repot (frågar först)'; Help = "Tar bara bort bin/ och obj/ som ligger bredvid en projektfil.`nLöser ofta konstiga build- och NuGet-fel. dclean -Yes hoppar över frågan." }
    'dout'    = @{ Group = '.NET'; Cmd = { dotnet list package --outdated @args }; Desc = 'Visa paket som har nyare versioner' }
    'dvuln'   = @{ Group = '.NET'; Cmd = { dotnet list package --vulnerable --include-transitive @args }; Desc = 'Visa sårbara paket (även transitiva)' }
    'nugetclear' = @{ Group = '.NET'; Cmd = { Clear-GGNuGet }; Desc = 'Töm NuGet-cachen (frågar först)' }
    'sln'     = @{ Group = '.NET'; Cmd = { Open-GGSolution }; Desc = 'Öppna repots .sln i Visual Studio' }
    # Azure
    'azs'     = @{ Group = 'Azure'; Cmd = { Invoke-GGAz account show -o table }; Desc = 'Aktiv Azure-subscription' }
    'azl'     = @{ Group = 'Azure'; Cmd = { Invoke-GGAz login @args }; Desc = 'Logga in i Azure CLI' }
    'azset'   = @{ Group = 'Azure'; Cmd = { param([Parameter(Position = 0)][string]$Name) Set-GGAzSubscription $Name }; Desc = 'Byt subscription (tab kompletterar)'; Help = 'Exempel: azset "Min subscription"' }
    # Navigering
    'repo'    = @{ Group = 'Navigering'; Cmd = { param([Parameter(Position = 0)][string]$Name) Enter-GGRepo $Name }; Desc = 'Hoppa till ett repo via namn (tab kompletterar)'; Help = "Exempel: repo api     (räcker med en del av namnet)`nRepon letas under gitguard.repoRoots (standard ~/source/repos). Se: gghelp repo" }
    'repos'   = @{ Group = 'Navigering'; Cmd = { Show-GGRepos @args }; Desc = 'Lista repon (-Status: branch och ändringar, -Refresh: sök igen)' }
    'mark'    = @{ Group = 'Navigering'; Cmd = { Add-GGBookmark @args }; Desc = 'Spara aktuell mapp som bokmärke (-Alias: skapa kommando)'; Help = "Exempel: mark loggar          (sedan: jump loggar)`n         mark api -Alias      (skapar även kommandot 'api')" }
    'jump'    = @{ Group = 'Navigering'; Cmd = { param([Parameter(Position = 0)][string]$Name) Enter-GGBookmark $Name }; Desc = 'Hoppa till ett bokmärke (tab kompletterar)' }
    'marks'   = @{ Group = 'Navigering'; Cmd = { Show-GGBookmarks }; Desc = 'Lista bokmärken' }
    'unmark'  = @{ Group = 'Navigering'; Cmd = { param([Parameter(Position = 0)][string]$Name) Remove-GGBookmark $Name }; Desc = 'Ta bort ett bokmärke' }
    # git-guard
    'gg'      = @{ Group = 'git-guard'; Cmd = { Invoke-GitGuard }; Desc = 'Kör git-guard-kontrollerna utan att pusha'; Help = "Samma kontroller som vid git push, för HEAD. Repots egna hooks körs inte.`nEn grön körning sparas, så att en push direkt efteråt går fort." }
    'ggnet'   = @{ Group = 'git-guard'; Cmd = { Invoke-GitGuardDotnet @args }; Desc = 'Kör bara .NET-kontrollerna på hela repot'; Help = "Parametrar: -SkipTests -SkipFormat -SkipBuild -Detailed -FormatMode style -DriftLevel warn`nRäknar alla problem som fel, även de som fanns innan." }
    'guard'   = @{ Group = 'git-guard'; Cmd = { Switch-GitGuard }; Desc = 'Slå av/på git-guard i aktuellt repo' }
    'ggstatus' = @{ Group = 'git-guard'; Cmd = { Show-GitGuardStatus }; Desc = 'Är git-guard aktivt här? Vilka verktyg saknas?' }
    'gghelp'  = @{ Group = 'git-guard'; Cmd = { param([Parameter(Position = 0)][string]$Topic) Show-GitGuardHelp $Topic }; Desc = 'Hjälp: gghelp [kommandon|inställningar|steg|felsökning|repo|readme|<kommando>]' }
    'ggupdate' = @{ Group = 'git-guard'; Cmd = { Update-GitGuard }; Desc = 'Uppdatera git-guard (git pull) och ladda om' }
    'ggedit'  = @{ Group = 'git-guard'; Cmd = { Edit-GGMyCommands }; Desc = 'Öppna dina egna kommandon (my-commands.ps1)' }
    'reload'  = @{ Group = 'git-guard'; Cmd = { Import-GitGuardProfile }; Desc = 'Ladda om profilen utan att starta om terminalen' }
    'aliases' = @{ Group = 'git-guard'; Cmd = { Show-GitGuardHelp kommandon }; Desc = 'Samma som gghelp kommandon' }
}

# Egna tillägg, t.ex.  $MyCommands['kod'] = @{ Cmd = { code . }; Desc = 'Öppna VS Code här' }
$myExtra = Join-Path $ggTerminal 'my-commands.ps1'
if (Test-Path -LiteralPath $myExtra) { . $myExtra }

# Inbyggda alias (t.ex. gp = Get-ItemProperty, gl = Get-Location) går före funktioner och
# måste tas bort först, annars körs aliaset i stället för kommandot.
foreach ($k in $MyCommands.Keys) {
    if (Test-Path -LiteralPath "Alias:$k") { Remove-Item -LiteralPath "Alias:$k" -Force -ErrorAction SilentlyContinue }
    Set-Item "function:global:$k" $MyCommands[$k].Cmd
}

if (Get-Command Register-GGCompleters -ErrorAction SilentlyContinue) { Register-GGCompleters }
if (Get-Command Register-GGBookmarkAliases -ErrorAction SilentlyContinue) { Register-GGBookmarkAliases }

# Startmeddelande: hela listan i Windows Terminal, en rad i andra interaktiva fönster.
# gitguard.startup = full | short | off (git config --global gitguard.startup short)
if (Get-Command Show-GitGuardStartup -ErrorAction SilentlyContinue) { Show-GitGuardStartup }
