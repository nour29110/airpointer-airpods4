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

AirPointer's own fusion integrates those rows back into the earbud's orientation, so its setup, calibration and pointing run unchanged. AirPods Pro never take this path: the app passes `--head-tracking` to the helper only for AirPods 4 (product IDs `0x2019` and `0x201B`).

AirPods 4 ignore a start they can't act on, so until reports arrive the helper asks again: first for 100 readings a second, then 50, then 25, then every 4 seconds.

## Keep the lid open

Closing the lid makes AirPods 4 end their connection. AirPointer keeps a closed AirPods Pro case awake by holding a transfer of the case's diagnostic records open, and the AirPods 4 case rejects that (its model check fails). With the lid open, AirPods 4 stay connected on their own, so for AirPods 4:

- Pointing starts as soon as the motion and the earbuds are verified. There's no "close the lid" step.
- The helper sends nothing to the case: no discovery, no model check, no diagnostic-record transfer. Your case's records are never used up.

## Clicking: twist the case

Twist the case quickly about the axis it points along, like turning a key, about 20° or more. That turn doesn't move the pointer, because calibration maps only turns toward the right and top dots. The click lands where the pointer was just before the twist, and the pointer holds still until the case settles.

Taps don't work on AirPods 4. Their readings are smoothed, and 25 to 100 a second rather than 200, so a tap's short jolt falls between them. Double-tapping the front of an AirPods 4 case with the lid open also starts pairing mode. Skip the tap step in setup ("Skip for Now").

**The right ⌥ key also clicks** wherever the case points, while pointing is on. It types nothing, so it can't land in a game or a text field.

## Checks

- `build.sh` runs the helper's offline self-test, which decodes two real AirPods 4 packets: 1 g at rest, almost no turning, correct timestamps, and no translation for AirPods Pro.
- A simulation fed an AirPods 4 stream through this translation into AirPointer's own `Orientation.js` and `Grip`. Over 20 seconds of turning, including four sign flips, it tracked the true orientation within 0.5° at 25, 50 and 100 Hz, and the pointer landed within 0.02% of the screen of the true position.
- The twist click, on the same simulated stream at 25, 50 and 100 Hz: every quick twist of 20° or more clicked, slow twists didn't, and 40 seconds of aiming at up to 350°/s, with up to 60% accidental twist, never clicked.
- On a real pair: AirPods 4 stream with the lid open, and pointing and calibration worked.

## Notes

- Tested on AirPods 4 with product ID `0x2019` and firmware 9A348. The service 16 format comes from the airpods-head-track and pods-head-tracker projects, which recorded it on AirPods 4, and from LibrePods.
- From the original README's warnings, these still apply to AirPods 4: some connection settings stay as the session set them, and the Bluetooth link drops for a moment when connecting. The case's diagnostic records are not touched.
- `HOLD` lines in a session's `native.log` show `ht=`, the number of head-tracking reports received.
