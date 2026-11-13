"""Checks that a pymobiledevice3 install still provides everything PhoneDeck relies on.

Run with the Python to check (the embedded one by default, see `make check`):

    build/python/bin/python3 -I scripts/check.py [--helper Resources/pmd3bar_helper.py] [--udid UDID]
                                                [--no-device] [--location]

Static checks (no iPhone needed): CLI commands and options, Python APIs used by the helper,
viewer assets, strings PhoneDeck waits for.
Device checks (first reachable iPhone, or --udid): device listing, mount status JSON, files,
apps, system log, serve-web viewer. --location also sets and then clears a simulated location.

Exit code 0 = everything passed, 1 = something failed.
"""

import argparse
import base64
import importlib
import importlib.resources
import inspect
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

PY = sys.executable
MIRROR_MIN_IOS = 27  # serve-web: "Screen streaming needs iOS 27.0 or later"
RESULTS: list[tuple[bool, str, str]] = []


def record(ok: bool, name: str, detail: str = "") -> bool:
    RESULTS.append((ok, name, detail))
    mark = "\033[32m✓\033[0m" if ok else "\033[31m✗\033[0m"
    print(f"  {mark} {name}" + (f"  — {detail}" if detail and not ok else ""))
    return ok


def env(udid: str | None = None) -> dict:
    e = dict(os.environ, NO_COLOR="1", TERM="dumb", COLUMNS="200", PYTHONDONTWRITEBYTECODE="1")
    e.pop("PYMOBILEDEVICE3_UDID", None)
    if udid:
        e["PYMOBILEDEVICE3_UDID"] = udid
    return e


def pmd3(*args: str, udid: str | None = None, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run([PY, "-I", "-m", "pymobiledevice3", *args], capture_output=True, text=True,
                          env=env(udid), timeout=timeout)


def last_line(text: str) -> str:
    """The most useful line of an error output: the last ERROR log line, else the last line."""
    lines = [l.strip(" │╭╰─") for l in text.strip().splitlines() if l.strip(" │╭╰─")]
    errors = [l.split(" ERROR ", 1)[-1] for l in lines if " ERROR " in l]
    return (errors or lines or [""])[-1][:200]


def skip(name: str, why: str) -> None:
    print(f"  – {name}: saltato ({why})")


# ---------------------------------------------------------------- static checks

# (command, options PhoneDeck passes to it)
CLI = [
    (["version"], []),
    (["mounter", "list"], ["--udid"]),
    (["mounter", "auto-mount"], ["--udid"]),
    (["developer", "core-device", "display", "serve-web"], ["--http-port", "--bind", "--password"]),
    (["developer", "core-device", "launch-application"], ["--env", "--kill-existing", "--no-kill-existing", "--console"]),
    (["apps", "webdav"], ["--mount", "--documents"]),
    (["developer", "dvt", "simulate-location", "set"], []),
    (["developer", "dvt", "simulate-location", "clear"], []),
    (["syslog", "live"], ["--format", "--no-debug", "--no-info", "--process-name", "--match-insensitive"]),
    (["apps", "install"], []),
    (["apps", "uninstall"], []),
    (["afc", "push"], []),
    (["afc", "pull"], []),
    (["afc", "rm"], []),
    (["apps", "pull"], ["--documents"]),
    (["apps", "push"], ["--documents"]),
    (["apps", "rm"], ["--documents"]),
    (["diagnostics", "restart"], []),
    (["diagnostics", "shutdown"], []),
    (["developer", "dvt", "condition", "list"], []),
    (["developer", "dvt", "condition", "set"], []),
    (["developer", "dvt", "sysmon", "process", "single"], ["--key"]),
    (["developer", "dvt", "kill"], []),
    (["crash", "parse"], []),
    (["crash", "pull"], []),
]

# (module, attribute path, callable members it must have)
APIS = [
    ("pymobiledevice3.usbmux", "list_devices", []),
    ("pymobiledevice3.lockdown", "create_using_usbmux", []),
    ("pymobiledevice3.lockdown", "LockdownClient", ["short_info", "close"]),
    ("pymobiledevice3.services.afc", "AfcService", ["listdir", "stat", "__aenter__"]),
    ("pymobiledevice3.services.installation_proxy", "InstallationProxyService", ["get_apps", "__aenter__"]),
    ("pymobiledevice3.services.crash_reports", "CrashReportsManager", ["COPY_MOBILE_NAME"]),
    ("pymobiledevice3.services.springboard", "SpringBoardServicesService", ["get_icon_pngdata", "__aenter__"]),
    ("pymobiledevice3.services.house_arrest", "HouseArrestService", ["create", "__aenter__"]),
    ("pymobiledevice3.services.house_arrest", "DOCUMENTS_ROOT", []),
    ("pymobiledevice3.exceptions", "AppNotInstalledError", []),
    ("pymobiledevice3.services.diagnostics", "DiagnosticsService", ["get_battery", "__aenter__"]),
    ("pymobiledevice3.lockdown", "LockdownClient", ["get_value"]),
    ("pymobiledevice3.services.pcapd", "PcapdService", ["watch", "write_to_pcap", "__aenter__"]),
    ("pymobiledevice3.services.webdav_mount", "webdav_mount_supported", []),
]


def static_checks() -> None:
    print("Comandi e opzioni")
    for cmd, opts in CLI:
        r = pmd3(*cmd, "-h", timeout=60)
        name = " ".join(cmd)
        if r.returncode != 0:
            record(False, name, last_line(r.stdout + r.stderr))
            continue
        missing = [o for o in opts if o not in r.stdout]
        record(not missing, name + (f" {' '.join(opts)}" if opts else ""),
               f"opzioni mancanti: {', '.join(missing)}" if missing else "")

    print("API Python usate da pmd3bar_helper.py")
    for module, attr, members in APIS:
        name = f"{module}.{attr}"
        try:
            obj = getattr(importlib.import_module(module), attr)
        except Exception as e:  # noqa: BLE001
            record(False, name, f"{type(e).__name__}: {e}")
            continue
        missing = [m for m in members if not hasattr(obj, m)]
        record(not missing, name, f"membri mancanti: {', '.join(missing)}" if missing else "")
    try:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        params = inspect.signature(InstallationProxyService.get_apps).parameters
        record("application_type" in params, "InstallationProxyService.get_apps(application_type=…)",
               "parametro application_type assente")
    except Exception as e:  # noqa: BLE001
        record(False, "InstallationProxyService.get_apps(application_type=…)", str(e))
    try:
        from pymobiledevice3.services.house_arrest import HouseArrestService
        params = inspect.signature(HouseArrestService.create).parameters
        record({"bundle_id", "documents_only"} <= set(params), "HouseArrestService.create(bundle_id, documents_only=…)",
               "parametri cambiati: aggiorna container_ls in pmd3bar_helper.py")
    except Exception as e:  # noqa: BLE001
        record(False, "HouseArrestService.create(bundle_id, documents_only=…)", str(e))

    try:
        from pymobiledevice3.services.webdav_mount import webdav_mount_supported
        record(webdav_mount_supported(), "mount_webdav disponibile (Open in Finder)", "mount_webdav non trovato")
    except Exception as e:  # noqa: BLE001
        record(False, "mount_webdav disponibile (Open in Finder)", str(e))

    print("Viewer e testi attesi")
    try:
        viewer = importlib.resources.files("pymobiledevice3.resources") / "serve_web"
        html = (viewer / "viewer.html").read_text()
        record('<canvas id="c"' in html, "viewer.html ha il canvas id=\"c\" (registrazione)",
               "canvas non trovato: va aggiornato bridgeJS in WebView.swift")
        record((viewer / "viewer.js").is_file(), "viewer.js presente")
        layout_ids = ["topbar", "left-tray", "right-tray", "bottom-row"]
        missing = [i for i in layout_ids if f'id="{i}"' not in html]
        record(not missing, "viewer.html ha topbar, trays e bottom-row (modalità solo iPhone)",
               f"id mancanti: {', '.join(missing)}: aggiorna layoutJS in WebView.swift")
        js = (viewer / "viewer.js").read_text()
        record("+ 48 + 40" in js,
               "viewer.js: fitCanvasToViewport riserva 88 px in larghezza (dimensione finestra)",
               "cambiato: aggiorna ViewerLayout.viewerReservedWidth (ViewerLayout.swift)")
        record("function fitCanvasToViewport" in js and "innerHeight - 150" in js,
               "viewer.js: fitCanvasToViewport riserva 150 px in altezza (modalità solo iPhone)",
               "cambiato: aggiorna VIEWER_RESERVED_H in layoutJS (WebView.swift)")
        record('id="brand-logo"' in html and 'id="brand"' in html,
               "viewer.html ha #brand-logo e #brand (nascosti dall'app)",
               "id cambiati: il logo di pymobiledevice3 ricomparirebbe, aggiorna layoutJS in WebView.swift")
    except Exception as e:  # noqa: BLE001
        record(False, "risorse del viewer", str(e))
    root = Path(importlib.import_module("pymobiledevice3").__file__).parent
    stream_src = (root / "remote" / "core_device" / "screen_stream.py").read_text(errors="ignore")
    routes = ['"/clipboard"', '"/clipboard/image"', '"/key"', "_CLIPBOARD_MAX_BODY = 32 * 1024 * 1024"]
    missing = [r for r in routes if r not in stream_src]
    record(not missing, "serve-web: /clipboard, /clipboard/image, /key e limite 32 MB (Paste from Mac)",
           f"mancanti: {', '.join(missing)}: aggiorna MacPaste (MacPaste.swift) e pasteFromMac (WebView.swift)")
    webdav_src = (root / "services" / "webdav.py").read_text(errors="ignore")
    record("Mounted; revealed " in webdav_src and "Automatic mount is unavailable" in webdav_src,
           "testi attesi da apps webdav --mount",
           "cambiati: aggiorna WebDAVOutput (LiveOutput.swift)")
    found = any("Press Ctrl+C" in p.read_text(errors="ignore") for p in root.rglob("*.py"))
    record(found, "testo \"Ctrl+C\" atteso da simulate-location set",
           "non trovato: DeviceTools.setLocation non capirà quando la posizione è attiva")


# ---------------------------------------------------------------- device checks

def helper(helper_path: str, *args: str, udid: str | None = None, timeout: int = 60):
    r = subprocess.run([PY, "-I", helper_path, *args], capture_output=True, text=True,
                       env=env(udid), timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(last_line(r.stderr) or f"exit {r.returncode}")
    return json.loads(r.stdout)


def free_port(start: int = 18080) -> int:
    for port in range(start, start + 200):
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError("nessuna porta libera")


def stop(p: subprocess.Popen) -> None:
    if p.poll() is None:
        p.send_signal(2)  # SIGINT, like PhoneDeck
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.terminate()
            p.wait(5)


def device_checks(helper_path: str, udid: str | None, location: bool) -> None:
    print("Dispositivo")
    try:
        devices = helper(helper_path, "list")
        ok_entries = [d for d in devices if not d.get("error")]
        keys_ok = all({"udid", "connection", "name", "version"} <= set(d) for d in devices)
        record(keys_ok, "helper list", "campi mancanti nell'output")
    except Exception as e:  # noqa: BLE001
        record(False, "helper list", str(e))
        return
    def major(d: dict) -> int:
        try:
            return int(str(d.get("version") or "0").split(".")[0])
        except ValueError:
            return 0

    if udid is None:
        # Prefer an iPhone that can also be mirrored (iOS 27+), then USB over Wi-Fi.
        ranked = sorted(ok_entries, key=lambda d: (major(d) < MIRROR_MIN_IOS, d["connection"] != "USB"))
        udid = ranked[0]["udid"] if ranked else None
    if udid is None:
        print("  – nessun iPhone raggiungibile: controlli sul dispositivo saltati")
        return
    info = next((d for d in ok_entries if d["udid"] == udid), {"name": udid, "version": "?"})
    print(f"  iPhone: {info['name']} · iOS {info['version']} ({udid})")

    r = pmd3("mounter", "list", "--udid", udid, timeout=60)
    try:
        images = json.loads(r.stdout)
        shape = isinstance(images, list) and all(isinstance(i, dict) for i in images)
        known = all({"DiskImageType", "MountPath"} & set(i) for i in images)
        record(r.returncode == 0 and shape and known, "mounter list (JSON)",
               "formato cambiato: va aggiornato isDeveloperImageMounted in Models.swift")
    except json.JSONDecodeError:
        record(False, "mounter list (JSON)", last_line(r.stderr))

    try:
        files = helper(helper_path, "afc-ls", "/", udid=udid)
        record(bool(files) and {"name", "dir", "size"} <= set(files[0]), "helper afc-ls /")
    except Exception as e:  # noqa: BLE001
        record(False, "helper afc-ls /", str(e))

    try:
        crashes = helper(helper_path, "crash-ls", "/", udid=udid)
        record(isinstance(crashes, list) and (not crashes or {"name", "dir", "size", "mtime"} <= set(crashes[0])),
               f"helper crash-ls / ({len(crashes)} voci)")
    except Exception as e:  # noqa: BLE001
        record(False, "helper crash-ls /", str(e))

    apps = []
    try:
        apps = helper(helper_path, "apps", udid=udid, timeout=120)
        record(isinstance(apps, list) and (not apps or {"bundle_id", "name", "version"} == set(apps[0])),
               f"helper apps ({len(apps)} app)")
    except Exception as e:  # noqa: BLE001
        record(False, "helper apps", str(e))

    # Store apps usually refuse both their container and Documents: try a few, pass on the first that opens.
    refused = []
    for app in apps[:15]:
        bundle_id = app["bundle_id"]
        try:
            listing = helper(helper_path, "container-ls", bundle_id, "/", udid=udid)
        except Exception as e:  # noqa: BLE001
            if "doesn't share its files" in str(e):
                refused.append(bundle_id)
                continue
            record(False, f"helper container-ls {bundle_id}", str(e))
            break
        record(isinstance(listing.get("documents"), bool) and isinstance(listing.get("entries"), list),
               f"helper container-ls {bundle_id} (documents={listing.get('documents')})", "formato inatteso")
        break
    else:
        if refused:
            skip("helper container-ls", f"nessuna delle {len(refused)} app provate condivide i file "
                                        "(serve un'app firmata in sviluppo o con file sharing)")

    try:
        details = helper(helper_path, "info", udid=udid)
        record({"device", "disk", "battery", "errors"} <= set(details) and "ProductVersion" in details["device"],
               "helper info" + (f" (errori: {'; '.join(details['errors'])})" if details.get("errors") else ""),
               "campi mancanti")
    except Exception as e:  # noqa: BLE001
        record(False, "helper info", str(e))

    pcap_file = Path(tempfile.mkdtemp()) / "check.pcapng"
    p = subprocess.Popen([PY, "-I", helper_path, "pcap", str(pcap_file)], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env(udid))
    time.sleep(4)
    p.terminate()  # SIGTERM: the helper closes the file and exits 0
    try:
        out, err = p.communicate(timeout=10)
        lines = [json.loads(l) for l in out.decode().splitlines() if l.strip()]
        header_ok = pcap_file.read_bytes()[:4] == b"\x0a\x0d\x0d\x0a"
        record(p.returncode == 0 and header_ok and bool(lines) and "packets" in lines[-1],
               f"helper pcap ({lines[-1]['packets'] if lines else 0} pacchetti in 4 s)",
               last_line(err.decode()) or "file pcapng o riepilogo mancanti")
    except Exception as e:  # noqa: BLE001
        p.kill()
        record(False, "helper pcap", str(e))
    finally:
        shutil.rmtree(pcap_file.parent, ignore_errors=True)

    p = subprocess.Popen([PY, "-I", "-m", "pymobiledevice3", "syslog", "live", "--format", "json", "--no-debug"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env(udid))
    try:
        deadline = time.time() + 20
        line = ""
        while time.time() < deadline and not line:
            line = p.stdout.readline().decode(errors="replace").strip()
        try:
            entry = json.loads(line) if line else {}
        except json.JSONDecodeError:
            entry = {}
        record({"timestamp", "level", "filename", "message"} <= set(entry), "syslog live --format json",
               "nessuna riga JSON con timestamp/level/filename/message entro 20 s")
    finally:
        p.send_signal(2)
        time.sleep(1)
        if p.poll() is None:
            p.terminate()  # syslog live may ignore SIGINT under load
        p.wait(5)

    if major(info) < MIRROR_MIN_IOS:
        skip("serve-web", f"il mirroring richiede iOS {MIRROR_MIN_IOS}+")
    else:
        serve_web_check(udid)

    if location:
        location_check(udid)


def serve_web_check(udid: str) -> None:
    # Same flags as the app (MirrorSession.swift): loopback only, and a password on every request.
    port = free_port()
    password = secrets.token_urlsafe(18)
    auth = "Basic " + base64.b64encode(f"phonedeck:{password}".encode()).decode()
    p = subprocess.Popen([PY, "-I", "-m", "pymobiledevice3", "developer", "core-device", "display", "serve-web",
                          "--http-port", str(port), "--bind", "127.0.0.1", "--password", password],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env(udid))

    def get(with_auth: bool) -> tuple[int, str]:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/", headers={"Authorization": auth} if with_auth else {})
        try:
            with urllib.request.urlopen(req, timeout=1) as resp:
                return resp.status, resp.read().decode(errors="ignore")
        except urllib.error.HTTPError as e:
            return e.code, ""

    try:
        status, body = None, ""
        for _ in range(60):
            if p.poll() is not None:
                break
            try:
                status, body = get(with_auth=True)
                if status == 200:
                    break
            except Exception:  # noqa: BLE001
                time.sleep(1)
        if status == 200:
            record('id="c"' in body, f"serve-web answers on :{port} with the viewer canvas")
            record(get(with_auth=False)[0] == 401, "serve-web refuses requests without the password (401)")
        else:
            err = p.stderr.read().decode(errors="ignore") if p.poll() is not None else "timeout"
            record(False, "serve-web", last_line(err) + " (is the DDI mounted?)")
    finally:
        stop(p)


def location_check(udid: str) -> None:
    # -u: unbuffered, or the hint only shows up when the process exits (-I ignores PYTHONUNBUFFERED).
    p = subprocess.Popen([PY, "-I", "-u", "-m", "pymobiledevice3", "developer", "dvt", "simulate-location", "set",
                          "--", "41.902800", "12.496400"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env(udid))
    out = b""
    try:
        # The "Press Ctrl+C" hint is printed on stdout once the location is set.
        os.set_blocking(p.stdout.fileno(), False)
        deadline = time.time() + 45
        while time.time() < deadline and p.poll() is None and b"Ctrl+C" not in out:
            out += p.stdout.read() or b""
            time.sleep(0.5)
        record(b"Ctrl+C" in out, "simulate-location set", last_line(out.decode(errors="ignore")))
    finally:
        stop(p)
        r = pmd3("developer", "dvt", "simulate-location", "clear", udid=udid, timeout=90)
        record(r.returncode == 0, "simulate-location clear (posizione reale ripristinata)",
               last_line(r.stderr))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--helper", default=str(Path(__file__).resolve().parent.parent / "Resources" / "pmd3bar_helper.py"))
    ap.add_argument("--udid")
    ap.add_argument("--no-device", action="store_true", help="solo controlli statici")
    ap.add_argument("--location", action="store_true", help="prova anche la posizione simulata (imposta e ripristina)")
    a = ap.parse_args()

    r = pmd3("version", timeout=60)
    print(f"pymobiledevice3 {r.stdout.strip() or '?'} · {PY}\n")
    static_checks()
    if not a.no_device:
        device_checks(a.helper, a.udid, a.location)

    failed = [r for r in RESULTS if not r[0]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} controlli superati")
    if failed:
        print("Falliti:")
        for _, name, detail in failed:
            print(f"  - {name}: {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
