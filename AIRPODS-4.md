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

## Findings so far (tested on AirPods 4, product ID 0x2019, firmware 9A348)

- The connection, setup and UARP check-ins all work.
- AirPods 4 acknowledge requests for sensor services 11 and 12 (raw accelerometer and gyroscope, which AirPods Pro stream) and 14 (LibrePods' original head tracking), but never send a reading. Two other projects document the same behavior.
- AirPods 4 stream head tracking on service **16** (LibrePods' "alternate" start). Each report is 58 bytes, starts with `01`, and holds the earbud's fused orientation as a Q15 quaternion vector at bytes 20–25 (w is implied).
- AirPods only stream while they consider themselves in use. Kinapod streams from a bare AirPod off-ear with Automatic Ear Detection off and the microphone fixed to one bud. Whether that also works with the buds docked in the case is the open question this build tests.

Sources: LibrePods (`AACPManager.kt`, docs), pods-head-tracker (`opentrack_bridge.py`), airpods-head-track (`aacp.rs`, `head_tracking.rs`), kinapod.com/technology.
