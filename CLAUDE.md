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
terminal/profile.ps1     PowerShell-profil: prompt och kommandotabellen $MyCommands.
terminal/commands.ps1    Funktionerna bakom kommandona (git, .NET, Azure, ggupdate ...).
terminal/navigation.ps1  repo/repos och bokmärken (mark, jump, marks, unmark).
terminal/help.ps1        gghelp, ggstatus, startmeddelandet och listan $GGSettings.
README.md                Användardokumentation. Håll den i synk med koden.
```

Installerat läge: allt kopieras till `~/.git-guard` (eller `$GIT_GUARD_HOME`).
`core.hooksPath` pekar på `~/.git-guard/hooks`.

## Hårda regler

1. **Användaren ska aldrig behöva ändra i filerna.** Nya beteenden styrs med
   `git config gitguard.<namn>` och har en säker standard. Varje ny inställning dokumenteras på
   fyra ställen: hookens header, tabellen i README, `$GGSettings` i `terminal/help.ps1` och
   `cfg`/`cfg_bool`/`cfg_enum`-anropet. Ett nytt kommando läggs i `$MyCommands` (med `Group`,
   `Desc` och gärna `Help`) och i README. Kontrollera att namnet inte redan är ett inbyggt alias
   (`Get-Command <namn>`).
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
   `terminal/bookmarks.json`, git config-inställningar, en befintlig repo-hook eller en egen hook
   i `~/.git-guard/hooks`. En befintlig hook döps om till
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
- I `terminal/` definieras allt med `function global:` och `$global:`, så att `reload` kan ladda
  om profilen inifrån en funktion. Tab-komplettering för en funktion kräver en namngiven
  parameter (`Register-ArgumentCompleter -ParameterName`).
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
.\tests\run-tests.ps1 -Quick        # syntax, BOM, radslut, parse, dokumentation i synk (sekunder)
.\tests\run-tests.ps1              # + alla funktionstester nedan (några minuter, kräver dotnet och nätverk)
.\tests\run-tests.ps1 -Only drift  # bara vissa scenarier (namn eller del av namn, kommaseparerat)
```

Kör den i **både** `pwsh` och `powershell` (5.1). CI (`.github/workflows/ci.yml`) kör samma
svit på Windows och Linux, PSScriptAnalyzer, shellcheck och ett röktest med macOS `/bin/bash` 3.2.
Testerna använder en egen `GIT_CONFIG_GLOBAL`, så din git config påverkas inte och påverkar inte.

Funktionstesterna (`$scenarios` i `tests/run-tests.ps1`) skapar repon med en lokal remote och kör
hooken som `git push` gör. Lägg till ett scenario för varje ny kontroll eller rättad bugg:

| Scenario | Förväntat |
|---|---|
| Samma paket med olika `Version` i två projekt (ändrat i pushen) | Fel: versionsdrift |
| Samma drift, men pushen rör inte projektfilerna | Varning "(fanns redan)", fel med `existingIssues=error` |
| `<Reference><HintPath>` till en DLL med samma namn som ett NuGet-paket | Fel: DLL + NuGet |
| Samma DLL i två olika versioner | Fel: DLL-konflikt |
| Samma DLL (samma version) från två olika mappar | Varning |
| packages.config-projekt med `..\packages\Id.1.2.3\lib\...` | Bara varning om packages.config, inget DLL+NuGet-fel |
| Olika versioner av ett paket i villkorade ItemGroups (per TFM) | Ingen drift |
| Projekt med `ManagePackageVersionsCentrally=false` i ett CPM-repo | Inget CPM-fel. `Version=` i ett CPM-projekt: fel |
| `RestorePackagesWithLockFile` + ändrad version utan ny låsfil | Fel: låsfil i osynk (NU1004) |
| Projekt A får paket X 4.0 transitivt, projekt B har X 3.1 direkt (tredjepartspaket, inte `Microsoft.Extensions.*` som kan tas bort av NuGet i .NET 10) | Varning: transitiv drift |
| Felaktiga mellanslag i ändrad `.cs` | Fel: formatering |
| Test som failar / samma med `gitguard.testFilter` | Fel / grönt |
| Bara `.sql` eller bara dokumentation ändrad | .NET hoppas över |
| `.yml` med tab först på en rad / tab i ett `run: \|`-skript / `yamlLint=off` | Fel / inget fel / inget fel |
| YAML-syntaxfel, dubbla nycklar, Helm-mall (kräver yamllint) | Fel / varning (fel med `.yamllint`) / hoppas över |
| Workflow utan `runs-on` (kräver actionlint) | Varning, fel med `yamlLint=error` |
| Skyddad branch, konfliktmarkörer | Fel |
| Ocommittad ändring i en pushad fil | Varning |
| `gg` (torrkörning) med en egen repo-hook | Hooken körs inte (men vid riktig push) |
| `commit-msg` i `.git/hooks` med git-guard som `core.hooksPath` | Körs via passthrough |
| Repo utan `.gitattributes`, git-lfs installerat, BSD-xargs (macOS) | `git lfs pre-push` körs inte |
| Hemlighet tillagd och borttagen i historiken (kräver gitleaks) | Fel |
| Rent repo, två gånger | Grönt, andra gången från cachen |

Testa också för hand när du ändrar installationen eller terminalen:
- `gg`, `gghelp`, `ggstatus` och tab-komplettering i en ny terminal (`reload` efter ändring)
- `install-githooks.ps1 -WhatIf`
- en hel installation och avinstallation mot en tillfällig HOME:
  `$env:HOME`/`$env:USERPROFILE` = tom mapp
- `install-terminal.ps1` två gånger: ett ändrat tema och `bookmarks.json` ska finnas kvar

## Commits

- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- En logisk ändring per commit. Uppdatera README i samma commit som beteendet ändras.
- Användare uppdaterar med `git pull` och kör installationsskriptet igen. Det måste alltid
  fungera från en ren klon utan manuella steg.
