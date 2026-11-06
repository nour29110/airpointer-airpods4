# AirPods 4 support

This branch lets AirPointer turn an **AirPods 4** case into a pointer, the same way it does with AirPods Pro. You don't need to change any AirPods settings. See `git diff main` for every line that changed.

## How it works

AirPointer points by reading the motion sensors of the earbuds sitting in the case. AirPods Pro stream raw accelerometer and gyroscope data (sensor services 11 and 12) at 200 Hz. AirPods 4 acknowledge those requests but never send any data.

AirPods 4 do stream **head tracking** (sensor service 16). Each 58-byte report carries:

| Bytes | Contents |
| --- | --- |
| 0 | `01` |
| 1–8 | Time, nanoseconds (64-bit, little-endian) |
| 20–25 | The earbud's fused orientation: a quaternion's vector part in Q15. w is implied and kept ≥ 0, so all three values flip sign together when w would go negative. |
| 44–49 | The accelerometer, in the same body frame, 1024 per g |

For AirPods 4, the helper asks for service 16 and **translates each report into the raw rows AirPointer already uses**:

- The accelerometer becomes an accelerometer row (service 11, g × 10⁵).
- The change in orientation since the previous report, divided by the time between them, becomes a gyroscope row (service 12, degrees per second × 10⁵, in the body frame).

AirPointer's own fusion integrates those rows back into the earbud's orientation, so everything else (setup, the closed-lid check, calibration, pointing and tap clicks) runs unchanged. AirPods Pro never take this path: the app passes `--head-tracking` to the helper only for AirPods 4 (product IDs `0x2019` and `0x201B`).

AirPods 4 ignore a start they can't act on, so until reports arrive the helper asks again: first for 100 readings a second, then 50, then 25, then every 4 seconds.

## Clicking

Tap the front of the case, as with AirPods Pro. AirPods 4 send 25 to 100 readings a second rather than 200, so a short tap can fall between readings. **The right ⌥ key also clicks** wherever the case points, while pointing is on. It types nothing, so it can't land in a game or a text field.

## Checks

- `build.sh` runs the helper's offline self-test, which decodes two real AirPods 4 packets: 1 g at rest, almost no turning, correct timestamps, and no translation for AirPods Pro.
- A simulation fed an AirPods 4 stream through this translation into AirPointer's own `Orientation.js` and `Grip`. Over 20 seconds of turning, including four sign flips, it tracked the true orientation within 0.5° at 25, 50 and 100 Hz, and the pointer landed within 0.02% of the screen of the true position.

## Notes

- Tested on AirPods 4 with product ID `0x2019` and firmware 9A348 up to the motion request. The service 16 format comes from the airpods-head-track and pods-head-tracker projects, which recorded it on AirPods 4, and from LibrePods.
- The original README's warnings still apply: each session uses up the case's stored diagnostic records, some connection settings stay as the session set them, and the Bluetooth link drops for a moment when connecting.
- `HOLD` lines in a session's `native.log` show `ht=`, the number of head-tracking reports received.
