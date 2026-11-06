# AirPods 4 support (experimental)

This branch lets AirPointer try an AirPods 4 case. Nothing about how it talks to the AirPods changed; it only stops refusing them. See `git diff main` for every line that changed.

## What changed

1. **The app offers AirPods 4.** Their Bluetooth product IDs were added next to the AirPods Pro ones: `0x201B` (AirPods 4 with ANC) and `0x2019` (believed to be AirPods 4 without ANC).
2. **The helper accepts AirPods 4 earbuds.** It used to require the earbud firmware to call itself "AirPods Pro". It now also accepts "AirPods 4" or plain "AirPods". AirPods Max and anything naming a case are still refused.
3. **The helper accepts an AirPods 4 case.** It used to require "Charging Case" in the case's firmware name; now "Case" is enough.
4. **Refusals say what the AirPods answered.** If a model check still fails, the session log's `EXIT` line now includes the exact name the earbud or case reported.

## Check your product ID first

```
system_profiler SPBluetoothDataType | grep -i -A10 airpods | grep -i "product id"
```

If it shows something other than `0x2019` or `0x201B`, add it to `models` in `Sources/AirPointer/Session/ClosedCaseAirPods.swift` (lowercase, like `"0x201b"`).

## Build and test

```
zsh ./build.sh
open AirPointer.app
```

Then follow the normal setup in the README. If a connection fails, the app shows a message, and the newest folder in `~/Library/Application Support/AirPointer/PointerSessions/` has a `native.log`. Its `STEP` lines and final `EXIT` line show exactly how far it got.

## What to expect

AirPointer works by keeping the earbuds' motion sensors streaming while they sit in the closed case. That relies on how the case firmware behaves, which was worked out on AirPods Pro 3. An AirPods 4 case runs different firmware, so this may stop at one of these points:

| Exit code | Meaning on AirPods 4 |
| --- | --- |
| 27 or 28 | The AirPods 4 don't open the motion channel the same way. |
| 30 or 43 | The channel opened, but no motion came, or it stopped. |
| 32 or 34 | A model name we didn't expect; the log line shows the name. |
| 36 | The case refused the request that keeps it awake. |

The original README's warnings still apply: each session uses up the case's stored diagnostic records, some AirPods connection settings stay as the session set them, and the Bluetooth link drops for a moment when connecting. The helper's own notes say it sends no firmware, configuration or security writes to the AirPods.
