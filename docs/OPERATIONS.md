# Operations Guide

## Installazione

Installer finale:

`release\MarcaVecioStream-Setup.exe`

Installazione prevista:

`C:\Program Files\MarcaVecioStream`

## Primo avvio

1. Apri l'app.
2. Seleziona la cartella contenuti (slide e video).
3. Verifica il percorso di `vlc.exe`.
4. Salva.
5. Se vuoi accesso remoto, verifica:
   - ngrok attivo
   - bot Telegram attivo
   - token remoto del pannello web

## Test funzionali consigliati

### Gestione slide

- caricare piu immagini JPG/PNG dall'app e dal pannello remoto
- controllare le anteprime, durata iniziale 10 secondi e durata personalizzata
- segnare slide prioritarie e scegliere frequenza da 2 a 5
- riordinare e attivare/disattivare contenuti
- modificare durante la riproduzione: il contenuto corrente deve terminare
- eliminare la slide corrente e controllare la rimozione dopo il termine
- disattivare tutto e verificare l'arresto con messaggio
- riavviare l'app e verificare persistenza
- mostrare slide verticali/orizzontali e MP4 sullo schermo del locale, controllando proporzioni, audio e passaggi

### Desktop

- aprire app
- selezionare cartella video
- salvare configurazione
- chiudere e riaprire app
- verificare persistenza configurazione

### Playback

- riprodurre video singolo
- riprodurre playlist cartella
- verificare full screen
- verificare loop
- verificare sempre in primo piano

### Web

- aprire `http://127.0.0.1:8090/`
- inserire token
- vedere lista file
- caricare file
- vedere progress bar upload
- eseguire play/stop

### Telegram

- `/start`
- `/subscribe`
- `/url`
- `/status`

### Disinstallazione

- disinstallare da Windows
- verificare chiusura processi:
  - `MarcaVecioStream`
  - `WebServer`
  - `TelegramWorker`
  - `ngrok`

## Troubleshooting rapido

### L'app non si apre

Controllare:

- `%APPDATA%\MarcaVecioStream\app.log`

### Il bot Telegram non risponde

Controllare:

- `%APPDATA%\MarcaVecioStream\telegram.log`

### Il pannello web non mostra l'ultima versione

Provare:

- reinstallazione setup
- `Ctrl+F5`
- finestra anonima browser

### ngrok non si installa

Verificare:

- permessi su `Program Files`
- fallback in `%LOCALAPPDATA%`
- file `ngrok.exe` non bloccato
