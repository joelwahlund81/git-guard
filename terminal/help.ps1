# git-guard: hjälp i terminalen (gghelp, ggstatus och startmeddelandet).
# Laddas av profile.ps1 - behöver aldrig ändras.
#
# Ny inställning eller nytt kommando? Uppdatera även $GGSettings nedan (se CLAUDE.md).

# Alla gitguard.*-inställningar: namn, standard, värden och vad de gör.
# Samma lista finns i hookens header och i README.
$global:GGSettings = @(
    @{ Key = 'disable';           Default = 'false';        Values = 'true';                     Desc = 'Stäng av alla kontroller i repot (samma som guard)' }
    @{ Key = 'skipTests';         Default = 'false';        Values = 'true';                     Desc = 'Kör inga tester' }
    @{ Key = 'skipDotnet';        Default = 'false';        Values = 'true';                     Desc = 'Hoppa över alla .NET-steg' }
    @{ Key = 'skipFormat';        Default = 'false';        Values = 'true';                     Desc = 'Hoppa över dotnet format' }
    @{ Key = 'format';            Default = 'whitespace';   Values = 'whitespace|style|off';     Desc = 'Formatering: snabb whitespace, eller style (kodstil + analyzers, långsammare)' }
    @{ Key = 'versionDrift';      Default = 'error';        Values = 'error|warn';               Desc = 'Samma NuGet-paket i olika versioner: stoppa eller varna' }
    @{ Key = 'existingIssues';    Default = 'warn';         Values = 'warn|error';               Desc = 'Problem i .NET-filer som pushen inte rör: varna (fanns redan) eller stoppa' }
    @{ Key = 'sqlLint';           Default = 'error/warn';   Values = 'error|warn|off';           Desc = 'SQL-lint: standard error om repot har .sqlfluff, annars warn' }
    @{ Key = 'sqlDialect';        Default = 'tsql';         Values = 'postgres, mysql ...';      Desc = 'SQL-dialekt (en .sqlfluff i repot vinner)' }
    @{ Key = 'solution';          Default = '(första)';     Values = 'src/App.sln';              Desc = 'Vilken solution som byggs när repot har flera' }
    @{ Key = 'testFilter';        Default = '(inget)';      Values = '"Category!=Integration"';  Desc = 'Filter till dotnet test' }
    @{ Key = 'testTimeout';       Default = '(ingen)';      Values = '5m';                       Desc = 'Avbryt tester som hänger' }
    @{ Key = 'protectedBranches'; Default = '(inga)';       Values = '"main master"';            Desc = 'Blockera direkt push till de här brancherna' }
    @{ Key = 'cache';             Default = 'true';         Values = 'false';                    Desc = 'Kör inte om .NET/tester för innehåll som redan är grönt' }
    @{ Key = 'verbose';           Default = 'false';        Values = 'true';                     Desc = 'Visa filer, kommandon och full utdata' }
    @{ Key = 'startup';           Default = 'full/short';   Values = 'full|short|off';           Desc = 'Startmeddelande: full i Windows Terminal, annars en rad' }
    @{ Key = 'repoRoots';         Default = '~/source/repos;~/src'; Values = '"C:\src;C:\jobb"'; Desc = 'Mappar där repo letar efter repon (global)' }
)

function global:Write-GGHead([string]$m) { Write-Host "`n  $m" -ForegroundColor Cyan }
function global:Write-GGRow([string]$Left, [string]$Right, [int]$Width = 12, [string]$Color = 'Yellow') {
    Write-Host ("  {0,-$Width}" -f $Left) -ForegroundColor $Color -NoNewline
    Write-Host $Right -ForegroundColor DarkGray
}

# --- Status --------------------------------------------------------------------
function global:Test-GGHookFile([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    return (@(Get-Content -LiteralPath $File -TotalCount 3 -ErrorAction SilentlyContinue) -contains '# git-guard pre-push hook')
}

# Är git-guard aktivt här, och hur? Används av ggstatus, gghelp och startmeddelandet.
function global:Get-GitGuardState {
    $state = [ordered]@{ InRepo = $false; Active = $false; Disabled = $false; Text = ''; Fix = '' }
    $top = git rev-parse --show-toplevel 2>$null
    $state.InRepo = [bool]$top
    $hp = git config --get core.hooksPath 2>$null
    $scope = ''
    if ($hp) {
        $scopeLine = git config --show-scope --get core.hooksPath 2>$null
        if ($scopeLine -match '^(\w+)\s') { $scope = $Matches[1] }
        $hpFull = $hp -replace '^~', $HOME
        if ($top -and -not [IO.Path]::IsPathRooted($hpFull)) { $hpFull = Join-Path $top $hpFull }
    }
    if ($state.InRepo) {
        $state.Disabled = (git config --bool --get gitguard.disable 2>$null) -eq 'true'
        if ($hp) {
            if (Test-GGHookFile (Join-Path $hpFull 'pre-push')) {
                $state.Active = $true
                $state.Text = if ($scope -eq 'local') { 'aktiv i detta repo (repots core.hooksPath)' } else { 'aktiv i detta repo (global hook)' }
            } else {
                $state.Text = "körs inte här: repot använder en egen core.hooksPath ($hp), t.ex. husky"
                $state.Fix = 'lägg till git-guard i den hooken, eller ta bort den: git config --unset core.hooksPath'
            }
        } else {
            $common = git rev-parse --git-common-dir 2>$null
            if ($common -and -not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $top $common }
            if ($common -and (Test-GGHookFile (Join-Path $common 'hooks/pre-push'))) {
                $state.Active = $true; $state.Text = 'aktiv i detta repo (installerad i .git/hooks)'
            } else {
                $state.Text = 'inte installerad för detta repo'
                $state.Fix = '.\install-githooks.ps1 -Global   (i git-guard-mappen)'
            }
        }
        if ($state.Active -and $state.Disabled) {
            $state.Active = $false
            $state.Text = 'AVSTÄNGD i detta repo (gitguard.disable)'
            $state.Fix = 'guard   (slår på igen)'
        }
    } else {
        if ($hp -and (Test-GGHookFile (Join-Path $hpFull 'pre-push'))) { $state.Active = $true; $state.Text = 'aktiv globalt' }
        elseif ($hp) { $state.Text = "inte aktiv globalt (core.hooksPath = $hp)" }
        else { $state.Text = 'inte aktiv globalt'; $state.Fix = '.\install-githooks.ps1 -Global   (eller per repo med -Path)' }
    }
    return [pscustomobject]$state
}

function global:Show-GitGuardStatus {
    $s = Get-GitGuardState
    Write-GGHead 'git-guard status'
    $color = if ($s.Active) { 'Green' } else { 'Yellow' }
    Write-Host "  $($s.Text)" -ForegroundColor $color
    if ($s.Fix) { Write-Host "  Rätta: $($s.Fix)" -ForegroundColor DarkGray }
    Write-Host "  Installerat i: $GGHome" -ForegroundColor DarkGray

    Write-GGHead 'Verktyg'
    $tools = [ordered]@{
        git        = 'krävs'
        dotnet     = '.NET-kontroller'
        pwsh       = 'PowerShell 7, rekommenderas (klarar stora project.assets.json)'
        gitleaks   = 'hemlighetssökning'
        sqlfluff   = 'SQL-lint'
        'git-lfs'  = 'stora filer (om repot använder LFS)'
        az         = 'Azure-kommandon (azs, azl, azset)'
    }
    $install = @{
        dotnet = 'winget install Microsoft.DotNet.SDK.8'; pwsh = 'winget install Microsoft.PowerShell'
        gitleaks = 'winget install Gitleaks.Gitleaks'; sqlfluff = 'pip install sqlfluff'
        'git-lfs' = 'winget install GitHub.GitLFS'; az = 'winget install Microsoft.AzureCLI'
    }
    foreach ($t in $tools.Keys) {
        $ok = [bool](Get-Command $t -ErrorAction SilentlyContinue)
        $mark = if ($ok) { '[x]' } else { '[ ]' }
        $extra = if (-not $ok -and $install[$t]) { "   ($($install[$t]))" } else { '' }
        Write-Host "  $mark " -ForegroundColor $(if ($ok) { 'Green' } else { 'DarkGray' }) -NoNewline
        Write-GGRow $t "$($tools[$t])$extra" 10 $(if ($ok) { 'Gray' } else { 'DarkGray' })
    }

    if ($s.InRepo) {
        Write-GGHead 'Detta repo'
        $set = @(git config --show-scope --get-regexp '^gitguard\.' 2>$null)
        if ($set.Count -eq 0) { Write-Host '  Inga gitguard-inställningar (standardvärden gäller). Se: gghelp inställningar' -ForegroundColor DarkGray }
        foreach ($line in $set) { Write-Host "  $line" -ForegroundColor DarkGray }
        $gitDir = git rev-parse --git-dir 2>$null
        $cache = if ($gitDir) { Join-Path $gitDir 'git-guard-ok' } else { $null }
        if ($cache -and (Test-Path -LiteralPath $cache)) {
            $tree = git rev-parse 'HEAD^{tree}' 2>$null
            $saved = (Get-Content -LiteralPath $cache -Raw -ErrorAction SilentlyContinue)
            if ($tree -and $saved -and $saved.StartsWith($tree)) { Write-Host '  Senaste gröna körning gäller HEAD (nästa push går fort)' -ForegroundColor Green }
        }
    }
    Write-Host ''
}

# --- Hjälp ---------------------------------------------------------------------
function global:Get-GGCommandGroups {
    $groups = [ordered]@{}
    foreach ($k in $MyCommands.Keys) {
        $g = $MyCommands[$k].Group
        if (-not $g) { $g = 'Egna' }
        if (-not $groups.Contains($g)) { $groups[$g] = New-Object System.Collections.Generic.List[string] }
        $groups[$g].Add($k)
    }
    return $groups
}

function global:Show-GGCommandsShort {
    $groups = Get-GGCommandGroups
    foreach ($g in $groups.Keys) { Write-GGRow $g ($groups[$g] -join '  ') 12 'Cyan' }
}

function global:Show-GitGuardHelp {
    param([Parameter(Position = 0)][string]$Topic)
    $t = "$Topic".Trim().ToLower()
    switch -Regex ($t) {
        '^$' {
            $s = Get-GitGuardState
            Write-GGHead 'git-guard - kontroller innan koden lämnar datorn'
            Write-Host "  Status: $($s.Text)" -ForegroundColor $(if ($s.Active) { 'Green' } else { 'Yellow' })
            Write-Host '  Vid varje git push körs kontrollerna. Ett X stoppar pushen, ett ! är en varning.' -ForegroundColor Gray
            Write-Host '  Kör dem utan att pusha: gg     Undantag en gång: git push --no-verify' -ForegroundColor Gray
            Write-GGHead 'Mer hjälp'
            Write-GGRow 'gghelp kommandon'      'alla kommandon med beskrivning' 26
            Write-GGRow 'gghelp <kommando>'     'detaljer, t.ex. gghelp gnb' 26
            Write-GGRow 'gghelp inställningar'  'alla gitguard-inställningar och vad som gäller här' 26
            Write-GGRow 'gghelp steg'           'vad som händer vid push' 26
            Write-GGRow 'gghelp felsökning'     'vanliga problem och lösningar' 26
            Write-GGRow 'gghelp repo'           'hoppa mellan repon och mappar' 26
            Write-GGRow 'gghelp readme'         'öppna hela dokumentationen' 26
            Write-GGRow 'ggstatus'              'är git-guard aktivt här, vilka verktyg saknas' 26
            Write-GGHead 'Kommandon'
            Show-GGCommandsShort
            Write-Host ''
            return
        }
        '^(kommandon|commands|aliases)$' {
            $groups = Get-GGCommandGroups
            foreach ($g in $groups.Keys) {
                Write-GGHead $g
                foreach ($k in $groups[$g]) { Write-GGRow $k $MyCommands[$k].Desc 11 }
            }
            Write-Host "`n  Detaljer: gghelp <kommando>   Egna kommandon: ggedit" -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        '^(inst(ä|a)llningar|settings|config)$' {
            Write-GGHead 'Inställningar (git config gitguard.<namn> <värde>)'
            Write-Host '  Per repo: git config gitguard.<namn> <värde>   Alla repon: git config --global ...' -ForegroundColor DarkGray
            Write-Host '  Ta bort: git config --unset gitguard.<namn>   (lägg till --global för den globala)' -ForegroundColor DarkGray
            Write-Host ''
            Write-Host ("  {0,-18} {1,-28} {2}" -f 'Namn', 'Gäller nu', 'Vad den gör') -ForegroundColor Cyan
            foreach ($st in $GGSettings) {
                $line = git config --show-scope --get "gitguard.$($st.Key)" 2>$null | Select-Object -First 1
                if ($line -match '^(\w+)\s+(.*)$') {
                    $where = if ($Matches[1] -eq 'local') { 'repo' } else { $Matches[1] }
                    $now = "$($Matches[2]) ($where)"; $col = 'Green'
                } else { $now = "$($st.Default)"; $col = 'DarkGray' }
                Write-Host ("  {0,-18} " -f $st.Key) -ForegroundColor Yellow -NoNewline
                Write-Host ("{0,-28} " -f $now) -ForegroundColor $col -NoNewline
                Write-Host "$($st.Desc). Värden: $($st.Values)" -ForegroundColor DarkGray
            }
            Write-Host "`n  Grönt = satt av dig (repo eller global). Grått = standardvärde." -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        '^(steg|steps)$' {
            Write-GGHead 'Vid git push (i den här ordningen)'
            $steps = @(
                @('Skyddade brancher', 'stoppar direkt push till gitguard.protectedBranches'),
                @('Ändrade filer',     'bara filer i commits som inte finns på servern kontrolleras'),
                @('Konfliktmarkörer',  'kvarglömda <<<<<<< / >>>>>>>'),
                @('SQL',               'sqlfluff på ändrade .sql (stoppar bara med .sqlfluff i repot)'),
                @('Hemligheter',       'gitleaks på de commits som pushas, maskerat'),
                @('npm-låsfil',        'package.json ändrad utan package-lock.json (varning)'),
                @('.NET',              'paket/DLL-referenser, restore, sårbarheter, format, build, test'),
                @('Tester',            'npm test, pytest, go test'),
                @('Repots hook',       'repots egen pre-push, eller git lfs pre-push')
            )
            $i = 0
            foreach ($st in $steps) { Write-GGRow ("{0}. {1}" -f $i, $st[0]) $st[1] 22; $i++ }
            Write-Host "`n  Sist kommer en sammanfattning med en rad per steg. Se exakt vad som körs: GITGUARD_VERBOSE=1 git push" -ForegroundColor DarkGray
            Write-Host '  Gamla problem i .NET-filer som pushen inte rör blir varningar "(fanns redan)".' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        '^(fels(ö|o)kning|help|problem)$' {
            Write-GGHead 'Felsökning'
            $rows = @(
                @('Pushen stoppas', 'Läs raden "Rätta:" under felet. En gång utan kontroller: git push --no-verify'),
                @('Tester failar lokalt', 'gpnt (push utan tester en gång) eller git config gitguard.testFilter "Category!=Integration"'),
                @('Restore: NU1301 / 401', 'anslut VPN, eller dotnet restore --interactive (Azure Artifacts)'),
                @('Push tar lång tid', 'kör gg först (sparas), git config gitguard.skipTests true, eller låt pipelinen testa'),
                @('Hooken körs inte', 'ggstatus. Har repot egen core.hooksPath (husky) gäller inte git-guard'),
                @('"running scripts is disabled"', 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'),
                @('gitleaks/sqlfluff saknas', '.\install-githooks.ps1 -InstallTools'),
                @("`$'\r': command not found", 'hooken har fått CRLF: kör installationsskriptet igen'),
                @('Ikoner visas som rutor', 'välj typsnittet MesloLGM Nerd Font i terminalen'),
                @('Ett kommando fungerar inte', 'reload, och gghelp <kommando>. Uppdatera: ggupdate')
            )
            foreach ($r in $rows) { Write-GGRow $r[0] $r[1] 30 }
            Write-Host "`n  Mer: gghelp readme" -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        '^(repo|repos|navigering|mark|jump)$' {
            Write-GGHead 'Hoppa mellan repon och mappar'
            Write-GGRow 'repo <namn>'       'gå till ett repo. Räcker med en del av namnet, tab kompletterar' 18
            Write-GGRow 'repos'             'lista repon (-Status: branch och ändringar, -Refresh: sök igen)' 18
            Write-GGRow 'mark <namn>'       'spara mappen du står i som bokmärke' 18
            Write-GGRow 'mark <namn> -Alias' 'samma, och skapa kommandot <namn> som går dit' 18
            Write-GGRow 'jump <namn>'       'gå till ett bokmärke' 18
            Write-GGRow 'marks / unmark'    'lista / ta bort bokmärken' 18
            $roots = (Get-GGRepoRoots) -join ', '
            Write-Host "`n  Repon letas under: $(if ($roots) { $roots } else { '(inga mappar hittades)' })" -ForegroundColor DarkGray
            Write-Host '  Ändra: git config --global gitguard.repoRoots "C:\src;C:\jobb"' -ForegroundColor DarkGray
            Write-Host "  Bokmärken sparas i $GGBookmarkFile" -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        '^readme$' {
            $readme = Join-Path $GGHome 'README.md'
            if (-not (Test-Path -LiteralPath $readme)) { Write-Host "Hittar inte $readme" -ForegroundColor Yellow; return }
            if (Get-Command code -ErrorAction SilentlyContinue) { code $readme } else { Invoke-Item -LiteralPath $readme }
            return
        }
        default {
            $key = @($MyCommands.Keys | Where-Object { $_ -eq $t })
            if ($key.Count -eq 0) {
                Write-Host "Okänt ämne eller kommando: '$Topic'. Skriv gghelp för en lista." -ForegroundColor Yellow
                return
            }
            $c = $MyCommands[$key[0]]
            Write-GGHead "$($key[0])  -  $($c.Desc)"
            if ($c.Help) { ($c.Help -split "`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray } }
            Write-Host "  Kör: $($c.Cmd.ToString().Trim())" -ForegroundColor DarkGray
            Write-Host ''
        }
    }
}

# --- Startmeddelande ----------------------------------------------------------
function global:Show-GitGuardStartup {
    # Inte när PowerShell kör ett skript eller kommando (pwsh -c / -File) utan att stanna kvar
    $cl = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)
    $nonInteractive = @($cl | Where-Object { $_ -match '^[-/](noni|noninteractive)$' }).Count -gt 0
    $runsCommand = @($cl | Where-Object { $_ -match '^[-/](c|command|f|file|e|ec|encodedcommand)$' }).Count -gt 0
    $noExit = @($cl | Where-Object { $_ -match '^[-/](noe|noexit)$' }).Count -gt 0
    if ($nonInteractive -or ($runsCommand -and -not $noExit)) { return }
    if ($global:GGReloading) { return }

    $mode = "$(git config --get gitguard.startup 2>$null)".Trim().ToLower()
    if (-not $mode) { $mode = if ($env:WT_SESSION) { 'full' } else { 'short' } }
    if ($mode -eq 'off') { return }
    $s = Get-GitGuardState
    $color = if ($s.Active) { 'DarkGreen' } else { 'DarkYellow' }
    if ($mode -eq 'full') {
        Write-Host ''
        Write-GGRow 'git-guard' $s.Text 12 'Cyan'
        Show-GGCommandsShort
        Write-Host '  Hjälp: gghelp  |  gghelp <kommando>  |  ggstatus      Dölj detta: git config --global gitguard.startup short' -ForegroundColor DarkGray
        Write-Host ''
    } else {
        Write-Host "git-guard: $($s.Text)  |  skriv gghelp för hjälp" -ForegroundColor $color
    }
}
