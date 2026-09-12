# Axion Super Power Saving Mode

realme UI 2/3-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on **Realme Narzo 50A (RMX3430)**. Also works on other AOSP/Lineage-based ROMs with SukiSU / KernelSU / Magisk.

Current module: **v1.7** (Android 16 install fix).

## Why this is a clone, not a port

The real RUI2/RUI3 Super Power Saving Mode is **not an APK you can flash**. It is glued into ColorOS framework jars, the stock launcher, `com.oplus.battery`, and vendor power HALs. Those APKs crash on Axion.

This module **rebuilds the feature** on AOSP:

| realme UI SPSM | This module |
|---|---|
| Black 6-app home, door to exit | Same UX (`dev.axion.spsm`) |
| Phone / Messages / Browser + 3 | Auto-filled, tap to change |
| CPU / brightness cuts | Helio G85: **A75 cpu6–7 offline**, A55 850 MHz on / 500 MHz off, GPU 300 MHz |
| Background apps gone | `pm suspend` + force-stop everything not in the 6 |
| Panel fully asleep | DT2W / lift-to-wake / AOD / pocket wake off |
| Calls still work | Mobile data stays (Jio VoLTE). Quick doze, **not** `force-idle` |

## Install (SukiSU)

1. Copy `Axion-SPSM-v1.6-RMX3430.zip` to the phone.
2. **SukiSU → Modules → Install from storage** → pick the zip → **Reboot**.
3. Open **Super Power Saving**.
4. SukiSU Superuser prompt → **Allow** (and disable umount for this app if you use “Unmount modules by default”).
5. Pick the 6 apps → **Turn on**.

Optional: add the **Super Power Save** tile in Quick Settings.

SukiSU Action button on the module also toggles the mode.

## If you get stuck

The black home is the launcher while the mode is on. Exit with the **door icon** (top left).

- SukiSU → Modules → **disable** Axion Super Power Saving → reboot
- or from any root shell: `touch /data/adb/spsm/disable` then reboot
- Log: `/data/adb/spsm/spsm.log`

## What it does (standalone — no other module required)

- AOSP Battery Saver (Android 16 keys + legacy names) + night mode + animation scale 0
- Brightness ~8%, 15s timeout, haptics off, location off, auto-rotate off, hotword off
- Bluetooth + NFC off (restored on exit). Radio stays up for **calls & SMS**
- Wi‑Fi off while the screen is off (restored on wake if it was on)
- Play services / Play Store / Search **disable-user + frozen**
- logd + kernel printk silenced; caches trimmed
- Offline Helio G85 big cores; little cluster capped; GPU locked 300 MHz
- Watchdog every 15s so PowerHAL cannot bring big cores back
- Survives reboot until you exit

Incoming **phone calls still work**. Alarms may be delayed while the screen is off (deep doze). WhatsApp / Telegram get no FCM push until you open them — same trade as realme SPSM.

## Uninstall

Disable the mode first, then remove the module in SukiSU. `uninstall.sh` unsuspends apps and restores the Axion launcher.
