# Axion Super Power Saving Mode

realme UI 2/3-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on **Realme Narzo 50A (RMX3430)**. KernelSU / **ResukiSU** / Magisk module.

Current module: **v2.1**.

## Why this is a clone, not a port

The real RUI Super Power Saving Mode is glued into ColorOS framework, the stock launcher, `com.oplus.battery`, and vendor HALs. Those APKs crash on Axion. This rebuilds the feature on AOSP.

| realme UI SPSM | This module (v2.1) |
|---|---|
| Black 6-app home, door to exit | Same UX (`dev.axion.spsm`) |
| Phone / Messages / Browser + 3 | Auto-filled, tap to change |
| CPU / brightness cuts | Helio G85: **A75 cpu6–7 offline**, A55 stay online (RIL), GPU 300 MHz |
| Background apps gone | 6-app home + Google freeze only (not a 2-minute `pm suspend` of everything) |
| Panel fully asleep | DT2W off **while SPSM is on**; restored from snapshot on exit |
| Calls still work | Mobile data stays (Jio VoLTE). **No** `force-idle` / deep doze |
| Restore on exit | Snapshot of every node **before** any write; exit restores sysfs first |

## Install (ResukiSU)

1. Download `Axion-SPSM-v2.1-RMX3430.zip` from [Releases](https://github.com/Rocker14427c/AXION-BS/releases).
2. **ResukiSU → Modules → Install from storage** → zip → **Reboot**.
3. Open **Super Power Saving** → grant root → **Allow**.
4. Pick 6 apps → **Turn on** (a few seconds, not minutes).

Optional: add the **Super Power Save** tile in Quick Settings.

## v2.1 vs older builds

- **Does not** kill `logd` / `persist.log.tag` (Logfox keeps working)
- **Does not** enable AOSP Battery Saver / Data Saver
- **Does not** deep-doze (that broke power-button wake on this G85)
- Snapshot/restore under `/data/adb/spsm/snap/`
- Even 3×2 icon grid
- Wi-Fi off for the whole SPSM session; mobile data stays

## If you get stuck

- Door icon (top left) → Exit
- ResukiSU → Modules → **remove** this module → reboot
- Root shell: `sh /data/adb/spsm/exit.sh`
- Log: `/data/adb/spsm/spsm.log`

Emergency undo scripts are in `tools/` (`RESTORE-PHONE.sh`, `FIX-LOGD.sh`, `FIX-DT2W.sh`). Run as **root** (`uid=0`), not as MT Manager.

## Build

Android SDK build-tools 34 + platform 34. `resources.arsc` **must** be ZIP_STORED (Android 16 rejects Deflate). See `build.sh`. Do not commit `*.jks`.
