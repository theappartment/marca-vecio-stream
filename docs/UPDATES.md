# Aggiornamenti e rollback

La ricerca avviene **solo** premendo **Cerca aggiornamenti** nell'app Windows. Non ci sono ricerche periodiche o all'avvio. Il download e l'installazione partono solo premendo **Scarica e installa**. Il controllo lavora in un processo separato e non blocca la configurazione o il playback.

## Accesso al repository privato

Il repository `theappartment/marca-vecio-stream` resta privato. Nell'account GitHub crea un personal access token fine-grained, limitato a questo repository, con permesso **Contents: Read-only**. Inseriscilo nella sezione **Aggiornamenti app** e premi **Salva accesso**. Un token classico deve avere accesso ai repository privati; e preferibile quello limitato al singolo repository.

L'accesso viene protetto da Windows per l'account corrente e salvato separatamente in `%APPDATA%\MarcaVecioStream\github-update.credential`. Non entra nel catalogo, nel pannello web o nel repository. Per rimuoverlo, lascia vuoto il campo e premi Salva accesso. Un altro account Windows deve configurare il proprio accesso. Non inviare token in chat o inserirli nei sorgenti.

## Installazione

L'app cerca l'ultima release stabile e confronta la versione con quella installata. Release di prova, pacchetti ancora in caricamento e downgrade non vengono proposti. L'installer viene scaricato in un file temporaneo e reso disponibile solo dopo la verifica delle dimensioni e del SHA256 dichiarati da GitHub. La verifica viene ripetuta prima dell'esecuzione.

Il download mantiene l'app aperta; un errore lascia in uso la versione attuale. Windows chiede il consenso amministratore per installare. Se annulli, l'app rimane aperta. Dopo l'avvio dell'installer l'app si chiude, l'installer ferma i componenti della stessa installazione e conserva file multimediali, configurazione, cataloghi, autoplay e kiosk. Completa l'installazione e riapri l'app.

## Versione originale per rollback

La release [1.0.0](https://github.com/theappartment/marca-vecio-stream/releases/tag/1.0.0), il relativo installer e il tag non vengono modificati o eliminati. I [sorgenti originali](https://github.com/theappartment/marca-vecio-stream/tree/1.0.0) includono il README e la documentazione originale. Il commit originale e `a02684d35517df86a867e593b0eaf10b31a5ee3a`.

Prima di un rollback, ferma il playback e copia l'intera cartella `%APPDATA%\MarcaVecioStream` per conservare anche i cataloghi. Scarica dalla release storica il suo installer e reinstalla la versione precedente. La 1.0.0 gestisce i video montati e non supporta slide, priorita o composizioni reel: i relativi metadati restano nel backup e tornano utilizzabili reinstallando una versione recente. Controlla la destinazione e il collegamento usato, poiche il vecchio installer puo usare un percorso diverso.

## Pubblicare nuove versioni

Il workflow `.github/workflows/release.yml` compila su Windows quando `main` contiene una versione non ancora pubblicata, oppure viene avviato manualmente da GitHub Actions. Ogni release contiene installer, documentazione e `SHA256SUMS.txt`; GitHub conserva anche i sorgenti del tag. Non sostituisce release esistenti.

Aggiorna insieme la versione in `src/UpdateClient.ps1`, `build-exe.ps1` e `installer.iss`; aggiungi `docs/releases/vVERSIONE.md`, esegui i test e pubblica il commit su `main`. Il workflow crea il tag `vVERSIONE` sul commit compilato. Le release precedenti rimangono scaricabili dal pulsante **Release e versioni precedenti**.

API utilizzate: [release GitHub](https://docs.github.com/en/rest/releases/releases), [download degli asset e digest](https://docs.github.com/en/rest/releases/assets).
