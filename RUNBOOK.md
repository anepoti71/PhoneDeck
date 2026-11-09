# PMD3Bar: runbook

Procedure per compilare, eseguire, aggiornare e risolvere i problemi di PMD3Bar.
Per una descrizione del progetto vedi il [README](README.md).

Tutti i comandi si lanciano dalla cartella del progetto:

```bash
cd /Users/anepoti/workspace/experiments/PMD3Bar
```

- [1. Prima installazione](#1-prima-installazione)
- [2. Eseguire](#2-eseguire)
- [3. Usare l'app](#3-usare-lapp)
- [4. Aggiornare pymobiledevice3](#aggiornare-pymobiledevice3)
- [5. Aggiornare il Python incluso](#5-aggiornare-il-python-incluso)
- [6. Modificare il codice](#6-modificare-il-codice)
- [7. Log e diagnosi](#7-log-e-diagnosi)
- [8. Problemi frequenti](#8-problemi-frequenti)
- [9. Regole da rispettare](#9-regole-da-rispettare)
- [10. Cambiare l'icona](#10-cambiare-licona)

---

## 1. Prima installazione

**Prerequisiti**
```bash
xcode-select -p        # deve rispondere con un percorso; altrimenti: xcode-select --install
swift --version        # Swift 6.x
uname -m               # arm64 (il Python incluso è solo per Apple Silicon)
```

**Preparare l'iPhone (una volta sola)**
1. Collegalo con il cavo e tocca **Autorizza** sull'iPhone.
2. Attiva la modalità sviluppatore: Impostazioni ▸ Privacy e sicurezza ▸ Modalità sviluppatore,
   poi riavvia l'iPhone e conferma.
3. Per usarlo anche via Wi-Fi: Finder ▸ iPhone ▸ "Mostra questo iPhone quando è connesso al Wi-Fi".

**Compilare e installare**
```bash
make python     # scarica CPython 3.12 (sha256 verificato) + pymobiledevice3 in build/python
make install    # compila, crea build/PMD3Bar.app e la copia in ~/Applications
```

`make python` scarica circa 25 MB e installa un centinaio di pacchetti: serve una volta sola,
e poi solo per aggiornare pymobiledevice3.

## 2. Eseguire

| Comando | Cosa fa |
|---|---|
| `open ~/Applications/PMD3Bar.app` | Avvia l'app installata |
| `make run` | Ricrea `build/PMD3Bar.app` e la avvia (chiude prima quella aperta) |
| `make dev` | Esegue dai sorgenti con `swift run`, usando il Python del conda env |
| `make check` | Verifica pymobiledevice3 incluso (vedi [4.3](#43-verificare-dopo-laggiornamento)) |
| `open build/PMD3Bar.app --args --open <UDID>` | Avvia e apre subito la finestra di quell'iPhone |

Per trovare l'UDID degli iPhone:
```bash
build/python/bin/python3 -I Resources/pmd3bar_helper.py list
```

**Avvio automatico al login**: menu ▸ Impostazioni ▸ "Avvia al login". Attivalo dalla copia in
`~/Applications`: macOS registra il percorso dell'app da cui lo attivi.

**Chiudere**: menu ▸ **Esci**. Si fermano anche tutti i mirroring, e i processi di posizione e log.

## 3. Usare l'app

1. Clicca l'icona dell'iPhone nella barra dei menu.
2. Seleziona un iPhone: la sezione **Developer Disk Image** si riferisce all'iPhone selezionato.
   Con "Monta la Developer Disk Image appena colleghi un iPhone" attivo (predefinito), l'app la
   monta da sola, una volta per ogni collegamento. Se fallisce, premi **Monta** dopo aver risolto
   la causa (di solito la modalità sviluppatore spenta).
3. Premi ▶ accanto all'iPhone (o ⌥⌘M per l'iPhone selezionato): si apre la sua finestra e parte
   il mirroring. Per iPhone con iOS precedente al 27 il pulsante è 🔧 e apre solo gli Strumenti.
4. Nella barra della finestra:
   - ⏺ registra lo schermo in `~/Download`;
   - 🧭 apre lo stesso viewer nel browser;
   - ■ ferma il mirroring;
   - ▯ apre il pannello **Strumenti**: App, File, Posizione, Log.
5. Chiudendo la finestra si ferma il mirroring di quell'iPhone e torna la sua posizione reale.

Porte: il primo iPhone usa la "Porta iniziale" impostata nel menu (8080 se non la cambi), gli altri
le successive libere.

**Impostazioni** (menu ▸ Impostazioni):

| Opzione | Predefinito | Note |
|---|---|---|
| Monta la DDI appena colleghi un iPhone | sì | Un tentativo per collegamento; riprova dopo uno scollegamento di oltre 20 s |
| Notifiche | sì | La prima volta macOS chiede il permesso. Collegamenti e scollegamenti sono notificati solo dopo 20 s, per non avvisare a ogni standby via Wi-Fi |
| Scorciatoia ⌥⌘M | sì | Se un'altra app la usa già, l'app lo segnala sotto le opzioni |
| Avvia al login | no | Solo dall'app compilata (`.app`), non con `make dev` |
| Porta iniziale | 8080 | |

## Aggiornare pymobiledevice3

L'app contiene **una sua copia** di pymobiledevice3, a una versione fissata in
`scripts/fetch-python.sh` (`PMD3_VERSION`, oggi `11.50.3`). Gli aggiornamenti pubblicati non
cambiano niente finché non aggiorni tu, e il conda env `pymobiledevice` è separato.

### 4.1 Controllare se c'è una nuova versione
```bash
build/python/bin/python3 -I -m pip index versions pymobiledevice3 | head -1
```
Novità e note di rilascio: https://github.com/doronz88/pymobiledevice3/releases

### 4.2 Aggiornare
```bash
PMD3_VERSION=11.51.0 make python     # sostituisci con la versione voluta
make install
```

Per provare una correzione non ancora rilasciata, usa il `master` di GitHub:
```bash
PMD3_SPEC="git+https://github.com/doronz88/pymobiledevice3.git@master" make python && make install
```

Per rendere permanente la nuova versione, aggiorna `PMD3_VERSION` in `scripts/fetch-python.sh`.

> **Attenzione:** `make python` cancella `build/python` *prima* di installare. Se l'installazione
> fallisce, l'app compilata dopo non avrà Python. L'app già installata in `~/Applications` non
> viene toccata finché non lanci `make install`.

### 4.3 Verificare dopo l'aggiornamento

```bash
make check                          # controlli statici + iPhone collegato
make check-static                   # solo controlli statici, senza iPhone
make check CHECK_ARGS="--location"  # anche la posizione simulata (imposta Roma e ripristina)
make check CHECK_ARGS="--udid <UDID>"   # su un iPhone preciso
```

`scripts/check.py` verifica:
- **senza iPhone**: comandi e opzioni usati dall'app, funzioni Python usate da `pmd3bar_helper.py`,
  il canvas del viewer, il testo "Ctrl+C" atteso dalla posizione simulata;
- **con iPhone**: elenco dispositivi, stato DDI, file, app, log di sistema, viewer `serve-web`
  (solo iOS 27 e successivi; sugli altri viene saltato).

Esce con codice 0 se tutto passa e, per ogni controllo fallito, indica cosa sistemare. Sceglie da
solo un iPhone raggiungibile, preferendo quelli con iOS 27 o successivo e quelli via USB.

Se un controllo fallisce, questa tabella dice dove guardare. Le stesse prove si possono fare a
mano dall'app:

| # | Prova | Se fallisce, guarda… |
|---|---|---|
| 1 | Il menu mostra l'iPhone con nome e versione di iOS | `pmd3bar_helper.py list` (funzioni interne `usbmux.list_devices`, `create_using_usbmux`) |
| 2 | Lo stato della DDI è corretto, **Monta** funziona | JSON di `mounter list`, opzione `mounter auto-mount --udid` |
| 3 | ▶ apre la finestra e si vede lo schermo | `developer core-device display serve-web --http-port` |
| 4 | ⏺ registra e salva un video | id del canvas `c` nel viewer (`WebView.swift`, `bridgeJS`) |
| 5 | Strumenti ▸ App mostra l'elenco | `pmd3bar_helper.py apps` (`InstallationProxyService.get_apps`) |
| 6 | Strumenti ▸ File mostra le cartelle | `pmd3bar_helper.py afc-ls` (`AfcService.listdir/stat`) |
| 7 | Strumenti ▸ Posizione: "Attiva" in pochi secondi | testo "Ctrl+C" stampato da `simulate-location set` (`DeviceTools.setLocation`) |
| 8 | Strumenti ▸ Log mostra righe | opzioni `syslog live --format json --no-debug --no-info --process-name --match-insensitive` |
| 9 | Strumenti ▸ App ▸ avvia un'app | `developer core-device launch-application` |

Controlli rapidi da terminale:
```bash
PY="build/python/bin/python3 -I"
$PY -m pymobiledevice3 version
$PY Resources/pmd3bar_helper.py list
PYMOBILEDEVICE3_UDID=<UDID> $PY Resources/pmd3bar_helper.py afc-ls /
PYMOBILEDEVICE3_UDID=<UDID> $PY Resources/pmd3bar_helper.py apps | head -c 300
$PY -m pymobiledevice3 developer core-device display serve-web -h | grep -- --http-port
$PY -m pymobiledevice3 syslog live -h | grep -E -- '--format|--no-info|--process-name'
```

### 4.4 Tornare alla versione precedente
```bash
PMD3_VERSION=11.50.3 make python && make install
```

## 5. Aggiornare il Python incluso

Versione, URL e sha256 sono fissati in `scripts/fetch-python.sh` (`PBS_TAG`, `PBS_FILE`, `PBS_SHA256`).
Per aggiornarli:

1. Scegli una release di https://github.com/astral-sh/python-build-standalone/releases che abbia
   almeno due settimane.
2. Prendi il file `cpython-3.12.X+TAG-aarch64-apple-darwin-install_only.tar.gz` e il suo sha256:
   ```bash
   gh api repos/astral-sh/python-build-standalone/releases/tags/<TAG> \
     -q '.assets[] | select(.name|test("aarch64-apple-darwin-install_only.tar.gz$")) | .name+" "+.digest'
   ```
3. Aggiorna le tre variabili, poi `make python && make install`.

Se cambi la versione minore di Python (per esempio da 3.12 a 3.13), aggiorna anche i percorsi
`lib/python3.12` in `fetch-python.sh`.

## 6. Modificare il codice

| Voglio… | Comando |
|---|---|
| Provare una modifica Swift al volo | `make dev` (usa il conda env, non serve `make python`) |
| Ricreare e avviare l'app | `make run` |
| Solo controllare che compili | `swift build -c release --arch arm64` |
| Provare `pmd3bar_helper.py` | `build/python/bin/python3 -I Resources/pmd3bar_helper.py list` |
| Pulire | `make clean` (lascia `build/python`) |

- Gli errori di SourceKit nell'editor ("Cannot find type…") sono falsi positivi, perché l'editor
  non vede il pacchetto Swift. Fa fede `swift build`.
- Il viewer web (HTML/JS/CSS) è dentro pymobiledevice3: non modificarlo lì, perché si perde al
  prossimo aggiornamento. Aggiungi le funzioni nell'app (`WebView.swift`, `bridgeJS`) o proponile a upstream.
- I comandi lunghi (mirroring, posizione, log) vanno sempre fermati prima con SIGINT, poi, se
  ancora attivi dopo qualche secondo, con SIGTERM. `syslog live` ignora SIGINT quando riceve
  molte righe.

## 7. Log e diagnosi

- **Log dell'app**: `~/Library/Logs/PMD3Bar/pmd3bar.log` (menu ▸ **Log**). Contiene ogni comando
  lanciato con il suo codice di uscita e gli errori, l'output di `serve-web` e gli errori del viewer
  (`[viewer] …`).
  ```bash
  tail -f ~/Library/Logs/PMD3Bar/pmd3bar.log
  ```
- **Viewer nella finestra**: Safari ▸ Sviluppo ▸ *nome del Mac* ▸ PMD3Bar, per ispezionare il WKWebView.
- **Processi attivi**:
  ```bash
  pgrep -fl 'PMD3Bar|pymobiledevice3'
  ```
- **Chi occupa una porta**: `lsof -nP -iTCP:8080 -sTCP:LISTEN`

## 8. Problemi frequenti

| Sintomo | Causa | Soluzione |
|---|---|---|
| "Nessun dispositivo" | iPhone non abbinato, bloccato o su un'altra rete | Collega il cavo e tocca Autorizza. Per il Wi-Fi: sbloccalo e mettilo sulla stessa rete |
| iPhone in arancione "non raggiungibile" | usbmuxd lo vede via Wi-Fi ma l'iPhone non risponde (standby) | Sblocca l'iPhone; si aggiorna da solo entro 5 secondi |
| Mirroring "Il viewer non risponde" | DDI non montata, oppure modalità sviluppatore spenta | **Monta** la DDI, controlla la modalità sviluppatore, poi Riprova |
| Video che si blocca e riparte | Il viewer riavvia da solo lo stream quando non arrivano fotogrammi (`no AU progress` nel log) | Normale ogni tanto; se succede spesso usa il cavo |
| Il mirroring si ferma staccando il cavo | Il tunnel USB si interrompe | L'app lo riavvia da sola via Wi-Fi; se non succede premi ▶ |
| Porta 8081 invece di 8080 | 8080 è occupata da un altro processo | `lsof -nP -iTCP:8080 -sTCP:LISTEN`; se è un `serve-web` rimasto attivo vedi la riga sotto |
| `serve-web` ancora attivo dopo la chiusura | L'app è stata chiusa in modo forzato | `pkill -INT -f 'pymobiledevice3 developer core-device display serve-web'` |
| L'iPhone resta in una posizione simulata | L'app è stata chiusa in modo forzato con la posizione attiva | Strumenti ▸ Posizione ▸ **Ripristina reale**, oppure `PYMOBILEDEVICE3_UDID=<UDID> build/python/bin/python3 -I -m pymobiledevice3 developer dvt simulate-location clear` |
| `ModuleNotFoundError: No module named 'importlib'` nel log | L'app è stata ricreata mentre era aperta | Già gestito: `make run` e `make install` chiudono prima l'app. Riavviala |
| Pip non riesce ad aggiornare (Permission denied) | File creati da root, dopo aver usato `sudo` con pymobiledevice3 | `sudo rm -rf` della cartella indicata nell'errore; poi non usare più `sudo` |
| "Python con pymobiledevice3 non trovato" | Manca `build/python` (in `make dev`, manca il conda env) | `make python`, oppure imposta `PMD3_PYTHON=/percorso/python` |
| Registrazione che non parte | Il viewer è cambiato (canvas `c`), oppure lo stream non è ancora attivo | Aspetta il video; vedi il punto 4 della [verifica](#43-verificare-dopo-laggiornamento) |
| "Screen streaming needs iOS 27.0 or later" | iPhone con iOS precedente al 27 | Normale: per quell'iPhone usa gli Strumenti (pulsante 🔧) |
| Nessuna notifica | Permesso negato, oppure app avviata con `make dev` | Impostazioni di Sistema ▸ Notifiche ▸ PMD3Bar; usa l'app compilata |
| ⌥⌘M non fa niente | Scorciatoia già usata da un'altra app, oppure disattivata | Menu ▸ Impostazioni: c'è un messaggio rosso se la registrazione è fallita |
| Icona vecchia o generica in Dock, Finder o notifiche | Cache delle icone di macOS | `make install` registra di nuovo l'app; se non basta: `killall Dock NotificationCenter` |
| La mappa della Posizione non mostra dove si trova l'iPhone | Non si può leggere la posizione reale dell'iPhone (vedi README, Limiti noti) | La mappa parte dal Mac ("Questo Mac") o dall'ultima posizione simulata; il pulsante ◎ centra sul Mac |
| "Posizione del Mac non disponibile" | Permesso di localizzazione negato a PMD3Bar | Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Localizzazione ▸ PMD3Bar |
| Icone delle app mancanti | Cache vuota o iPhone non raggiungibile durante il caricamento | Pulsante ↻ nel pannello App; cache in `~/Library/Caches/PMD3Bar/icons` (si può cancellare) |

## 9. Regole da rispettare

1. **Mai `sudo`** con pymobiledevice3 o con pip: crea file di proprietà di root che poi bloccano
   gli aggiornamenti. L'unico caso che lo richiede è `remote tunneld`, che PMD3Bar non usa.
2. **Mai modificare** i file dentro `build/python` o dentro `site-packages`: il prossimo
   `make python` li sovrascrive. Le modifiche vanno nei sorgenti del progetto o proposte a upstream.
3. **Versioni fissate**: aggiorna pymobiledevice3 e Python apposta, uno alla volta, e fai sempre
   la [verifica](#43-verificare-dopo-laggiornamento) dopo.
4. **Esposizione in rete**: i viewer ascoltano solo su `127.0.0.1`. Chi raggiunge la porta può
   vedere e **controllare** l'iPhone: non esporla in rete senza password e HTTPS.
5. **Distribuzione**: l'app include software GPL-3.0. Se la dai ad altri, va distribuita con
   licenza GPL e con il codice sorgente.

## 10. Cambiare l'icona

L'icona dell'app (Dock, Finder, Cmd-Tab, notifiche, Spotlight) nasce da `Resources/AppIcon-source.png`:
un'immagine quadrata con il disegno su sfondo uniforme scuro.

```bash
cp ~/Downloads/nuova-icona.png Resources/AppIcon-source.png
make icon       # genera Resources/AppIcon.icns (16…1024 px) e Resources/AppIcon.png
make install    # ricrea l'app e la registra di nuovo, così macOS non usa l'icona in cache
```

`scripts/make-icon.py` toglie lo sfondo partendo dagli angoli: i colori scuri *dentro* il disegno
restano. Il disegno viene adattato alla griglia delle icone macOS (corpo di 824 px su tela di
1024, con ombra leggera). Se lo sfondo non è uniforme, va reso trasparente prima.

L'icona della **barra dei menu** è diversa: è un template monocromatico disegnato in codice
(`Sources/PMD3Bar/MenuBarIcon.swift`), perché macOS la colora da solo per tema chiaro e scuro.
Ha tre varianti: normale, mirroring attivo (pallino) e nessun iPhone (attenuata).
