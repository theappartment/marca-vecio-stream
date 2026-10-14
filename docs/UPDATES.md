# Installazione, aggiornamenti e rollback

Versione corrente: 1.3.1, senza updater. Non contiene ricerca release, download installer, pulsanti aggiornamento o worker GitHub. Per aggiornare, scarica ed esegui manualmente il setup, usando la stessa destinazione.

La rimozione serve a verificare se l'updater contribuisce al blocco Defender Trojan:Win32/Powbr.A!MTB rilevato sulla 1.3.0. Non costituisce una conferma di falso positivo o di risoluzione: la prova deve essere svolta con Defender attivo. Nessuna protezione antivirus viene modificata.

L'installer rimuove dalla cartella del programma i vecchi file UpdateWorker, UpdateClient e UpdateUi; conserva configurazione, cataloghi, contenuti e credenziale GitHub eventualmente salvata nel profilo utente (non piu utilizzata). I processi della stessa installazione vengono fermati prima della sostituzione dei file.

La release originale 1.0.0 resta disponibile su https://github.com/theappartment/marca-vecio-stream/releases/tag/1.0.0 con installer e sorgenti/documentazione del relativo tag. Prima di un rollback conserva una copia di %APPDATA%\MarcaVecioStream. La versione originale gestisce solo i video montati e non supporta slide e composizioni reel.

La 1.3.0 con updater e documentata nel suo tag. La procedura di pubblicazione GitHub rimane attiva per produrre installer scaricabili manualmente; non e un componente dell'app installata.