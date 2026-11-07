# AirPods 4 support

This version of [AirPointer](https://github.com/musubipapi/airpointer) by Andy Gao lets it turn an **AirPods 4** case into a pointer, the same way it does with AirPods Pro. You don't need to change any AirPods settings. The first commit here is the original AirPointer's code at its commit `a73cc79`, and every change for AirPods 4 comes after it.

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

## The lid

**Open:** AirPods 4 stream from the open case and stay connected on their own. Pointing starts as soon as the motion and the earbuds are verified: there's no "close the lid" or "turn upright" step.

**Closed:** when the lid closes while you're pointing, AirPointer tries to keep the closed case awake the way it does for AirPods Pro. A closed case ends its link to the earbuds after 3.5 s of idle firmware-update traffic (UARP), so the helper asks the case for its diagnostic records (MTIC) and holds them, which keeps that traffic busy. Like AirPods Pro, this uses up the case's stored diagnostic records.

The AirPods 4 case answers this only once the lid is closed, and it reports a different model name than the AirPods Pro case (the session log shows it). The rest of the exchange was tuned on the AirPods Pro 3 case. On the tested AirPods 4 it holds, but on other firmware it may not:

- If the case cooperates and the earbuds keep streaming, pointing carries on with the lid closed, as it does on the tested pair. AirPods Pro sessions end about 30 minutes after the lid closes, and AirPods 4 likely do too.
- If not, the case is set aside rather than ending the session, and the link drops when the lid closes. AirPointer then waits for the lid to open and reconnects by itself.

The app ignores in-case reports from the first 3 seconds after connecting: AirPods 4 send a burst then that can read as a lid closing.

## Clicking

**Press the front of the case**, where its light is, like pressing a button. Hold the case still for a moment first: a press while you're still aiming doesn't click. The click lands where the pointer was just before the press, and the pointer holds still from the moment the press arrives until the case settles, so the press doesn't nudge your aim.

A press turns the case a little in your hand: a few degrees within a hundredth of a second, mostly about the axis it points along, and then it springs back. Aiming turns the case smoothly instead. In a recording of 27 presses on a closed case held in the hand, aiming never sped the case up by more than 30°/s along the press direction from one reading to the next, and a press sped it up by 40 to 300°/s. So a press has to:

- come from a still case (35°/s at most, 30 to 150 ms before),
- speed the case up by 40°/s or more along the press direction within one reading,
- peak along that direction, and
- fall back to half its peak within 35 ms.

The press direction is in the streaming earbud's frame, and it adjusts to your presses. If the other earbud streams, its frame is different: three firm presses that agree teach it the new direction, and the third one clicks.

Presses need about 100 readings a second, which AirPods 4 send when they can. At 50 a second the softest presses are missed, and at 25 presses don't click at all.

**Twisting still clicks:** twist the case quickly about the axis it points along, like turning a key, about 20° or more. That turn doesn't move the pointer, because calibration maps only turns toward the right and top dots. A firm press is a small, quick twist too, so whichever one notices it first clicks, and one press always clicks once.

**The right ⌥ key also clicks** wherever the case points, while pointing is on. It types nothing, so it can't land in a game or a text field.

AirPods Pro taps don't work on AirPods 4. Their readings are smoothed, and 25 to 100 a second rather than 200, so a tap's short jolt falls between them. Skip the tap step in setup ("Skip for Now"). With the lid open, double-tapping the front of an AirPods 4 case also starts pairing mode, so press with the lid closed.

## Checks

- `build.sh` runs the helper's offline self-test, which decodes two real AirPods 4 packets: 1 g at rest, almost no turning, correct timestamps, and no translation for AirPods Pro. An earbud's first reports, sent before its own fusion starts, have a zero orientation. They read as no turn, so the first real orientation doesn't read as a spin of thousands of degrees a second.
- The app's self-test checks press clicks on synthetic AirPods 4 motion. A press from a still case clicks once, at 50 and 100 readings a second, however the readings are batched, and holds the pointer from its start. Aiming, a press while aiming, jolts from other directions, slow turns and presses right after a gap don't click. Three presses in a new direction teach it, and a press that is also a twist clicks once.
- Press clicks on the recording (125 s at 99 readings a second): all 27 presses in the press stretches clicked, plus 2 in a mixed stretch, and about 70 s of aiming and handling never clicked. Aiming and handling still never clicked with the stillness limit anywhere from 25 to 40°/s and the jump anywhere from 40 to 60°/s (at 50°/s, 25 of the 27 presses clicked). With 5% of readings lost at random, 98% of presses clicked and nothing else did. The Swift detector and a Python model of it gave the same clicks at the same times.
- A simulation fed an AirPods 4 stream through this translation into AirPointer's own `Orientation.js` and `Grip`. Over 20 seconds of turning, including four sign flips, it tracked the true orientation within 0.5° at 25, 50 and 100 Hz, and the pointer landed within 0.02% of the screen of the true position.
- The twist click, on the same simulated stream at 25, 50 and 100 Hz: every quick twist of 20° or more clicked, slow twists didn't, and 40 seconds of aiming at up to 350°/s, with up to 60% accidental twist, never clicked.
- On a real pair: AirPods 4 stream with the lid open and closed, and pointing, calibration and twist clicks worked. The press recording came from that pair, through `defaults write local.airpointer recordMotion -bool true`, which saves each session's motion as `motion-rows.csv` in its session folder (`defaults delete local.airpointer recordMotion` stops it).

## Notes

- Tested on AirPods 4 with product ID `0x2019` and firmware 9A348. The service 16 format comes from the airpods-head-track and pods-head-tracker projects, which recorded it on AirPods 4, and from LibrePods.
- From the original README's warnings, these still apply to AirPods 4: some connection settings stay as the session set them, the Bluetooth link drops for a moment when connecting, and closing the lid uses up the case's diagnostic records.
- `build.sh` resets AirPointer's Accessibility permission after every build, because each build is signed afresh and macOS's old grant no longer applies. Setup's Allow step asks again.
- `HOLD` lines in a session's `native.log` show `ht=`, the number of head-tracking reports received.
