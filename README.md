# Axion Super Power Saving Mode

realme UI 2/3-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on **Realme Narzo 50A (RMX3430)**. Also works on other AOSP/Lineage-based ROMs with SukiSU / KernelSU / Magisk.

## Why this is a clone, not a port

The real RUI2/RUI3 Super Power Saving Mode is **not an APK you can flash**. It is glued into:

- ColorOS / realme **framework jars** (`oplus-framework`, `oplus-services`)
- The **stock realme launcher** (the black 6-app home *is* a launcher mode)
- `com.oplus.battery` and PowerManager hooks
- Signature-level `oplus.*` permissions
- MediaTek/Oplus power HAL policies

RUI2 = Android 11, RUI3 = Android 12, Axion 2.7 = **Android 16**. Those APKs crash with `ClassNotFoundException` for `oplus.*` on AOSP, and putting ColorOS framework on Axion bootloops. Vendor leftovers you still see (`system_server` on vendor, mtk apps) are **not** ColorOS SPSM.

This module **rebuilds the feature** on Axion:

| realme UI SPSM | This module |
|---|---|
| Black 6-app home, door to exit | Same UX (`dev.axion.spsm`) |
| Phone / Messages / Browser + 3 | Auto-filled, long-press to change |
| CPU / brightness cuts | Helio G85: **offline A75 big cores (cpu6-7)**, little cluster capped ~1.15 GHz, GPU locked to lowest OPP, GED/FPSGO boosts off |
| Background apps gone | `pm suspend` + force-stop everything not in the 6 |
| Battery saver | AOSP battery saver + `force_all_apps_standby` + data saver + doze when screen off |

## Install (SukiSU)

1. Copy `Axion-SPSM-v1.0.zip` to the phone.
2. **SukiSU → Modules → Install from storage** → pick the zip → **Reboot**.
3. Open **Super Power Saving**.
4. SukiSU Superuser prompt → **Allow** (and disable umount for this app if you use “Unmount modules by default”).
5. Pick the 6 apps → **Turn on**.

Optional: add the **Super Power Save** tile in Quick Settings.

SukiSU Action button on the module also toggles the mode.

## If you get stuck

The black home is the launcher while the mode is on. Exit with the **door icon** (top left).

If that fails:

- SukiSU → Modules → **disable** Axion Super Power Saving → reboot  
- or from any root shell: `touch /data/adb/spsm/disable` then reboot  
- Log: `/data/adb/spsm/spsm.log`

## What it does (aggressive)

- Forces AOSP Battery Saver + night mode + animation scale 0
- Brightness ~8%, 15s screen timeout, haptics off, location off
- Bluetooth + NFC off (radio stays up for **calls & SMS**)
- Restrict background data, disable Wi‑Fi/BLE scanning
- Offline Helio G85 big cores, cap remaining CPUs, lock GPU min
- Freeze (suspend) all non-essential apps
- Watchdog every 20s so PowerHAL cannot bring big cores back
- Survives reboot until you exit

Incoming **phone calls still work**. Alarms may be delayed while the screen is off (deep doze). WhatsApp / Telegram only work if you put them in the 6 apps.

## Uninstall

Disable the mode first, then remove the module in SukiSU. `uninstall.sh` unsuspends apps and restores the Axion launcher.
