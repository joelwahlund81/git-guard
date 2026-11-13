# git-guard

En global `pre-push`-hook som kontrollerar koden innan den lämnar datorn. Den har extra fokus på
.NET: NuGet-versioner, DLL-referenser, låsfiler och tredjepartsberoenden.
Är något fel stoppas pushen. Inga filer behöver ändras, allt styrs med `git config`.

---

## Kom igång

**Krav:** Git for Windows och PowerShell 7 (`winget install Microsoft.PowerShell`).

```powershell
# 1. Klona direkt till installationsmappen (enklast att uppdatera)
git clone <din-repo-url> $HOME\.git-guard
cd $HOME\.git-guard

# 2. Tillåt lokala skript (bara första gången)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 3. Koppla in hooken globalt och installera verktyg (sqlfluff, gitleaks)
.\install-githooks.ps1 -Global -InstallTools

# 4. Terminalen: prompt med git-status, typsnitt och kommandon (valfritt)
.\install-terminal.ps1
```

Starta om Windows Terminal. Nu körs kontrollerna vid varje `git push`. Med `gg` kör du dem utan att pusha.

**Uppdatera:** `cd $HOME\.git-guard; git pull`. Kör `.\install-githooks.ps1 -Global` igen om
installationsskripten ändrats.

> Klonar du repot någon annanstans, t.ex. `C:\src\git-guard`, kopierar installationsskriptet
> filerna till `~/.git-guard`. Då kör du installationsskriptet igen efter varje `git pull`.

---

## Stegen vid `git push`

Hooken går igenom stegen i ordning. Ett **✗** stoppar pushen, ett **!** är bara en varning.

| # | Steg | Vad som händer | Stoppar |
|---|---|---|---|
| 0 | Skyddade brancher | Blockerar direkt push till brancher i `gitguard.protectedBranches` | ✗ |
| 1 | Ändrade filer | Tar fram filerna i commits som inte finns på remoten än. Resten av stegen tittar bara på dem | – |
| 2 | Konfliktmarkörer | Letar efter kvarglömda `<<<<<<<` / `>>>>>>>` | ✗ |
| 3 | SQL | `sqlfluff lint` på ändrade `.sql`-filer (T-SQL som standard). Stoppar bara om repot har en `.sqlfluff`, annars varning | ✗ / ! |
| 4 | Hemligheter | `gitleaks` på de commits som pushas: lösenord, nycklar, tokens. Hittar även hemligheter som tagits bort i en senare commit. Fynden visas maskerade, och repots `.gitleaks.toml`/`.gitleaksignore` gäller | ✗ |
| 5 | npm-låsfil | `package.json` ändrad men inte `package-lock.json` | ! |
| 6 | .NET | Kör `checks/dotnet-check.ps1`, se nedan | ✗ |
| 7 | Tester | `npm test`, `pytest` eller `go test` om sådana projekt finns | ✗ |
| 8 | Repots egen hook | Kör repots egen `pre-push` / `pre-push.local` om den finns | ✗ |

Ändras bara dokumentation (`.md`, `.txt`, bilder, mappen `docs/`) hoppas steg 6–7 över.
Ändras bara sådant som inte påverkar .NET-bygget (`.sql`, `.yml`, `.ps1`, `.sh`, `Dockerfile` m.m.)
hoppas .NET-stegen över.

**Snabbare andra gången:** när en körning är helt grön sparas resultatet i `.git/git-guard-ok`. Kör du
`gg` och sedan `git push` utan att ändra något, hoppas .NET och testerna över vid pushen. Det gäller
bara när exakt samma innehåll pushas, arbetskatalogen är ren och inställningarna är desamma.
Saknas ett verktyg (sqlfluff, gitleaks, dotnet, npm, pytest, go) hoppas steget över med en varning.
Varje steg som hoppas över säger varför, och sist kommer en **sammanfattning** med en rad per steg
och hur lång tid det tog. Vill du se exakt vad som körs: `GITGUARD_VERBOSE=1 git push` (en gång)
eller `git config gitguard.verbose true`.

### .NET-stegen (`checks/dotnet-check.ps1`)

| # | Steg | Fångar | Stoppar |
|---|---|---|---|
| 6.1 | Projektfiler | Samma NuGet-paket i **olika versioner** i olika projekt | ✗ * |
| | | Samma bibliotek både som **DLL** (`HintPath`) och som **NuGet-paket** | ✗ |
| | | Samma DLL i **olika versioner**, eller en DLL som saknas | ✗ |
| | | `Version=` i projekt trots Central Package Management, saknad `PackageVersion` | ✗ |
| | | `packages.config`, DLL:er från `packages\`, flytande versioner (`1.*`), `VersionOverride`, samma DLL från olika mappar | ! |
| 6.2 | Restore | `dotnet restore`, med `--locked-mode` när `packages.lock.json` finns, så att låsfiler i osynk fångas | ✗ |
| 6.3 | Tredjepartsbibliotek | Nedgraderingar (NU1605), versionskonflikter (NU1107), sårbara paket med hög/kritisk risk (NU1903/1904) | ✗ |
| | | Utanför tillåtet intervall (NU1608), .NET Framework-paket (NU1701), sårbarheter med låg/medel risk | ! |
| | | Ett beroende löses till olika versioner i olika projekt (transitiv drift) | ! |
| 6.4 | Formatering | `dotnet format whitespace --folder` på ändrade filer: mellanslag, indrag och radslut enligt `.editorconfig`. Tar några sekunder. Med `gitguard.format style` kontrolleras även kodstil och analyzers, men då laddas hela solutionen | ✗ |
| 6.5 | Build | `dotnet build`: referenskonflikter (MSB3277) och referenser som inte hittas (MSB3245) | ✗ |
| 6.6 | Test | `dotnet test` om testprojekt finns | ✗ |

\* Blir en varning med `git config gitguard.versionDrift warn`.

**Gamla problem stoppar inte.** Ett ✗ i projektfiler (6.1, 6.3 och referenskonflikter i 6.5) stoppar
bara om pushen ändrar något av de berörda projekten, deras `packages.config`/`packages.lock.json`
eller en gemensam fil (`Directory.*.props/targets`, `global.json`, `nuget.config`). Annars blir det en
varning markerad **(fanns redan)**, så att du inte blockeras av skuld som någon annan lämnat.
Vill du ha det strängare: `git config gitguard.existingIssues error`. `ggnet` räknar alltid allt som fel.

Varje fel följs av en rad `Rätta: ...` med kommandot som löser det.

---

## Kommandon i terminalen

| Kommando | Gör |
|---|---|
| `gg` | Kör alla kontroller utan att pusha. Repots egna hooks (t.ex. git lfs) körs inte |
| `ggnet` | Kör bara .NET-kontrollerna på hela repot |
| `guard` | Slå av/på git-guard i aktuellt repo |
| `aliases` | Visa alla egna kommandon |
| `gs` / `gl` | Kort status / commit-graf |
| `gp` / `gpf` | Push / säker force-push (`--force-with-lease`) |
| `gco` / `gclean` | Byt branch / ta bort lokala brancher som är borta på remote |
| `dt` / `azs` | `dotnet test` / aktiv Azure-subscription |

Undantag för en enskild push: `git push --no-verify` (allt) eller
`$env:SKIP_TESTS=1; git push; Remove-Item Env:SKIP_TESTS` (tester). Glöm inte den sista delen:
annars gäller `SKIP_TESTS` för alla pushar tills terminalen stängs.

**Egna kommandon:** skapa `~/.git-guard/terminal/my-commands.ps1`. Filen ignoreras av git och
skrivs aldrig över.

```powershell
$MyCommands['kod'] = @{ Cmd = { code . }; Desc = 'Öppna VS Code här' }
```

---

## Inställningar

Per repo: `git config <nyckel> <värde>`. För alla repon: `git config --global <nyckel> <värde>`.
Ta bort en inställning med `git config --unset <nyckel>`.

| Nyckel | Värde | Effekt |
|---|---|---|
| `gitguard.disable` | `true` | Stäng av allt i repot (samma som `guard`) |
| `gitguard.skipTests` | `true` | Kör inga tester |
| `gitguard.skipDotnet` | `true` | Hoppa över alla .NET-steg |
| `gitguard.skipFormat` | `true` | Hoppa över `dotnet format` |
| `gitguard.format` | `whitespace` (standard) / `style` / `off` | Hur noga formateringen kontrolleras (se 6.4) |
| `gitguard.cache` | `false` | Kör alltid allt. Standard: en grön körning sparas, och samma innehåll kontrolleras inte igen |
| `gitguard.versionDrift` | `warn` | Versionsdrift varnar i stället för att stoppa |
| `gitguard.existingIssues` | `warn` (standard) / `error` | Problem i .NET-filer som pushen inte rör varnar med "(fanns redan)" i stället för att stoppa |
| `gitguard.sqlLint` | `error` / `warn` / `off` | Hur SQL-lint ska räknas. Standard: `error` om repot har `.sqlfluff`, annars `warn` |
| `gitguard.solution` | `src/App.sln` | Vilken solution som byggs när repot har flera (standard: den första i bokstavsordning) |
| `gitguard.testFilter` | `"Category!=Integration"` | Filter till `dotnet test`, t.ex. för att hoppa över tester som kräver databas eller Azure |
| `gitguard.testTimeout` | `5m` | Avbryt tester som hänger (`--blame-hang-timeout`) i stället för att pushen fastnar |
| `gitguard.sqlDialect` | `postgres` m.fl. | Annan SQL-dialekt (en `.sqlfluff` i repot vinner) |
| `gitguard.protectedBranches` | `"main master"` | Blockera direkt push till de brancherna |
| `gitguard.verbose` | `true` | Visa vilka filer som ingår, varje kommando och full dotnet-utdata |

---

## Installationsalternativ

```powershell
.\install-githooks.ps1                              # meny
.\install-githooks.ps1 -Path C:\src -Interactive    # bara i utvalda repon, fråga för varje
.\install-githooks.ps1 -Path C:\src -WhatIf         # visa vad som skulle hända
.\install-githooks.ps1 -Global -Uninstall           # koppla bort globalt
.\install-githooks.ps1 -Path C:\src -Uninstall      # ta bort ur repon
.\install-terminal.ps1 -Theme paradox               # byt Oh My Posh-tema (annars behålls ditt tema)
```

Installeras hooken per repo döps en befintlig `pre-push` om till `pre-push.local` och körs ändå.
Repon med husky eller en egen `core.hooksPath` lämnas orörda.

---

## Felsökning

| Problem | Lösning |
|---|---|
| "running scripts is disabled" | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Hooken körs inte i ett repo | Kolla `git config core.hooksPath`. Har repot en egen (husky) gäller inte den globala |
| "PowerShell saknas" | `winget install Microsoft.PowerShell` |
| Restore: "Kunde inte nå paketkällan" (NU1301) eller 401 | Anslut VPN, eller logga in mot Azure Artifacts med `dotnet restore --interactive` ([Credential Provider](https://aka.ms/artifacts-credprovider)) |
| Integrationstester failar lokalt | `git config gitguard.testFilter "Category!=Integration"` |
| Push tar för lång tid | `git config gitguard.skipTests true` i repot och låt pipelinen köra testerna |
| Ikoner visas som rutor | Välj typsnittet **MesloLGM Nerd Font** i Windows Terminal / VS Code |
| `$'\r': command not found` | Hooken har fått CRLF. Kör `git add --renormalize .` eller installationsskriptet igen |

---

## Rekommenderat i .NET-repon

Med de här filerna i repots rot får kontrollerna mest att jobba med.

**Directory.Build.props**
```xml
<Project>
  <PropertyGroup>
    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
    <Nullable>enable</Nullable>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <AnalysisLevel>latest-recommended</AnalysisLevel>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
  </PropertyGroup>
</Project>
```

**Directory.Packages.props** (Central Package Management)
```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
```

Lägg också till `dotnet new globaljson` och `dotnet new editorconfig`. Kör sedan `dotnet restore` och
committa alla `packages.lock.json`.

---

## Skydd i Azure DevOps

Hooks kan alltid kringgås. Det som måste stoppas bör därför också finnas på servern:

- **Branch policies på main:** build validation, minst en granskare, reset votes on new push,
  länkade work items, lösta kommentarer
- **Branch security:** neka force push och direkt push, få personer med "Bypass policies"
- **Repository policies:** commit author email validation, file path validation (`*.pfx`, `.env`),
  max filstorlek
- **GitHub Secret Protection för Azure DevOps:** push protection för hemligheter
- **Pipeline:** `dotnet restore --locked-mode`, NuGet audit, approvals på prod-environments

---

Utvecklar du git-guard: läs [CLAUDE.md](CLAUDE.md) för regler och testscenarier.
