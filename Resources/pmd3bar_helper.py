"""PMD3Bar helper: device listing that tolerates per-device failures.

`pymobiledevice3 usbmux list` aborts the whole listing when a single entry fails to answer lockdown
(common for Wi-Fi entries: usbmuxd keeps advertising an iPhone that just went to sleep or left the
network). This helper queries each usbmux entry on its own, with a timeout, and reports failures per
entry instead.

Commands (device chosen with PYMOBILEDEVICE3_UDID, USB preferred over Wi-Fi):
  list          JSON list of {udid, connection, name, version, product_type, error}
  afc-ls PATH   JSON list of {name, dir, size, mtime} under /var/mobile/Media/PATH
  apps          JSON list of {bundle_id, name, version} of user apps (only these fields: the full
                install metadata can carry app secrets and is never printed)
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


async def afc_ls(path: str) -> list[dict]:
    from pymobiledevice3.services.afc import AfcService

    lockdown = await _lockdown()
    try:
        async with AfcService(lockdown=lockdown) as afc:
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
    elif args == ["apps"]:
        out = asyncio.run(user_apps())
    elif len(args) >= 2 and args[0] == "icons":
        out = asyncio.run(save_icons(args[1], args[2:]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
