# Project Overview

## Nome progetto

Marca Vecio Stream

## Scopo

Applicazione Windows per:

- gestire playback video locale tramite VLC
- riprodurre contenuti in full screen e loop
- controllare l'app da interfaccia desktop
- controllare l'app da pannello web locale/remoto
- pubblicare la URL pubblica via bot Telegram quando il tunnel ngrok cambia

## Componenti principali

- `src/MarcaVecioPlayer.ps1`
  Applicazione desktop principale con interfaccia WPF.
- `src/WebServer.ps1`
  Web server locale con API HTTP e pannello web.
- `src/TelegramWorker.ps1`
  Worker che interroga Telegram e invia notifiche URL/stato.
- `src/web/index.html`
  Interfaccia web per controllo remoto e upload file.
- `build-exe.ps1`
  Build degli eseguibili Windows con `ps2exe`.
- `installer.iss`
  Script Inno Setup per il setup finale Windows.
- `build-setup.ps1`
  Build del setup `.exe`.

## Funzionalita implementate

- selezione cartella video
- selezione percorso VLC
- scansione file video supportati
- playback video singolo
- playback playlist cartella
- fullscreen, loop e video on top in VLC
- avvio con Windows
- modalita kiosk
- pannello web con token
- upload file da web con progress bar
- delete file da web
- integrazione ngrok
- integrazione bot Telegram
- installer `.exe`
- icona applicazione
- disinstallazione con cleanup processi

## Formati video supportati

- `.mp4`
- `.mkv`
- `.avi`
- `.mov`
- `.wmv`
- `.m4v`
- `.webm`

## Output distributivi

- `dist\MarcaVecioStream.exe`
- `dist\WebServer.exe`
- `dist\TelegramWorker.exe`
- `release\MarcaVecioStream-Setup.exe`
