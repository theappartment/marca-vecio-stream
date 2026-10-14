# Marca Vecio Stream

Applicazione Windows per gestire slide JPG/PNG, video e composizioni reel in una rotazione fullscreen con VLC, dall'app o dal pannello web remoto. Versione 1.3.1.

L'installer arresta automaticamente l'app e i suoi processi ausiliari nella cartella di installazione prima di sostituire i file. Alla chiusura dell'app vengono fermati anche i processi ausiliari gia presenti e riutilizzati all'avvio. Configurazione e contenuti vengono conservati durante l'aggiornamento.

La finestra di riproduzione resta aperta durante tutta la rotazione. Le foto passano con una dissolvenza di 450 ms; i video vengono riprodotti con VLC incorporato nella stessa finestra. I passaggi foto/video mantengono lo sfondo nero e non aprono finestre VLC separate.

**Ctrl + Alt + S** ferma foto e video, chiude il fullscreen e riporta in primo piano l'app di configurazione, ripristinandola se era minimizzata. La combinazione e globale mentre il player e aperto: funziona anche se il focus e su una finestra sotto al player. Viene rilasciata quando termina la riproduzione. Se e gia usata da un'altra applicazione, il player non parte e mostra il motivo. Esc resta disponibile quando il focus e sull'app. Puoi sempre usare Stop dal pannello web.

## Slide, priorita e video

L'arresto dei decoder VLC avviene in background: durante un cambio contenuto l'interfaccia continua a gestire i messaggi Windows. Stop nasconde subito il player e libera le risorse appena i decoder hanno terminato. Se un decoder non si arresta entro 5 secondi, la rotazione viene fermata con una segnalazione e viene riaperta la configurazione, invece di ripetere l'attesa sulla stessa schermata.

Le dissolvenze usano un bitmap statico e l'opacita nativa di Windows, senza animare una superficie WPF trasparente a schermo intero. Un controllo di sicurezza rimuove la copertura se la transizione non termina; il segnale di prontezza video funziona anche quando le statistiche VLC sono disabilitate. Un video normale senza fotogrammi pronti entro 8 secondi viene saltato con una segnalazione, evitando attese indefinite sulla schermata precedente.

Tutti i passaggi tra foto, video normali e composizioni reel hanno una dissolvenza di 450 ms. Durante il caricamento rimane visibile il contenuto precedente; appena il nuovo contenuto e pronto, il frame precedente sfuma sopra la nuova immagine o il video in riproduzione. La dissolvenza e visiva: l'audio dei normali video resta invariato, i reel restano senza audio e Stop/Ctrl+Alt+S interrompono immediatamente anche una transizione in corso.

All'avvio di una composizione reel, lo sfondo e i tre riquadri restano nascosti fino a quando tutti i video leggibili hanno fotogrammi decodificati. Il contenuto precedente rimane visibile durante la preparazione, poi viene mostrata la composizione completa. I 30 secondi partono dalla presentazione della scena. I reel brevi si ripetono internamente a VLC, mantenendo il decoder e la finestra, senza riaprire il file dal controller a ogni fine video. La composizione conserva il limite di 30 secondi.

Foto, sfondi, video normali e reel hanno un'anteprima accanto ai controlli, sia nell'elenco dell'app Windows sia nel pannello web. Selezionando un contenuto nell'app compare anche l'anteprima nel riquadro di modifica. Per i video si mostra un fotogramma, generato senza audio e salvato in cache; le immagini vengono mostrate direttamente. Le anteprime web richiedono lo stesso token del pannello. Un contenuto non leggibile viene indicato con **Anteprima non disponibile** e resta selezionabile per eliminarlo o disattivarlo.

Per caricare video verticali scegli **Reel (video)**. Ogni giro abbina casualmente i reel attivi in gruppi di tre, intervallando le composizioni con foto e video del loop normale e distribuendo le promo nell'intero giro. Ogni reel compare almeno una volta per giro. L'ultimo gruppo viene completato con altri reel attivi: con uno o due video disponibili alcune posizioni vengono riutilizzate. Ogni composizione dura 30 secondi; i video piu brevi ripartono fino al termine, quelli piu lunghi vengono interrotti al limite. I tre reel sono senza audio. Il centro e a tutta altezza, i lati piu piccoli, nel layout 16:9 del riferimento. I video mantengono le proporzioni e non vengono ritagliati.

Lo sfondo fornito **COPERTINA FLYER_2 copy.jpg** e incluso come predefinito. Per sostituirlo scegli **Sfondo reel (foto)** al caricamento, oppure cambia la destinazione di una foto gia presente e salva. Lo sfondo attivo viene mostrato dietro ai tre video e non entra nella rotazione delle slide. La scelta di un nuovo sfondo disattiva il precedente; disattivando tutti gli sfondi personalizzati torna quello predefinito. Anche la destinazione dei video esistenti puo essere cambiata tra **Loop normale** e **Reel**. La durata globale delle immagini non modifica i 30 secondi delle composizioni reel. Modifiche e cancellazioni attendono la fine della composizione in corso; Ctrl+Alt+S interrompe immediatamente tutti e tre i reel e torna all'app.

Prima di caricare, scegli **Loop normale** oppure **Promo / evento** dal selettore accanto al pulsante di caricamento. La scelta vale per tutte le foto selezionate in quel caricamento, sia dall'app Windows sia dal pannello remoto. La foto viene pubblicata gia attiva e con la categoria scelta: non occorre modificarla dopo l'upload. I video di una selezione mista entrano nel loop normale e vengono riprodotti integralmente. Puoi modificare la categoria di una foto anche in seguito.

Segna le immagini degli eventi o delle promozioni come **Promo / evento**. Ogni promo appare da 2 a 5 volte per giro, secondo la frequenza globale, mentre gli altri contenuti appaiono una volta. A ogni giro l'app distribuisce le promo casualmente tra i contenuti di base, mantenendo l'ordine relativo del loop di base ed evitando ripetizioni immediate della stessa promo quando possibile. Le promo corrispondono alle slide precedentemente segnate come prioritarie: le selezioni esistenti vengono mantenute.

Per cambiare rapidamente la durata di tutte le immagini, imposta **Durata tutte le immagini (s)** e premi **Applica a tutte**, nell'app o nel pannello web. Il valore va da 1 a 300 secondi e viene salvato per la cartella corrente; anche le nuove immagini lo ereditano. Il comando aggiorna tutte le immagini, comprese quelle prioritarie o disattivate. I video mantengono sempre la loro durata completa. Le modifiche entrano dopo il contenuto in corso. Puoi ancora personalizzare una singola slide dal suo controllo durata; una nuova applicazione globale uniforma nuovamente tutte le immagini.

1. Seleziona la cartella contenuti e salva le impostazioni.
2. Usa **Carica slide / video** nell'app oppure **Carica file** nel pannello web. Puoi selezionare piu file insieme.
3. Seleziona una slide e imposta **Attivo**, **Prioritaria** e la durata da 1 a 300 secondi, quindi **Salva contenuto** / **Salva**. La durata iniziale e 10 secondi.
4. Scegli quante volte mostrare le slide prioritarie: da 2 a 5 apparizioni per giro, inizialmente 2. Gli altri contenuti compaiono una volta.
5. Riordina i contenuti con **Sposta su / giu**, quindi premi **Avvia rotazione**.

Le modifiche si applicano automaticamente quando termina il contenuto in corso. I video vengono riprodotti integralmente. Le ripetizioni delle slide prioritarie sono distribuite tra gli altri contenuti; quando una slide ha piu apparizioni di tutti gli altri contenuti insieme, alcune apparizioni consecutive sono inevitabili.

Gli eventi si attivano e disattivano manualmente. **Riproduci selezionato** mantiene in loop il solo contenuto attivo scelto. **Stop** interrompe subito la riproduzione. Se elimini il contenuto in corso, il file resta disponibile fino al termine e viene poi eliminato; nei pannelli appare come eliminazione in attesa.

I video esistenti vengono riconosciuti automaticamente come attivi, in ordine alfabetico. I nuovi contenuti vengono aggiunti in fondo. Impostazioni e ordine restano salvati dopo il riavvio, separatamente per ogni cartella. Un nome gia presente non viene sovrascritto: rinomina il nuovo file oppure elimina prima quello esistente.

## Documentazione

- [Panoramica progetto](docs/PROJECT-OVERVIEW.md)
- [Architettura](docs/ARCHITECTURE.md)
- [Guida operativa](docs/OPERATIONS.md)
- [Backup e release GitHub](docs/GITHUB-RELEASE.md)

## Installazione e aggiornamenti

La versione 1.3.1 rimuove completamente l'updater introdotto nella 1.3.0, per confrontare il comportamento con Defender attivo. Gli aggiornamenti si installano manualmente dal setup. La rimozione non conferma che l'updater fosse la causa della segnalazione antivirus. Foto, video e impostazioni vengono conservati. Vedi [aggiornamenti e rollback](docs/UPDATES.md).

## Funzioni principali

- Selezione della cartella contenuti da monitorare.
- Slide con anteprime, durata, priorita e attivazione manuale in entrambi i pannelli.
- Rotazione mista aggiornata automaticamente in una finestra permanente, con video VLC incorporati e dissolvenza tra foto.
- Rilevamento automatico del percorso di `vlc.exe` nei percorsi piu comuni.
- Elenco dei video compatibili presenti nella cartella.
- Avvio di un singolo video in loop a schermo intero.
- Avvio della rotazione dei contenuti attivi in full screen e loop.
- Pulsante di stop che chiude solo l'istanza VLC avviata dall'app.
- Avvio automatico con Windows.
- Modalita kiosk con auto play e finestra minimizzata.
- Pannello web locale per controllo remoto, upload ed eliminazione file.
- Bot Telegram che pubblica la URL `ngrok` aggiornata e risponde ai comandi principali.
- Sezione impostazioni nell'app per modificare in qualunque momento il token Telegram.
- Salvataggio delle impostazioni in `%APPDATA%\MarcaVecioStream\config.json`.

## Requisiti

- Windows con PowerShell 5.1 o superiore.
- VLC a 64 bit installato sul PC, con `libvlc.dll` e `libvlccore.dll` nella stessa cartella di `vlc.exe`.

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

- Le slide supportate sono `.jpg`, `.jpeg`, `.png`. I video supportati sono `.mp4`, `.mkv`, `.avi`, `.mov`, `.wmv`, `.m4v`, `.webm`.
- Il player incorporato e stato verificato con VLC 3.0.23 a 64 bit. Non richiede una porta di controllo VLC aggiuntiva.
- Se VLC non viene rilevato automaticamente, seleziona manualmente `vlc.exe`.
- Il pannello web ascolta in locale su `127.0.0.1`, quindi per l'accesso remoto via Internet puoi esporlo con un tunnel come `ngrok`.
- Il setup Inno Setup aggiorna l'installazione Windows. Il catalogo si trova in `%APPDATA%\MarcaVecioStream\catalogs` e non viene cancellato dall'aggiornamento.

## Verifiche di sviluppo

Da PowerShell, nella cartella progetto:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Media.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Playback.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Transitions.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Escape.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GlobalStop.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Update.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Server.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Server.ps1 -Compiled
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WindowsUi.ps1
node .\tests\test-web.cjs
```

I test usano cartelle e configurazioni isolate. Il test playback usa una finestra nascosta e VLC senza output video o audio; il test transizioni controlla i fotogrammi renderizzati fuori schermo. Prima dell'uso sullo schermo del locale verificare fullscreen, proporzioni, audio e passaggi tra slide e video.

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
