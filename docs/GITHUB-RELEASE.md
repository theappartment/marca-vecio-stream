# GitHub Backup And Release Plan

## Obiettivo

Pubblicare il progetto su GitHub e allegare il setup Windows scaricabile da release.

## Cosa caricare nel repository

Da versionare:

- `src\`
- `docs\`
- `build-exe.ps1`
- `build-setup.ps1`
- `installer.iss`
- `install.ps1`
- `uninstall.ps1`
- `README.md`
- `logoapp.ico`
- `logoapp.png.jpg`

Da valutare se escludere:

- `dist\`
- `release\`

Scelta consigliata:

- non versionare `dist\`
- non versionare `release\`
- allegare `release\MarcaVecioStream-Setup.exe` alla GitHub Release

## Struttura release consigliata

Tag:

`v1.0.0`

Titolo release:

`Marca Vecio Stream v1.0.0`

Asset release:

- `MarcaVecioStream-Setup.exe`

## Checklist pubblicazione

1. Verificare che la build locale sia funzionante.
2. Rigenerare:
   - `dist\MarcaVecioStream.exe`
   - `dist\WebServer.exe`
   - `dist\TelegramWorker.exe`
   - `release\MarcaVecioStream-Setup.exe`
3. Fare backup del progetto su GitHub.
4. Creare tag versione.
5. Creare GitHub Release.
6. Allegare `release\MarcaVecioStream-Setup.exe`.
7. Scrivere changelog sintetico.

## Serve per completare la pubblicazione

Su questa macchina, al momento, mancano:

- `git`
- `gh` GitHub CLI

Per pubblicare davvero servono una di queste opzioni:

### Opzione A

Installare `git` e `gh`, poi autenticarsi su GitHub.

### Opzione B

Usare GitHub Desktop o browser manualmente.

### Opzione C

Installare tooling da terminale e fare tutto qui, inclusi:

- init repository
- commit
- push
- creazione release

## File da allegare

Setup finale:

`release\MarcaVecioStream-Setup.exe`
