"""PMD3Bar helper: device listing that tolerates per-device failures.

`pymobiledevice3 usbmux list` aborts the whole listing when a single entry fails to answer lockdown
(common for Wi-Fi entries: usbmuxd keeps advertising an iPhone that just went to sleep or left the
network). This helper queries each usbmux entry on its own, with a timeout, and reports failures per
entry instead.

Commands (device chosen with PYMOBILEDEVICE3_UDID, USB preferred over Wi-Fi):
  list          JSON list of {udid, connection, name, version, product_type, error}
  afc-ls PATH   JSON list of {name, dir, size, mtime} under /var/mobile/Media/PATH
  container-ls BUNDLE_ID PATH [--documents]
                {documents, entries} for PATH inside an app's container. The whole container is
                vended only for development-signed apps: for the others it falls back to the
                Documents folder (documents = true), which is vended when the app shares files
  info          JSON object with device identity, storage and battery
  apps          JSON list of {bundle_id, name, version} of user apps (only these fields: the full
                install metadata can carry app secrets and is never printed)
  crash-ls PATH JSON list of {name, dir, size, mtime} of the crash reports under PATH
  crash-rm PATH deletes one crash report (or folder) under the crash reports directory
  icons DIR BUNDLE_ID...
                saves each app's home screen icon as DIR/<bundle_id>.png over one connection
                (skips icons already there); prints the JSON list of bundle ids saved
"""

import asyncio
import json
import os
import posixpath
import sys

from pymobiledevice3 import usbmux
from pymobiledevice3.lockdown import create_using_usbmux

LOCKDOWN_TIMEOUT = 6


class Refused(Exception):
    """An expected refusal from the iPhone: printed as one line on stderr, without a traceback."""


async def describe(device) -> dict:
    entry = {
        "udid": device.serial,
        "connection": device.connection_type,
        "name": None,
        "version": None,
        "product_type": None,
        "error": None,
    }
    lockdown = None
    try:
        lockdown = await asyncio.wait_for(
            create_using_usbmux(device.serial, autopair=False, connection_type=device.connection_type),
            LOCKDOWN_TIMEOUT,
        )
        info = lockdown.short_info
        entry["name"] = (info.get("DeviceName") or "").strip() or None
        entry["version"] = info.get("ProductVersion")
        entry["product_type"] = info.get("ProductType")
    except asyncio.TimeoutError:
        entry["error"] = "timeout"
    except Exception as e:  # noqa: BLE001 - report any failure for this entry, keep the others
        entry["error"] = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
    finally:
        if lockdown is not None:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    return entry


async def list_devices() -> list[dict]:
    devices = await usbmux.list_devices()
    return list(await asyncio.gather(*(describe(d) for d in devices)))


async def _lockdown():
    return await create_using_usbmux(serial=os.environ.get("PYMOBILEDEVICE3_UDID"))


async def _ls(afc, path: str) -> list[dict]:
    entries = []
    for name in sorted(await afc.listdir(path), key=str.lower):
        try:
            st = await afc.stat(posixpath.join(path, name))
        except Exception:  # noqa: BLE001 - entry vanished or unreadable: still list it
            st = {}
        mtime = st.get("st_mtime")
        entries.append({
            "name": name,
            "dir": st.get("st_ifmt") == "S_IFDIR",
            "size": int(st.get("st_size") or 0),
            "mtime": mtime.isoformat() if hasattr(mtime, "isoformat") else None,
        })
    return entries


async def afc_ls(path: str, crash_reports: bool = False) -> list[dict]:
    """Lists /var/mobile/Media, or the crash reports directory (same AFC protocol, other service)."""
    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.crash_reports import CrashReportsManager

    lockdown = await _lockdown()
    service = CrashReportsManager.COPY_MOBILE_NAME if crash_reports else None
    try:
        async with AfcService(lockdown=lockdown, service_name=service) as afc:
            return await _ls(afc, path)
    finally:
        await lockdown.close()


async def container_ls(bundle_id: str, path: str, documents: bool) -> dict:
    from pymobiledevice3.exceptions import AppNotInstalledError, PyMobileDevice3Exception
    from pymobiledevice3.services.house_arrest import DOCUMENTS_ROOT, HouseArrestService

    lockdown = await _lockdown()
    try:
        if not documents:
            try:
                async with await HouseArrestService.create(lockdown=lockdown, bundle_id=bundle_id) as afc:
                    return {"documents": False, "entries": await _ls(afc, path)}
            except AppNotInstalledError:
                raise
            except PyMobileDevice3Exception:
                documents = True  # not development-signed: only its Documents folder may be vended
                if not path.startswith(DOCUMENTS_ROOT):
                    path = DOCUMENTS_ROOT
        try:
            async with await HouseArrestService.create(lockdown=lockdown, bundle_id=bundle_id,
                                                       documents_only=True) as afc:
                return {"documents": True, "entries": await _ls(afc, path)}
        except AppNotInstalledError:
            raise
        except PyMobileDevice3Exception as e:
            # Not PyMobileDevice3Exception: its message would end with "Please report it at…".
            raise Refused(
                f"{bundle_id} doesn't share its files: its container opens only for development-signed apps, "
                f"its Documents folder only for apps with file sharing enabled") from e
    finally:
        await lockdown.close()


# Lockdown values shown in the Info tab (the full set also carries keys and certificates).
INFO_KEYS = ["DeviceName", "ProductType", "ProductVersion", "BuildVersion", "SerialNumber", "UniqueDeviceID",
             "ModelNumber", "RegionInfo", "HardwareModel", "CPUArchitecture", "WiFiAddress", "BluetoothAddress"]
DISK_KEYS = ["TotalDiskCapacity", "TotalDataCapacity", "TotalDataAvailable", "AmountDataAvailable"]
BATTERY_KEYS = ["CurrentCapacity", "IsCharging", "ExternalConnected", "FullyCharged", "CycleCount", "DesignCapacity",
                "NominalChargeCapacity", "AppleRawMaxCapacity", "Temperature", "Voltage"]


def _plain(value):
    """Only JSON scalars: lockdown can return bytes or dates."""
    return value if isinstance(value, (str, int, float, bool)) or value is None else str(value)


async def device_info() -> dict:
    from pymobiledevice3.services.diagnostics import DiagnosticsService

    lockdown = await _lockdown()
    out = {"device": {}, "disk": {}, "battery": {}, "errors": []}
    try:
        values = await lockdown.get_value()  # after pairing: all_values may predate the session
        out["device"] = {k: _plain(values.get(k)) for k in INFO_KEYS if values.get(k) is not None}
        try:
            disk = await lockdown.get_value("com.apple.disk_usage") or {}
            out["disk"] = {k: disk[k] for k in DISK_KEYS if isinstance(disk.get(k), int)}
        except Exception as e:  # noqa: BLE001 - show what is available
            out["errors"].append(f"storage: {type(e).__name__}: {e}")
        try:
            async with DiagnosticsService(lockdown=lockdown) as diagnostics:
                battery = await diagnostics.get_battery() or {}
            # Recent iOS keeps the capacities (design, nominal) one level down, in BatteryData.
            battery = {**(battery.get("BatteryData") or {}), **battery}
            out["battery"] = {k: _plain(battery[k]) for k in BATTERY_KEYS if k in battery}
        except Exception as e:  # noqa: BLE001
            out["errors"].append(f"battery: {type(e).__name__}: {e}")
        return out
    finally:
        await lockdown.close()


async def crash_rm(path: str) -> list[str]:
    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.crash_reports import CrashReportsManager

    if path.strip("/") == "":
        raise ValueError("refusing to delete the whole crash reports directory")
    lockdown = await _lockdown()
    try:
        async with AfcService(lockdown=lockdown, service_name=CrashReportsManager.COPY_MOBILE_NAME) as afc:
            await afc.rm(path, force=True)
            return [path]
    finally:
        await lockdown.close()


async def user_apps() -> list[dict]:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    lockdown = await _lockdown()
    try:
        async with InstallationProxyService(lockdown=lockdown) as proxy:
            apps = await proxy.get_apps(application_type="User")
        result = [{
            "bundle_id": bundle_id,
            "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or bundle_id,
            "version": info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "",
        } for bundle_id, info in apps.items()]
        return sorted(result, key=lambda a: a["name"].lower())
    finally:
        await lockdown.close()


async def save_icons(out_dir: str, bundle_ids: list[str]) -> list[str]:
    from pymobiledevice3.services.springboard import SpringBoardServicesService

    os.makedirs(out_dir, exist_ok=True)
    todo = [b for b in bundle_ids if not os.path.exists(os.path.join(out_dir, f"{b}.png"))]
    if not todo:
        return []
    saved = []
    lockdown = await _lockdown()
    try:
        async with SpringBoardServicesService(lockdown=lockdown) as springboard:
            for bundle_id in todo:
                try:
                    png = await springboard.get_icon_pngdata(bundle_id)
                except Exception:  # noqa: BLE001 - one missing icon must not stop the others
                    continue
                if png:
                    tmp = os.path.join(out_dir, f".{bundle_id}.png.tmp")
                    with open(tmp, "wb") as f:
                        f.write(png)
                    os.replace(tmp, os.path.join(out_dir, f"{bundle_id}.png"))
                    saved.append(bundle_id)
    finally:
        await lockdown.close()
    return saved


def main() -> int:
    args = sys.argv[1:]
    if args == ["list"]:
        out = asyncio.run(list_devices())
    elif len(args) == 2 and args[0] == "afc-ls":
        out = asyncio.run(afc_ls(args[1]))
    elif len(args) in (3, 4) and args[0] == "container-ls" and args[3:] in ([], ["--documents"]):
        out = asyncio.run(container_ls(args[1], args[2], documents=len(args) == 4))
    elif args == ["info"]:
        out = asyncio.run(device_info())
    elif len(args) == 2 and args[0] == "crash-ls":
        out = asyncio.run(afc_ls(args[1], crash_reports=True))
    elif len(args) == 2 and args[0] == "crash-rm":
        out = asyncio.run(crash_rm(args[1]))
    elif args == ["apps"]:
        out = asyncio.run(user_apps())
    elif len(args) >= 2 and args[0] == "icons":
        out = asyncio.run(save_icons(args[1], args[2:]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


def run() -> int:
    try:
        return main()
    except Refused as e:
        # Only the first line of the cause: pymobiledevice3 appends "Please report it at…" to unknown errors.
        cause = (str(e.__cause__).strip().splitlines() or [type(e.__cause__).__name__])[0] if e.__cause__ else ""
        print(f"{e} ({cause})" if cause else str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(run())
