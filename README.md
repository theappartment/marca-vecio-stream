# Marca Vecio Stream

Applicazione Windows leggera per gestire il playback di video salvati in una cartella specifica usando VLC in full screen e loop, con pannello web remoto.

## Documentazione

- [Panoramica progetto](docs/PROJECT-OVERVIEW.md)
- [Architettura](docs/ARCHITECTURE.md)
- [Guida operativa](docs/OPERATIONS.md)
- [Backup e release GitHub](docs/GITHUB-RELEASE.md)

## Funzioni principali

- Selezione della cartella video da monitorare.
- Rilevamento automatico del percorso di `vlc.exe` nei percorsi piu comuni.
- Elenco dei video compatibili presenti nella cartella.
- Avvio di un singolo video in loop a schermo intero.
- Avvio di tutti i video della cartella tramite playlist `.m3u` in full screen e loop.
- Pulsante di stop che chiude solo l'istanza VLC avviata dall'app.
- Avvio automatico con Windows.
- Modalita kiosk con auto play e finestra minimizzata.
- Pannello web locale per controllo remoto, upload ed eliminazione file.
- Bot Telegram che pubblica la URL `ngrok` aggiornata e risponde ai comandi principali.
- Sezione impostazioni nell'app per modificare in qualunque momento il token Telegram.
- Salvataggio delle impostazioni in `%APPDATA%\MarcaVecioStream\config.json`.

## Requisiti

- Windows con PowerShell 5.1 o superiore.
- VLC installato sul PC.

## Avvio rapido

1. Esegui `install.ps1`.
2. Apri l'app dallo shortcut creato sul Desktop o dal menu Start.
3. Seleziona la cartella dei video.
4. Verifica o seleziona il percorso di `vlc.exe`.
5. Premi `Salva`.
6. Usa `Riproduci selezionato` oppure `Riproduci tutta la cartella`.
7. Per il controllo remoto, apri il pannello web su `http://127.0.0.1:8090/` e usa il token configurato.
8. Su Telegram apri il bot e invia `/subscribe` per ricevere automaticamente la URL pubblica aggiornata.

## Installazione

Esegui da PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

L'installer copia i file in `%LOCALAPPDATA%\Programs\MarcaVecioStream` e crea due shortcut:

- Desktop
- Menu Start

## Build EXE

Per generare gli eseguibili Windows definitivi:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-exe.ps1
```

Questo crea in `dist\`:

- `MarcaVecioStream.exe`
- `WebServer.exe`
- `TelegramWorker.exe`

Dopo la build, riesegui `install.ps1`: l'installer usera automaticamente l'eseguibile principale al posto del launcher PowerShell.

## Disinstallazione

Esegui da PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Note

- I formati video supportati sono: `.mp4`, `.mkv`, `.avi`, `.mov`, `.wmv`, `.m4v`, `.webm`.
- Se VLC non viene rilevato automaticamente, seleziona manualmente `vlc.exe`.
- Il pannello web ascolta in locale su `127.0.0.1`, quindi per l'accesso remoto via Internet puoi esporlo con un tunnel come `ngrok`.
- L'app e pensata per un'installazione locale per utente. Se vuoi, nel passo successivo possiamo trasformarla anche in un pacchetto `.exe` o in un installer `.msi` usando tooling aggiuntivo.

## Esempio ngrok

Una volta installato e autenticato `ngrok` sul PC Windows che esegue l'app:

```powershell
ngrok http 8090
```

Poi apri l'URL pubblico generato da `ngrok` e inserisci il token remoto configurato nell'app.

## Bot Telegram

- Avvia `ngrok` sullo stesso PC che esegue l'app.
- Apri il bot Telegram configurato e invia `/start`.
- Se serve, cambia il token direttamente dalla sezione `Bot Telegram` dell'app e salva.
- Invia `/subscribe` per registrare la chat e ricevere la URL aggiornata ogni volta che cambia.
- Comandi disponibili: `/subscribe`, `/unsubscribe`, `/url`, `/status`.
