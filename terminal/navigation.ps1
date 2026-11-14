# git-guard: snabb navigering till repon och bokmärkta mappar.
# Laddas av profile.ps1 - behöver aldrig ändras.
#
#   repo <namn>     hoppa till ett repo (räcker med en del av namnet, tab kompletterar)
#   repos           lista repon (-Status visar branch och ändringar, -Refresh söker igen)
#   mark <namn>     spara aktuell mapp som bokmärke (-Alias skapar även kommandot <namn>)
#   jump <namn>     hoppa till ett bokmärke
#   marks / unmark  lista / ta bort bokmärken
#
# Repon letas under mapparna i  git config --global gitguard.repoRoots "C:\src;C:\jobb"
# (standard: ~/source/repos och ~/src). Bokmärken sparas i terminal/bookmarks.json,
# som är din egen fil och aldrig skrivs över.

$global:GGRepoCache = $null
$global:GGBookmarkFile = Join-Path (Join-Path $GGHome 'terminal') 'bookmarks.json'

function global:Get-GGRepoRoots {
    $cfg = git config --global --get gitguard.repoRoots 2>$null
    if ($cfg) { $roots = @($cfg -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    else { $roots = @((Join-Path $HOME 'source/repos'), (Join-Path $HOME 'src')) }
    @($roots | ForEach-Object { [Environment]::ExpandEnvironmentVariables(($_ -replace '^~', $HOME)) } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

# Repon = mappar med .git (mapp eller fil för worktrees), högst två nivåer ned under varje rot
function global:Get-GGRepoList([switch]$Refresh) {
    if ($global:GGRepoCache -and -not $Refresh) { return $global:GGRepoCache }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($root in (Get-GGRepoRoots)) {
        $level1 = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
        foreach ($d in $level1) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
                $list.Add([pscustomobject]@{ Name = $d.Name; Path = $d.FullName }); continue
            }
            foreach ($d2 in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $d2.FullName '.git')) {
                    $list.Add([pscustomobject]@{ Name = $d2.Name; Path = $d2.FullName })
                }
            }
        }
    }
    $global:GGRepoCache = @($list | Sort-Object Name)
    return $global:GGRepoCache
}

function global:Enter-GGRepo([string]$Name) {
    $all = @(Get-GGRepoList)
    if ($all.Count -eq 0) {
        Write-Host 'Hittar inga repon.' -ForegroundColor Yellow
        Write-Host '  Rätta: git config --global gitguard.repoRoots "C:\src;C:\jobb"   (mappar där dina repon ligger)' -ForegroundColor DarkGray
        return
    }
    if (-not $Name) { Show-GGRepos; return }
    $hits = @($all | Where-Object { $_.Name -eq $Name })
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Name -like "$Name*" }) }
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Name -like "*$Name*" }) }
    if ($hits.Count -eq 0) {
        Write-Host "Inget repo matchar '$Name'. Nytt repo nyss? Kör: repos -Refresh" -ForegroundColor Yellow
        return
    }
    if ($hits.Count -gt 1) {
        Write-Host "Flera repon matchar '$Name':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $hits.Count; $i++) { Write-Host ("  {0,2}) {1,-30} {2}" -f ($i + 1), $hits[$i].Name, $hits[$i].Path) -ForegroundColor DarkGray }
        $a = Read-Host 'Välj nummer (Enter = avbryt)'
        $n = 0
        if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $hits.Count) { return }
        $hits = @($hits[$n - 1])
    }
    Set-Location -LiteralPath $hits[0].Path
}

function global:Show-GGRepos {
    param([switch]$Status, [switch]$Refresh)
    $all = @(Get-GGRepoList -Refresh:$Refresh)
    $roots = (Get-GGRepoRoots) -join ', '
    Write-Host "`n  Repon ($($all.Count)) under $roots" -ForegroundColor Cyan
    foreach ($r in $all) {
        $extra = ''
        if ($Status) {
            $branch = git -C $r.Path rev-parse --abbrev-ref HEAD 2>$null
            $dirty = @(git -C $r.Path status --porcelain 2>$null).Count
            $extra = "[$branch]" + $(if ($dirty -gt 0) { " $dirty ändrade" } else { '' })
        }
        Write-Host ("  {0,-30}" -f $r.Name) -ForegroundColor Yellow -NoNewline
        if ($Status) { Write-Host ("{0,-28} {1}" -f $extra, $r.Path) -ForegroundColor DarkGray }
        else { Write-Host $r.Path -ForegroundColor DarkGray }
    }
    Write-Host '  Hoppa dit: repo <namn>   Sök igen: repos -Refresh   Med status: repos -Status' -ForegroundColor DarkGray
    Write-Host ''
}

# --- Bokmärken -----------------------------------------------------------------
function global:Get-GGBookmarks {
    $b = [ordered]@{}
    if (-not (Test-Path -LiteralPath $GGBookmarkFile)) { return $b }
    try {
        $json = Get-Content -LiteralPath $GGBookmarkFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $b[$p.Name] = @{ path = $p.Value.path; alias = [bool]$p.Value.alias } }
    } catch {
        Write-Host "Kunde inte läsa $GGBookmarkFile ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    return $b
}

function global:Save-GGBookmarks($Bookmarks) {
    $obj = [ordered]@{}
    foreach ($k in $Bookmarks.Keys) { $obj[$k] = [ordered]@{ path = $Bookmarks[$k].path; alias = $Bookmarks[$k].alias } }
    $text = ([pscustomobject]$obj | ConvertTo-Json -Depth 4)
    [IO.File]::WriteAllText($GGBookmarkFile, $text, (New-Object System.Text.UTF8Encoding $false))
}

function global:Add-GGBookmark {
    param([Parameter(Position = 0)][string]$Name, [string]$Path = (Get-Location).Path, [switch]$Alias)
    if (-not $Name) { Write-Host 'Ange ett namn: mark <namn>   (lägg till -Alias för ett eget kommando)' -ForegroundColor Yellow; return }
    if ($Name -notmatch '^[\w.-]+$') { Write-Host 'Namnet får bara innehålla bokstäver, siffror, - _ och .' -ForegroundColor Yellow; return }
    $b = Get-GGBookmarks
    $b[$Name] = @{ path = (Resolve-Path -LiteralPath $Path).Path; alias = [bool]$Alias }
    Save-GGBookmarks $b
    Write-Host "Bokmärke '$Name' -> $($b[$Name].path)   (jump $Name)" -ForegroundColor Green
    if ($Alias) { Register-GGBookmarkAliases -Only $Name }
}

function global:Enter-GGBookmark([string]$Name) {
    $b = Get-GGBookmarks
    if (-not $Name) { Show-GGBookmarks; return }
    if (-not $b.Contains($Name)) { Write-Host "Inget bokmärke '$Name'. Se: marks" -ForegroundColor Yellow; return }
    if (-not (Test-Path -LiteralPath $b[$Name].path)) { Write-Host "Mappen finns inte längre: $($b[$Name].path)   (unmark $Name)" -ForegroundColor Yellow; return }
    Set-Location -LiteralPath $b[$Name].path
}

function global:Show-GGBookmarks {
    $b = Get-GGBookmarks
    Write-Host "`n  Bokmärken ($($b.Count))" -ForegroundColor Cyan
    if ($b.Count -eq 0) { Write-Host '  Inga än. Gå till en mapp och kör: mark <namn>' -ForegroundColor DarkGray }
    foreach ($k in $b.Keys) {
        Write-Host ("  {0,-20}" -f $k) -ForegroundColor Yellow -NoNewline
        $tag = if ($b[$k].alias) { '[kommando] ' } else { '' }
        Write-Host "$tag$($b[$k].path)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

function global:Remove-GGBookmark([string]$Name) {
    $b = Get-GGBookmarks
    if (-not $Name -or -not $b.Contains($Name)) { Write-Host "Inget bokmärke '$Name'. Se: marks" -ForegroundColor Yellow; return }
    if ($b[$Name].alias -and $global:GGBookmarkAliases -contains $Name) { Remove-Item -LiteralPath "function:$Name" -ErrorAction SilentlyContinue }
    $b.Remove($Name)
    Save-GGBookmarks $b
    Write-Host "Bokmärket '$Name' borttaget" -ForegroundColor Green
}

# Bokmärken med -Alias blir egna kommandon, men bara om namnet är ledigt
if ($null -eq $global:GGBookmarkAliases) { $global:GGBookmarkAliases = @() }
function global:Register-GGBookmarkAliases([string]$Only) {
    $b = Get-GGBookmarks
    foreach ($k in $b.Keys) {
        if ($Only -and $k -ne $Only) { continue }
        if (-not $b[$k].alias) { continue }
        $existing = Get-Command $k -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existing -and $global:GGBookmarkAliases -notcontains $k) {
            Write-Host "Bokmärket '$k' blir inget kommando: namnet används redan av $($existing.CommandType) $($existing.Name). Använd: jump $k" -ForegroundColor Yellow
            continue
        }
        $path = $b[$k].path
        Set-Item "function:global:$k" ([scriptblock]::Create("Set-Location -LiteralPath '$($path -replace "'", "''")'"))
        if ($global:GGBookmarkAliases -notcontains $k) { $global:GGBookmarkAliases += $k }
    }
}
