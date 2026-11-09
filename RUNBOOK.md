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
| `open build/PMD3Bar.app --args --open <UDID>` | Avvia e apre subito la finestra di quell'iPhone |

Per trovare l'UDID degli iPhone:
```bash
build/python/bin/python3 -I Resources/pmd3bar_helper.py list
```

**Avvio automatico al login**: Impostazioni di Sistema ▸ Generali ▸ Elementi login ▸ `+` ▸ `~/Applications/PMD3Bar.app`.

**Chiudere**: menu ▸ **Esci**. Si fermano anche tutti i mirroring, e i processi di posizione e log.

## 3. Usare l'app

1. Clicca l'icona dell'iPhone nella barra dei menu.
2. Seleziona un iPhone: la sezione **Developer Disk Image** si riferisce all'iPhone selezionato.
   Se è "Non montata" premi **Monta**. Ci vogliono pochi secondi via cavo, di più via Wi-Fi.
   Va rifatto dopo ogni riavvio dell'iPhone.
3. Premi ▶ accanto all'iPhone: si apre la sua finestra e parte il mirroring.
4. Nella barra della finestra:
   - ⏺ registra lo schermo in `~/Download`;
   - 🧭 apre lo stesso viewer nel browser;
   - ■ ferma il mirroring;
   - ▯ apre il pannello **Strumenti**: App, File, Posizione, Log.
5. Chiudendo la finestra si ferma il mirroring di quell'iPhone e torna la sua posizione reale.

Porte: il primo iPhone usa la "Porta iniziale" impostata nel menu (8080 se non la cambi), gli altri
le successive libere.

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

Una verifica automatica non c'è ancora: fai questi controlli a mano, con un iPhone collegato.
Ogni riga corrisponde a un punto in cui l'app dipende da pymobiledevice3.

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
