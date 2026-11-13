# CLAUDE.md – git-guard

Instruktioner för Claude (och andra) som ändrar i det här repot.

## Vad projektet är

git-guard är en global git `pre-push`-hook som kör snabba kvalitetskontroller innan kod lämnar
datorn. Fokus är .NET/Azure-repon (NuGet-versioner, DLL-referenser, låsfiler, transitiva
beroenden), men den hanterar även SQL, hemligheter, npm, Python och Go.
Användaren är en enskild utvecklare som kör Windows, Git for Windows och PowerShell 7.

```
hooks/pre-push           Bash. Orkestrerar allt och körs av Git (även i Git Bash på Windows).
hooks/<övriga>           Bash. Vidarekoppling till repots .git/hooks (och git lfs) när core.hooksPath
                         är global. Alla är identiska; markör: # git-guard passthrough hook.
checks/dotnet-check.ps1  PowerShell. Alla .NET-kontroller, anropas från hooken.
install-githooks.ps1     Installerar till ~/.git-guard och kopplar in hooken globalt/per repo.
install-terminal.ps1     Oh My Posh, Nerd Font, moduler och kopplar in terminal/profile.ps1.
terminal/profile.ps1     PowerShell-profil: prompt, kommandon (gg, ggnet, guard, aliases ...).
README.md                Användardokumentation. Håll den i synk med koden.
```

Installerat läge: allt kopieras till `~/.git-guard` (eller `$GIT_GUARD_HOME`).
`core.hooksPath` pekar på `~/.git-guard/hooks`.

## Hårda regler

1. **Användaren ska aldrig behöva ändra i filerna.** Nya beteenden styrs med
   `git config gitguard.<namn>` och har en säker standard. Varje ny inställning dokumenteras på
   tre ställen: hookens header, tabellen i README och `cfg`/`cfg_bool`-anropet.
2. **Markörraden** `# git-guard pre-push hook` ska stå på rad 2 i `hooks/pre-push`.
   Installationsskriptet och hooken använder den för att känna igen sig själva. Ändra den aldrig.
3. **Fel stoppar, varningar informerar.** Använd `red`/`Write-Bad` bara när pushen verkligen ska
   stoppas. Nya kontroller med risk för falsklarm börjar som varning, gärna med en
   `gitguard.*`-inställning som kan höja nivån till fel (som `versionDrift`).
4. **Snabbhet.** Hooken körs vid varje push. Titta bara på filer som ingår i pushen när det går.
   Hoppa över tunga steg när bara dokumentation ändrats. Inga nätverksanrop utöver
   `dotnet restore`. Tunga analyser (CodeQL, full sårbarhetsskanning) hör hemma i pipelinen.
5. **Verktyg är valfria.** Saknas sqlfluff, gitleaks, pwsh eller dotnet ska hooken varna och
   fortsätta, inte krascha. Använd `command -v` / `Get-Command` innan anrop.
6. **Idempotenta installationer.** Skripten ska kunna köras om och om igen. Skriv aldrig över
   användarens egna filer: `terminal/my-commands.ps1`, `terminal/theme.omp.json`,
   git config-inställningar eller en befintlig repo-hook. En befintlig hook döps om till
   `pre-push.local` och körs ändå.
7. **Text till användaren är på svenska**, kort och konkret. Ett fel följs av en rad som
   börjar med `Rätta:` med kommandot som löser det.

## Bash (`hooks/pre-push`)

- LF-radslut, UTF-8 **utan** BOM, körbar (`git update-index --chmod=+x hooks/pre-push`).
- Måste fungera i Git Bash (MSYS2) på Windows, i Linux och i macOS bash 3.2. Använd därför
  inte `mapfile`/`readarray`, associativa arrayer eller `${var,,}`.
- Sökvägar som skickas till PowerShell går genom `to_native` (`cygpath -w` i Git Bash).
- Tomma arrayer med `set -u`: använd `"${arr[@]+"${arr[@]}"}"`.
- Läs stdin (`input="$(cat)"`) en gång och skicka det vidare till repots egna hooks.

## PowerShell (`*.ps1`)

- **Ska fungera i både Windows PowerShell 5.1 och PowerShell 7.** Undvik därför `??`, `?:`,
  `&&`/`||` mellan kommandon, `ConvertFrom-Json -AsHashtable`, `ForEach-Object -Parallel`,
  `Join-Path` med fler än två delar och `$IsWindows` utan fallback (använd
  `$PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows`).
- **UTF-8 med BOM.** Annars läser 5.1 filen som ANSI och svenska tecken går sönder. Använd inga
  tankstreck (–) eller typografiska citattecken i koden, bara ASCII-bindestreck och raka citattecken.
- Externa kommandon (`git`, `dotnet`) körs med `$ErrorActionPreference = 'Continue'`. I 5.1
  blir stderr annars ett avbrytande fel när det omdirigeras.
- Använd aldrig `$args` som eget variabelnamn (automatisk variabel). Använd t.ex. `$dnArgs`.
- `Get-ChildItem -Include` fungerar bara med `-Recurse` eller en sökväg med jokertecken.
- Färger skrivs som ANSI (`$E = [char]27`) så att de syns även när hooken körs från Git Bash.
- XML i projektfiler läses namnrymdsoberoende: `SelectNodes("//*[local-name()='X']")`.

## .NET-kontrollerna

Ordningen i `dotnet-check.ps1` är medveten och ska behållas:
statisk analys av projektfiler → restore → `project.assets.json` (logs + targets) →
format (kräver restore) → build (`--no-restore`) → test (`--no-build`).

- Läs NuGet-problem ur `obj/project.assets.json` (`logs`) i stället för att tolka konsolutdata.
  Det fungerar även när restore inte gör något.
- MSBuild kan ge rader med `[sökväg.csproj]` på slutet. `Write-Detail` tar bort dem och gör
  sökvägar relativa. Använd den för alla detaljrader.
- Nya NuGet- eller MSBuild-koder läggs till i `Get-NuLabel` med svensk förklaring.

## Testa ändringar

Kör alltid innan commit:

```powershell
bash -n hooks/pre-push                       # syntax
shellcheck hooks/pre-push                    # om installerat
Invoke-ScriptAnalyzer -Path . -Recurse       # Install-Module PSScriptAnalyzer
# parse-test i båda PowerShell-versionerna:
pwsh       -NoProfile -Command "[void][Management.Automation.Language.Parser]::ParseFile('checks/dotnet-check.ps1',[ref]`$null,[ref]`$null)"
powershell -NoProfile -File checks/dotnet-check.ps1 -RepoRoot <testrepo> -SkipTests
```

Funktionstest, i ett testrepo med sln och 2–3 classlib-projekt:

| Scenario | Förväntat |
|---|---|
| Samma paket med olika `Version` i två projekt | Fel: versionsdrift (+ NU1605 om de refererar varandra) |
| `<Reference><HintPath>` till en DLL med samma namn som ett NuGet-paket | Fel: DLL + NuGet |
| Samma DLL i två olika versioner | Fel: DLL-konflikt |
| Samma DLL (samma version) från två olika mappar | Varning |
| packages.config-projekt med `..\packages\Id.1.2.3\lib\...` | Bara varning om packages.config, inget DLL+NuGet-fel |
| Olika versioner av ett paket i villkorade ItemGroups (per TFM) | Ingen drift |
| Projekt med `ManagePackageVersionsCentrally=false` i ett CPM-repo | Inget CPM-fel |
| `RestorePackagesWithLockFile` + ändrad version utan ny låsfil | Fel: låsfil i osynk (NU1004) |
| Projekt A får paket X 2.0 transitivt, projekt B har X 1.0 direkt | Varning: transitiv drift |
| Felaktiga mellanslag i ändrad `.cs` | Fel: formatering |
| Rent repo | Allt grönt, push går igenom |

Kör också:
- `gg` i testrepot (torrkörning utan push)
- `install-githooks.ps1 -WhatIf`
- en hel installation och avinstallation mot en tillfällig HOME:
  `$env:HOME`/`$env:USERPROFILE` = tom mapp

## Commits

- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- En logisk ändring per commit. Uppdatera README i samma commit som beteendet ändras.
- Användare uppdaterar med `git pull` och kör installationsskriptet igen. Det måste alltid
  fungera från en ren klon utan manuella steg.
