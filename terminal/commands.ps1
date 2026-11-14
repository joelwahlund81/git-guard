# git-guard: hjälpfunktioner till kommandona i profile.ps1 (git, .NET, Azure, git-guard).
# Laddas av profile.ps1 - behöver aldrig ändras.

function global:Write-GGNote([string]$m) { Write-Host $m -ForegroundColor Yellow }
function global:Write-GGFix([string]$m)  { Write-Host "  Rätta: $m" -ForegroundColor DarkGray }

function global:Test-GGRepo {
    if (git rev-parse --show-toplevel 2>$null) { return $true }
    Write-GGNote 'Inte i ett git-repo'
    return $false
}

# Den remote som används: uppströms-remoten för branchen, annars origin, annars den första
function global:Get-GGRemote {
    $up = git rev-parse --abbrev-ref '@{u}' 2>$null
    if ($up) { return $up.Split('/')[0] }
    $remotes = @(git remote 2>$null)
    if ($remotes -contains 'origin') { return 'origin' }
    if ($remotes.Count -gt 0) { return $remotes[0] }
    return $null
}

# Standardbranchen på servern (main/master/develop ...)
function global:Get-GGDefaultBranch([string]$Remote) {
    if (-not $Remote) { $Remote = Get-GGRemote }
    $head = git symbolic-ref --short "refs/remotes/$Remote/HEAD" 2>$null
    if ($head) { return ($head -replace "^$([regex]::Escape($Remote))/", '') }
    foreach ($b in @('main', 'master', 'develop')) {
        git show-ref --verify --quiet "refs/remotes/$Remote/$b" 2>$null
        if ($LASTEXITCODE -eq 0) { return $b }
    }
    return 'main'
}

function global:New-GGBranch {
    param([Parameter(Position = 0)][string]$Name)
    if (-not (Test-GGRepo)) { return }
    if (-not $Name) { Write-GGNote 'Ange ett namn: gnb feature/mitt-namn'; return }
    $remote = Get-GGRemote
    if (-not $remote) { git switch -c $Name; return }
    $def = Get-GGDefaultBranch $remote
    Write-Host "Hämtar $remote/$def ..." -ForegroundColor DarkGray
    git fetch $remote $def --quiet
    git switch -c $Name "$remote/$def" --no-track
    if ($LASTEXITCODE -eq 0) { Write-Host "Ny branch $Name från $remote/$def. Pusha första gången med: gp -u $remote HEAD" -ForegroundColor Green }
}

function global:Sync-GGBranch {
    if (-not (Test-GGRepo)) { return }
    $remote = Get-GGRemote
    if (-not $remote) { Write-GGNote 'Repot har ingen remote'; return }
    $def = Get-GGDefaultBranch $remote
    git fetch $remote --quiet
    git rebase --autostash "$remote/$def"
    if ($LASTEXITCODE -ne 0) {
        Write-GGNote 'Rebase stoppade på en konflikt.'
        Write-GGFix 'lös konflikten, git add <fil>, git rebase --continue  (eller git rebase --abort för att ångra)'
    } else {
        Write-Host "Din branch ligger nu ovanpå $remote/$def. Var den redan pushad: gpf" -ForegroundColor Green
    }
}

function global:Test-GGHeadPushed {
    $r = @(git branch -r --contains HEAD 2>$null)
    return $r.Count -gt 0
}

function global:Invoke-GGAmend {
    if (-not (Test-GGRepo)) { return }
    if (Test-GGHeadPushed) { Write-GGNote 'Obs: senaste commit är redan pushad. Efter amend måste du pusha med gpf.' }
    git commit --amend --no-edit @args
}

function global:Undo-GGCommit {
    if (-not (Test-GGRepo)) { return }
    $last = git log -1 --format='%h %s' 2>$null
    if (-not $last) { Write-GGNote 'Det finns ingen commit att ångra'; return }
    if (Test-GGHeadPushed) {
        Write-GGNote "Commiten '$last' är redan pushad. Ångrar du den måste du pusha med gpf efteråt."
        $a = Read-Host 'Ångra ändå? [j/N]'
        if ($a -notmatch '^(j|ja|y|yes)$') { Write-Host 'Avbryter.'; return }
    }
    git reset --soft HEAD~1
    if ($LASTEXITCODE -eq 0) { Write-Host "Ångrade '$last'. Ändringarna ligger kvar stagade (gds)." -ForegroundColor Green }
}

function global:Invoke-GGPushNoTests {
    $had = Test-Path Env:SKIP_TESTS
    $old = $env:SKIP_TESTS
    $env:SKIP_TESTS = '1'
    try { git push @args }
    finally { if ($had) { $env:SKIP_TESTS = $old } else { Remove-Item Env:SKIP_TESTS -ErrorAction SilentlyContinue } }
}

# --- Webbläsare: PR och repo -------------------------------------------------
function global:Open-GGUrl([string]$Url) {
    Write-Host $Url -ForegroundColor DarkGray
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { Start-Process $Url }
    elseif ($IsMacOS) { & open $Url }
    else { & xdg-open $Url }
}

# Tolkar remote-URL:en. Ger @{ Kind = 'azure'|'github'; Base = repo-URL } eller $null.
function global:Get-GGRepoWeb([string]$Remote) {
    $url = git remote get-url $Remote 2>$null
    if (-not $url) { return $null }
    $url = $url.Trim() -replace '\.git$', ''
    if ($url -match '^https?://(?:[^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+)') {
        return @{ Kind = 'azure'; Base = "https://dev.azure.com/$($Matches[1])/$($Matches[2])/_git/$($Matches[3])" }
    }
    if ($url -match '^(?:ssh://)?git@ssh\.dev\.azure\.com:(?:v3/)?([^/]+)/([^/]+)/([^/]+)$') {
        return @{ Kind = 'azure'; Base = "https://dev.azure.com/$($Matches[1])/$($Matches[2])/_git/$($Matches[3])" }
    }
    if ($url -match '^https?://(?:[^@/]+@)?([^./]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/?#]+)') {
        return @{ Kind = 'azure'; Base = "https://dev.azure.com/$($Matches[1])/$($Matches[2])/_git/$($Matches[3])" }
    }
    if ($url -match '^[^@]+@vs-ssh\.visualstudio\.com:(?:v3/)?([^/]+)/([^/]+)/([^/]+)$') {
        return @{ Kind = 'azure'; Base = "https://dev.azure.com/$($Matches[1])/$($Matches[2])/_git/$($Matches[3])" }
    }
    if ($url -match '^(?:https?://(?:[^@/]+@)?|git@|ssh://git@)github\.com[:/]([^/]+)/([^/]+)$') {
        return @{ Kind = 'github'; Base = "https://github.com/$($Matches[1])/$($Matches[2])" }
    }
    return $null
}

function global:Open-GGPullRequest {
    if (-not (Test-GGRepo)) { return }
    $remote = Get-GGRemote
    $web = if ($remote) { Get-GGRepoWeb $remote } else { $null }
    if (-not $web) { Write-GGNote 'Känner inte igen remoten (stöd: Azure DevOps och GitHub)'; return }
    $branch = git rev-parse --abbrev-ref HEAD
    $def = Get-GGDefaultBranch $remote
    if ($branch -eq $def) { Write-GGNote "Du står på $def. Skapa en egen branch först: gnb <namn>"; return }
    git rev-parse --abbrev-ref '@{u}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-GGNote "Branchen $branch är inte pushad än."
        Write-GGFix "gp -u $remote HEAD   och kör gpr igen"
        return
    }
    $enc = [uri]::EscapeDataString($branch)
    if ($web.Kind -eq 'azure') {
        Open-GGUrl "$($web.Base)/pullrequestcreate?sourceRef=$enc&targetRef=$([uri]::EscapeDataString($def))"
    } else {
        Open-GGUrl "$($web.Base)/compare/$([uri]::EscapeDataString($def))...$($enc)?expand=1"
    }
}

function global:Open-GGRepoWeb {
    if (-not (Test-GGRepo)) { return }
    $remote = Get-GGRemote
    $web = if ($remote) { Get-GGRepoWeb $remote } else { $null }
    if (-not $web) { Write-GGNote 'Känner inte igen remoten (stöd: Azure DevOps och GitHub)'; return }
    $branch = git rev-parse --abbrev-ref HEAD
    if ($web.Kind -eq 'azure') { Open-GGUrl "$($web.Base)?version=GB$([uri]::EscapeDataString($branch))" }
    else { Open-GGUrl "$($web.Base)/tree/$([uri]::EscapeDataString($branch))" }
}

# --- .NET ----------------------------------------------------------------------
function global:Get-GGRoot {
    $top = git rev-parse --show-toplevel 2>$null
    if ($top) { return $top }
    return (Get-Location).Path
}

function global:Remove-GGBinObj {
    param([switch]$Yes)
    $root = Get-GGRoot
    # Bara bin/obj bredvid en projektfil, så att t.ex. en bin-mapp med skript inte tas bort
    # (-Include fungerar inte med -LiteralPath i Windows PowerShell 5.1, därför Where-Object)
    $projDirs = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.csproj', '.fsproj', '.vbproj') -and $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' } |
        ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
    $dirs = @(foreach ($d in $projDirs) {
        foreach ($n in @('bin', 'obj')) { $p = Join-Path $d $n; if (Test-Path -LiteralPath $p -PathType Container) { $p } }
    })
    if ($dirs.Count -eq 0) { Write-Host 'Inga bin/ eller obj/ att ta bort' -ForegroundColor Green; return }
    Write-Host "Tar bort $($dirs.Count) mapp(ar):" -ForegroundColor Cyan
    $dirs | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.Substring($root.Length).TrimStart('\', '/'))" -ForegroundColor DarkGray }
    if ($dirs.Count -gt 20) { Write-Host "  ... och $($dirs.Count - 20) till" -ForegroundColor DarkGray }
    if (-not $Yes) {
        $a = Read-Host 'Ta bort? [j/N]'
        if ($a -notmatch '^(j|ja|y|yes)$') { Write-Host 'Avbryter.'; return }
    }
    foreach ($d in $dirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host 'Klart. Kör dotnet restore (eller db) igen.' -ForegroundColor Green
}

function global:Clear-GGNuGet {
    $a = Read-Host 'Tömma hela NuGet-cachen? Nästa restore laddar ned allt igen. [j/N]'
    if ($a -notmatch '^(j|ja|y|yes)$') { Write-Host 'Avbryter.'; return }
    dotnet nuget locals all --clear
}

function global:Open-GGSolution {
    $root = Get-GGRoot
    $wanted = git config --get gitguard.solution 2>$null
    $sln = $null
    if ($wanted -and (Test-Path -LiteralPath (Join-Path $root $wanted))) { $sln = Get-Item -LiteralPath (Join-Path $root $wanted) }
    if (-not $sln) {
        $sln = @(Get-ChildItem -Path (Join-Path $root '*') -File -Include '*.sln', '*.slnx' -ErrorAction SilentlyContinue) +
               @(Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.sln', '.slnx') }) |
               Select-Object -First 1
    }
    if (-not $sln) { Write-GGNote "Hittar ingen .sln/.slnx i $root"; return }
    Write-Host "Öppnar $($sln.Name)" -ForegroundColor DarkGray
    Invoke-Item -LiteralPath $sln.FullName
}

# --- Azure -----------------------------------------------------------------------
function global:Invoke-GGAz {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-GGNote 'Azure CLI (az) saknas.'
        Write-GGFix 'winget install -e --id Microsoft.AzureCLI   och starta om terminalen'
        return
    }
    az @args
}

function global:Set-GGAzSubscription {
    param([Parameter(Position = 0)][string]$Name)
    if (-not $Name) { Write-GGNote 'Ange namn eller id: azset "Min subscription"   (tab kompletterar)'; return }
    Invoke-GGAz account set --subscription $Name
    if ($LASTEXITCODE -eq 0) { Invoke-GGAz account show -o table }
}

# --- git-guard ---------------------------------------------------------------------
function global:Import-GitGuardProfile {
    $global:GGReloading = $true
    try { . (Join-Path $GGHome 'terminal/profile.ps1') }
    finally { $global:GGReloading = $false }
    Write-Host 'Profilen omladdad.' -ForegroundColor Green
}

function global:Update-GitGuard {
    if (-not (Test-Path -LiteralPath (Join-Path $GGHome '.git'))) {
        Write-GGNote "$GGHome är ingen git-klon, så den kan inte uppdateras med git pull."
        Write-GGFix 'gå till din git-guard-klon, kör git pull och sedan .\install-githooks.ps1 -Global'
        return
    }
    $before = git -C $GGHome rev-parse HEAD
    git -C $GGHome pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-GGNote 'git pull misslyckades (se ovan).'
        Write-GGFix "git -C `"$GGHome`" status   (har du ändrat filer där? Lägg egna saker i my-commands.ps1)"
        return
    }
    $after = git -C $GGHome rev-parse HEAD
    if ($before -eq $after) { Write-Host 'git-guard är redan uppdaterat.' -ForegroundColor Green; return }
    $changedFiles = @(git -C $GGHome diff --name-only $before $after)
    Write-Host "Uppdaterat: $($changedFiles.Count) fil(er) ändrade" -ForegroundColor Green
    git -C $GGHome log --oneline "$before..$after" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($changedFiles | Where-Object { $_ -match '^install-terminal\.ps1$' }) {
        Write-GGNote 'install-terminal.ps1 har ändrats. Kör den gärna igen: & "$GGHome\install-terminal.ps1"'
    }
    Import-GitGuardProfile
}

function global:Edit-GGMyCommands {
    $file = Join-Path $GGHome 'terminal/my-commands.ps1'
    if (-not (Test-Path -LiteralPath $file)) {
        $template = @'
# Mina egna kommandon för git-guard-profilen. Filen skrivs aldrig över vid uppdatering.
# Ladda om efter ändring: reload
#
# Cmd   = det som körs (@args = argumenten du skriver efter kommandot)
# Desc  = kort beskrivning i 'gghelp kommandon'
# Help  = längre text i 'gghelp <kommando>' (valfri)
# Group = rubrik i listan (valfri)
#
# $MyCommands['kod']   = @{ Cmd = { code . }; Desc = 'Öppna VS Code här' }
# $MyCommands['api']   = @{ Cmd = { Set-Location C:\src\api }; Desc = 'Gå till api-repot' }
# $MyCommands['up']    = @{ Cmd = { docker compose up -d @args }; Desc = 'Starta containrar'; Group = 'Docker' }
'@
        # UTF-8 med BOM så att Windows PowerShell 5.1 läser svenska tecken rätt
        [IO.File]::WriteAllText($file, $template, (New-Object System.Text.UTF8Encoding $true))
        Write-Host "Skapade $file" -ForegroundColor Green
    }
    if (Get-Command code -ErrorAction SilentlyContinue) { code $file } else { notepad $file }
    Write-Host 'Spara och kör reload för att använda ändringarna.' -ForegroundColor DarkGray
}

# --- Tabbkomplettering ---------------------------------------------------------------
function global:Register-GGCompleters {
    Register-ArgumentCompleter -CommandName gsw -ParameterName Branch -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete)
        git branch --format='%(refname:short)' 2>$null | Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
    Register-ArgumentCompleter -CommandName azset -ParameterName Name -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete)
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }
        az account list --query '[].name' -o tsv 2>$null | Where-Object { $_ -like "*$($wordToComplete.Trim('"', "'"))*" } |
            ForEach-Object { $q = if ($_ -match '\s') { "'$_'" } else { $_ }; [Management.Automation.CompletionResult]::new($q, $_, 'ParameterValue', $_) }
    }
    foreach ($c in @('repo')) {
        Register-ArgumentCompleter -CommandName $c -ParameterName Name -ScriptBlock {
            param($commandName, $parameterName, $wordToComplete)
            Get-GGRepoList | Where-Object { $_.Name -like "*$wordToComplete*" } |
                ForEach-Object { [Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Path) }
        }
    }
    foreach ($c in @('jump', 'unmark')) {
        Register-ArgumentCompleter -CommandName $c -ParameterName Name -ScriptBlock {
            param($commandName, $parameterName, $wordToComplete)
            $b = Get-GGBookmarks
            $b.Keys | Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $b[$_].path) }
        }
    }
    Register-ArgumentCompleter -CommandName gghelp -ParameterName Topic -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete)
        @('kommandon', 'inställningar', 'steg', 'felsökning', 'repo', 'readme') + @($MyCommands.Keys) |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
}
