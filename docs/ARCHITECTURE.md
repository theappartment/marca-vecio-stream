# Architecture

## Flusso generale

1. L'utente avvia `MarcaVecioStream.exe`.
2. L'app carica `config.json` da `%APPDATA%\MarcaVecioStream`.
3. L'app avvia i processi ausiliari:
   - `WebServer.exe`
   - `TelegramWorker.exe`
   - `ngrok.exe` se abilitato
4. L'app mantiene aggiornato `state.json`.
5. Il pannello web legge lo stato via API HTTP locale.
6. I comandi remoti vengono scritti come file JSON nella cartella `commands`.
7. L'app principale legge i comandi e li esegue tramite VLC.

## Persistenza

Cartella dati utente:

`%APPDATA%\MarcaVecioStream`

File principali:

- `config.json`
- `state.json`
- `playlist.m3u`
- `app.log`
- `telegram.log`
- `telegram.pid`
- `webserver.pid`
- `ngrok.pid`

## Playback

L'app usa VLC con questi comportamenti:

- fullscreen
- loop
- video always on top
- finestra minimizzata all'avvio di VLC

Per playback cartella, l'app genera una playlist `.m3u`.

## Web server

Il web server ascolta in locale su:

`http://127.0.0.1:<porta>/`

Endpoint principali:

- `GET /api/status`
- `POST /api/play-selected`
- `POST /api/play-all`
- `POST /api/stop`
- `POST /api/upload`
- `DELETE /api/files`
- `POST /api/settings`

## Telegram worker

Il worker Telegram:

- interroga periodicamente Bot API
- gestisce `/start`
- gestisce `/subscribe`
- gestisce `/unsubscribe`
- gestisce `/url`
- gestisce `/status`
- notifica cambi URL ngrok alle chat registrate

## ngrok

ngrok viene usato per esporre il pannello web senza aprire porte manualmente sul router.

Percorso tipico binario:

`C:\Program Files\MarcaVecioStream\tools\ngrok\ngrok.exe`

Fallback runtime:

`%LOCALAPPDATA%\MarcaVecioStream\tools\ngrok\ngrok.exe`
