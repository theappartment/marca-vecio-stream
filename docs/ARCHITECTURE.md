# Architecture

La versione 1.2.6 esegue libvlc_media_player_stop su un Task. Durante il cambio, un DispatcherFrame breve mantiene i messaggi dell'HWND in elaborazione, con guardie PlaybackChangingContent/PlaybackUpdating per evitare rientranze. Stop nasconde le finestre e ritorna subito; gli HWND del vecchio player vengono mantenuti nascosti finche gli output VLC sono chiusi e poi eliminati sul thread UI. L'evento Closed confronta il sender con la superficie attuale per non fermare una riproduzione successiva. Timeout di 5 s sul cambio decoder: arresto immediato della rotazione e ritorno alla configurazione, con rilascio in background.

Versione 1.2.6: l'overlay diventa un Form nativo senza attivazione, posseduto dall'HWND del player. Il frame congelato viene copiato una sola volta in un bitmap PArgb; il compositing usa alpha globale via SetLayeredWindowAttributes su un timer C# a 16 ms, indipendente dal dispatcher WPF. Non si usa piu AllowsTransparency su una superficie WPF fullscreen. Generazioni del timer impediscono ai callback vecchi di alterare una nuova transizione. Il controllo UI rilascia la copertura al termine o dopo durata+250 ms; un errore alpha termina il worker. La prontezza VLC usa get_stats oppure tempo positivo e video_get_size, evitando dipendenze dalle statistiche; timeout di 8 s per video normali senza fotogrammi. I media terminati senza essere mai presentati vengono esclusi.

Versione 1.2.5: il frame precedente viene mostrato in una finestra WPF trasparente posseduta dalla finestra fullscreen, senza taskbar o attivazione. Questa finestra resta sopra gli HWND nativi di VLC, superando il limite airspace di WindowsFormsHost. Appena foto/video/scena reel sono pronti, l'opacity della copertura passa da 1 a 0 in 450 ms; al termine viene nascosta e il bitmap rilasciato. Stop annulla l'animazione e chiude entrambe le finestre. Per i video normali viene conservato un frame vicino al termine, prima che VLC chiuda l'output. La dissolvenza non introduce fade audio.

Versione 1.2.4: la scena reel viene preparata sotto un canvas Hidden, mantenendo il contenuto precedente con una copertura WPF. Per le foto la copertura riutilizza il bitmap gia caricato; per un video nella sessione interattiva conserva in memoria i pixel della finestra fullscreen prima di arrestare il decoder. Solo dopo la decodifica dei tre reel vengono rivelati canvas e host nella stessa operazione UI e rimossa la copertura. Il timer della scena parte al momento della presentazione. Nessuna cattura viene salvata o trasmessa.

Versione 1.2.2: `Get-MediaPreview` restituisce immagini originali oppure miniature video PNG in `%APPDATA%\MarcaVecioStream\previews`. La chiave include percorso, dimensione e data di modifica; un mutex coordina app e server. Windows Shell usa IShellItemImageFactory con THUMBNAILONLY, evitando le icone generiche; VLC costituisce il fallback con estrazione scene, senza audio o player visibili e con tempo limite. `/api/preview` serve anche video/reel, sempre dopo autenticazione e risoluzione del nome dal catalogo. La UI WPF carica le miniature OnLoad e conserva bitmap congelate senza bloccare la sorgente.

Versione 1.2.1: il planner distribuisce uniformemente le composizioni reel tra i contenuti di base, con fase casuale a ogni giro. Mantiene l'ordine relativo di foto e video normali; inserisce poi le ripetizioni delle promo secondo la frequenza globale. Le composizioni non vengono accumulate alla fine della playlist.

Versione 1.2.0: ogni elemento del catalogo ha `role` (`loop`, `reel`, `background`); i cataloghi precedenti vengono migrati a `loop`. Il planner raggruppa tutti i reel attivi in terne casuali, completando l'ultima terna dal pool, e genera scene di 30 secondi. La superficie conserva tre WindowsFormsHost e tre player LibVLC senza audio, oltre al player per i video normali. Il controller riavvia i reel terminati entro la scena e ferma tutti e tre prima di applicare le cancellazioni. Lo sfondo WPF viene caricato OnLoad senza bloccare il file; quello predefinito e incluso in `assets/reel-background.jpg`. Upload: parametro `role`; PATCH contenuto: campo `role`. Tutti i file della scena in corso sono protetti dalla pulizia differita.

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
7. L'app principale legge i comandi e li esegue nella finestra di riproduzione permanente, con VLC incorporato tramite LibVLC.
8. App Windows e server condividono le operazioni sul catalogo tramite `MediaCatalog.ps1`, protette da un mutex per cartella.

## Persistenza

Cartella dati utente:

`%APPDATA%\MarcaVecioStream`

File principali:

- `config.json`
- `state.json`
- `catalogs/<hash-cartella>.json`
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

`PlaybackController.ps1` costruisce una nuova sequenza a ogni giro. Le slide con priority=true sono le promo: vengono mostrate 2-5 volte ciascuna. Il catalogo le distribuisce in gruppi con un punto di partenza casuale e mescola le altre promo e le posizioni dei contenuti di base con Fisher-Yates. I contenuti di base mantengono il loro ordine relativo e compaiono una volta ciascuno. I gruppi evitano ripetizioni immediate quando ci sono abbastanza contenuti distinti; il controller gestisce anche il confine tra due giri. Senza promo l'ordine coincide con quello scelto dall'utente.

`PlaybackSurface.ps1` mantiene una singola finestra WPF fullscreen su fondo nero. Le foto sono caricate in memoria senza bloccare il file originale e vengono alternate su due livelli: il livello entrante sfuma da 0 a 1 in 450 ms, mantenendo quello uscente opaco. I video usano LibVLC a 64 bit, caricata dalla cartella del VLC configurato, e vengono riprodotti nel child HWND di un WindowsFormsHost della stessa finestra. Non ci sono finestre VLC autonome.

Il controller controlla i confini ogni 200 ms. Le foto usano la durata configurata; per i video vengono interrogati gli stati nativi playing/ended/error e la durata LibVLC. Il player e la finestra vengono creati all'avvio della rotazione e rilasciati solo con Stop, uscita o errore finale. Lo stato pubblico mantiene processId riferito al processo dell'app che ospita il player. I passaggi foto/video restano nella stessa superficie ma non applicano una dissolvenza al video nativo.

La finestra riceve il focus all'avvio. Esc viene intercettato dal PreviewKeyDown WPF e dal KeyDown del controllo Windows Forms. Un timer di 20 ms verifica inoltre il tasto durante il focus sul child HWND nativo VLC, solo quando il processo dell'app possiede la finestra in primo piano. Il timer viene rilasciato con la superficie. Esc esegue lo stesso Stop dei pannelli e lascia aperta l'app.

Ctrl+Alt+S usa RegisterHotKey con MOD_NOREPEAT e una HwndSourceHook per WM_HOTKEY, senza dipendere dal focus. La registrazione precede l'apertura fullscreen; un errore di registrazione annulla l'avvio invece di lasciare un player senza scorciatoia di uscita. Stop rilascia registrazione e hook prima di chiudere la superficie. La scorciatoia riporta poi la finestra di configurazione in primo piano, ripristinandola da minimizzata e aggiornando lo stato pubblico.

Ogni secondo l'app riconcilia catalogo e cartella, aggiorna lo stato pubblico e rileva modifiche. La nuova sequenza entra al prossimo confine tra contenuti, senza troncare quello corrente. I file segnalati per eliminazione vengono esclusi subito dalla sequenza futura e rimossi solo quando non sono in riproduzione. Gli errori VLC persistenti fermano la rotazione; i file illeggibili vengono saltati e segnalati.

Il catalogo mantiene frequenza globale e, per ogni file, ordine, abilitazione, priorita, durata e richiesta di eliminazione. La chiave e un hash del percorso assoluto normalizzato. Le scritture usano file temporanei e sostituzione atomica; un catalogo corrotto viene conservato e segnalato. Gli upload terminano su file temporanei, vengono validati e pubblicati con rename senza sovrascritture.

## Web server

Il web server ascolta in locale su:

`http://127.0.0.1:<porta>/`

Endpoint principali:

- `GET /api/status`
- `POST /api/play-selected`
- `POST /api/play-all`
- `POST /api/stop`
- `POST /api/upload`
- Il caricamento accetta `priority=true|false` nella query insieme a `filename`; se assente, la foto entra nel loop normale. La categoria viene salvata nella stessa operazione protetta dal mutex che pubblica il file. La scelta promo e riservata alle immagini; i due pannelli inviano false per i video di un batch misto.
- `DELETE /api/files`
- `POST /api/settings`
- `PATCH /api/content?name=<nome>`: aggiornamento parziale di `enabled`, `priority`, `durationSeconds`; priorita e durata solo per slide.
- `POST /api/order`: `{ "names": [...] }`, elenco completo in ordine, inclusi i contenuti in eliminazione; conflitti restituiscono 409.
- `POST /api/rotation`: `{ "priorityFrequency": 2..5 }`.
- `POST /api/slide-duration`: `{ "slideDurationSeconds": 1..300 }`, imposta la durata globale della cartella e aggiorna tutte le immagini; i video restano invariati.
- `GET /api/preview?name=<nome>`: immagine autenticata, senza cache pubblica.

`GET /api/status` conserva i campi esistenti e aggiunge metadati ai file, `priorityFrequency` e stato playback con nome corrente, messaggio, errore e modifiche in attesa. Il server legge i metadati direttamente dal catalogo per evitare di restituire modifiche obsolete. Le anteprime web usano blob ottenuti con il token nell'header. Errori di validazione: 400; autenticazione: 401; file mancanti: 404; duplicati o ordine obsoleto: 409.

La durata globale `slideDurationSeconds` viene esposta anche in `/api/status` e salvata nel catalogo, con valore iniziale 10. I vecchi cataloghi vengono migrati mantenendo le durate individuali. Il comando globale aggiorna le durate delle sole immagini e il valore ereditato dalle immagini caricate o rilevate successivamente. La rotazione continua a leggere la durata effettiva di ogni slide; i video terminano in base allo stato ended di LibVLC.

La build incorpora i moduli condivisi negli EXE: il runtime compilato non deve eseguire file PowerShell esterni e funziona anche con execution policy Restricted. I moduli vengono comunque distribuiti per l'avvio dai sorgenti. Il binding C# LibVLC viene compilato nel processo quando inizia la riproduzione.

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

Versione 1.2.7: animazioni DWM disabilitate sulla finestra della dissolvenza prima della prima visualizzazione. Fotogramma dipinto interamente in doppio buffer a opacita zero, poi mostrato; posizione e dimensioni fisse durante la variazione uniforme di opacita.

Versione 1.3.0: UpdateClient condiviso da app e UpdateWorker compilato. UpdateUi avvia il worker esclusivamente dai pulsanti, controlla soltanto il risultato del lavoro richiesto e avvia Inno Setup dopo verifica. Token privato separato con DPAPI per utente; nessuna ricerca all'avvio o periodica.

Versione 1.3.1: rimosso updater runtime e worker; installer elimina i file residui. Pubblicazione release GitHub mantenuta per installazione manuale.
