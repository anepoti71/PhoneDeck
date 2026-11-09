# PMD3Bar

<img src="Resources/AppIcon.png" width="128" alt="Icona di PMD3Bar">

App per la barra dei menu di macOS per vedere e controllare uno o più iPhone dal Mac, via cavo o Wi-Fi.
Usa [pymobiledevice3](https://github.com/doronz88/pymobiledevice3), incluso nell'app con un suo
Python: non servono `sudo`, `tunneld` né il terminale.

Per installare, aggiornare e risolvere problemi vedi il **[RUNBOOK](RUNBOOK.md)**.

## Cosa fa

**Dalla barra dei menu**
- Elenca gli iPhone collegati via USB o Wi-Fi, con versione di iOS e stato della connessione.
- Mostra se la Developer Disk Image (DDI) è montata e la monta **da sola** quando colleghi un iPhone.
- Avvia il mirroring di ogni iPhone nella sua finestra. Si possono mirrorare più iPhone insieme.
  Gli iPhone con iOS precedente al 27 aprono la finestra con i soli Strumenti.
- **Notifiche** quando un iPhone si collega o si scollega, la DDI viene montata, un'installazione
  finisce o il mirroring si interrompe.
- **Scorciatoia globale ⌥⌘M** per mostrare o nascondere la finestra dell'iPhone selezionato.
- **Avvio al login**, attivabile dal menu (Impostazioni).

**In ogni finestra**
- Schermo dell'iPhone in tempo reale, con audio, tocchi, tastiera, tasti fisici e appunti condivisi.
  È il viewer web di pymobiledevice3, mostrato in una finestra nativa.
- Di base si vede **solo l'iPhone**. I controlli del viewer (zoom, rotazione, cornice, tasti, appunti,
  accessibilità) e gli Strumenti si aprono solo se li chiedi, dai pulsanti nella barra della finestra.
- Registrazione video dello schermo e screenshot, salvati in `~/Download`.
- Pannello **Strumenti** (icona a destra nella barra della finestra):
  - **App**: elenco delle app installate con icone, installazione di `.ipa`, avvio, disinstallazione.
  - **File**: cartella Media dell'iPhone (foto in `DCIM`), con download, caricamento ed eliminazione.
  - **Posizione**: posizione GPS simulata, scelta sulla mappa. Quando chiudi la finestra torna quella reale.
    La mappa parte dalla posizione del Mac o dall'ultima posizione simulata su quell'iPhone.
  - **Log**: log di sistema in tempo reale, con filtri ed esportazione.
- Trascina un `.ipa` sulla finestra per installarlo, o altri file per copiarli sull'iPhone.

## Requisiti

- Mac con Apple Silicon e macOS 14 o successivo.
- Swift 6: bastano i Command Line Tools (`xcode-select --install`), non serve Xcode.
- iPhone con iOS 17 o successivo, già abbinato al Mac almeno una volta via cavo.
  Per il mirroring serve iOS 27 o successivo; App, File, Posizione e Log funzionano anche prima.
- Modalità sviluppatore attiva sull'iPhone (Impostazioni ▸ Privacy e sicurezza ▸ Modalità sviluppatore).

## Avvio rapido

```bash
cd /Users/anepoti/workspace/experiments/PMD3Bar
make python    # una volta: prepara il Python incluso nell'app (circa 260 MB)
make install   # crea l'app e la copia in ~/Applications
open ~/Applications/PMD3Bar.app
```

Poi, dall'icona dell'iPhone nella barra dei menu: **Monta** la DDI, se serve, e premi ▶ accanto all'iPhone.

## Come è fatto

```
PMD3Bar.app/Contents/
├── MacOS/PMD3Bar                interfaccia SwiftUI (barra dei menu + finestre)
└── Resources/
    ├── python/                  CPython 3.12 standalone + pymobiledevice3 (versione fissata)
    └── pmd3bar_helper.py        funzioni Python che la riga di comando non offre
```

```
┌────────────── PMD3Bar (Swift) ──────────────┐
│ Barra dei menu   Finestre (WKWebView)        │
│      │                 │ http://127.0.0.1:8080, 8081…
└──────┼─────────────────┼─────────────────────┘
       │ processi figli  │
       ▼                 ▼
  python -m pymobiledevice3 …         ← un processo per comando,
  python pmd3bar_helper.py …            uno serve-web per ogni iPhone
       │
       ▼  usbmuxd (USB / Wi-Fi) + tunnel iOS 17+ senza root
    iPhone
```

- **L'app non importa Python**: lancia `python -m pymobiledevice3 …` come processo figlio e legge
  l'output JSON. L'iPhone su cui lavorare è indicato dalla variabile `PYMOBILEDEVICE3_UDID`.
- **Mirroring**: per ogni iPhone c'è un processo `developer core-device display serve-web` su una
  porta diversa (dalla 8080 in su). Ogni processo ha il suo tunnel, per questo più iPhone possono
  andare in parallelo.
- **`pmd3bar_helper.py`** fa quello che la riga di comando di pymobiledevice3 non permette:
  - elenca gli iPhone anche quando una connessione Wi-Fi non risponde (`usbmux list` in quel caso
    fallisce del tutto);
  - elenca le cartelle con tipo e dimensione dei file;
  - elenca le app solo con nome, bundle ID e versione, senza i metadati completi, che possono
    contenere chiavi delle app;
  - scarica le icone delle app con una sola connessione e le salva in `~/Library/Caches/PMD3Bar/icons`.
- **Quale Python**, in ordine di priorità:
  1. quello incluso nell'app;
  2. la variabile d'ambiente `PMD3_PYTHON`;
  3. `~/miniforge3/envs/pymobiledevice/bin/python` (comodo con `make dev`).

### Sorgenti

| File | Contenuto |
|---|---|
| `Sources/PMD3Bar/PMD3BarApp.swift` | Avvio dell'app e menu (elenco iPhone, DDI, impostazioni) |
| `Sources/PMD3Bar/AppModel.swift` | Stato: iPhone, DDI, sessioni di mirroring, strumenti |
| `Sources/PMD3Bar/MirrorSession.swift` | Gestione di un processo `serve-web`: avvio, stop, riavvio, porta |
| `Sources/PMD3Bar/MirrorWindow.swift` | Finestra per iPhone e pannello Strumenti |
| `Sources/PMD3Bar/WebView.swift` | WKWebView del viewer: download, registrazione, log della console |
| `Sources/PMD3Bar/DeviceTools.swift` | App, file, posizione e log di sistema di un iPhone |
| `Sources/PMD3Bar/PMD3.swift` | Ricerca del Python, esecuzione dei comandi, log |
| `Sources/PMD3Bar/Models.swift` | Lettura del JSON, stati |
| `Sources/PMD3Bar/Integrations.swift` | Notifiche, scorciatoia globale ⌥⌘M, avvio al login |
| `Sources/PMD3Bar/MenuBarIcon.swift` | Icona della barra dei menu (template monocromatico, una variante per stato) |
| `Resources/pmd3bar_helper.py` | Funzioni Python aggiuntive (vedi sopra) |
| `Resources/Info.plist` | Metadati del bundle (app della barra dei menu, `LSUIElement`, icona) |
| `Resources/AppIcon-source.png` | Disegno originale dell'icona |
| `Resources/AppIcon.icns`, `AppIcon.png` | Icona dell'app generata da `make icon` |
| `scripts/make-icon.py` | Scontorna il disegno e genera tutte le dimensioni dell'icona |
| `scripts/fetch-python.sh` | Scarica CPython (sha256 verificato) e installa pymobiledevice3 |
| `scripts/build-app.sh` | Compila, crea `build/PMD3Bar.app` e la firma ad-hoc |
| `scripts/check.py` | Verifica che pymobiledevice3 offra tutto quello che l'app usa (`make check`) |
| `Makefile` | Comandi `dev`, `python`, `app`, `run`, `install`, `check`, `check-static`, `icon`, `clean` |

## Limiti noti

- Si mirrora un iPhone per finestra, solo con iOS 27 o successivo. La registrazione è solo video:
  l'audio resta dentro il viewer.
- Via Wi-Fi l'iPhone deve essere sbloccato o sveglio e sulla stessa rete. Il primo abbinamento richiede il cavo.
- Posizione simulata e avvio delle app richiedono la DDI montata.
- La posizione **reale** dell'iPhone non è leggibile dal Mac: i servizi per sviluppatori permettono
  solo di impostare o cancellare quella simulata, e nei log di `locationd` le coordinate sono
  oscurate. Per questo la mappa usa la posizione del Mac, che è vicino all'iPhone collegato.
- La firma è ad-hoc: l'app va bene su questo Mac. Per darla ad altri servono firma Developer ID e notarizzazione.
- L'app dipende da comandi e funzioni interne di pymobiledevice3: aggiornalo seguendo il [RUNBOOK](RUNBOOK.md#aggiornare-pymobiledevice3).

## Licenza

pymobiledevice3 è distribuito con licenza GPL-3.0-or-later. L'app lo include, quindi se la
distribuisci ad altri devi farlo con licenza GPL e rendere disponibile il codice sorgente.
