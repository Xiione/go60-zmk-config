# Go60 pad probe

Use this to find out whether a finger landing on either Go60 pad produces a usable contact signal before a deliberate slide. Each half reads its own Cirque over SPI and returns raw packets through its own USB-C data connection. Each probe uses the shared Enthium keymap. The pad on the flashed half produces diagnostic packets in place of pointer, click, or scroll events.

## Flash and run

Run from the checkout root. Put the half being tested in bootloader mode. Copy its image to the matching volume. After flashing, leave the USB data cable plugged directly into the same half. Run one half at a time.

```sh
/bin/cp -X ./go60-lh-pad-probe.uf2 /Volumes/GO60LHBOOT/
python3 tools/pad-probe/tester.py lh
```

Move the cable to the right half, enter its bootloader, then run:

```sh
/bin/cp -X ./go60-rh-pad-probe.uf2 /Volumes/GO60RHBOOT/
python3 tools/pad-probe/tester.py rh
```

The tester auto-selects a single macOS USB modem port and checks the hand reported by the firmware. If several ports are present, pass the correct one with `--port /dev/cu.usbmodem…`. Close any scroll recorder using that port. Use the MacBook keyboard to start trials.

The default run performs **hold**, **catch**, and **sweep/pressure** in absolute mode, then repeats in relative mode. Press Return with fingers off and follow the timed cues. For the shortest comparison use `python3 tools/pad-probe/tester.py lh --trial hold` (or `rh`). Repeat either hand as often as desired. The tester appends one JSON object per framed trial to `/private/tmp/go60-pad-probe.jsonl`. Use `--out PATH` for a different destination.

## Read a trial

- **Hold** — Land near the center, hold still, then lift vertically. An absolute down followed by an up, accompanied by positive Z during the hold and zero on lift, supports a contact-based catch. Check the X/Y span to see how much the coordinates wandered. Repeat a few times. Sensor noise and finger deformation can change X/Y during a stationary touch.
- **Catch** — Flick and lift, then land and hold. Look for two distinct down/up pairs in the raw absolute trace. This measures whether the second landing is observable. This probe generates no coast.
- **Sweep/pressure** — Trace a wide circle to exercise both coordinates. Then vary pressure gently in one spot. The Z range shows whether touch strength varies on your pad. Z is an uncalibrated sensor reading.
- **Relative controls** — Compare motion, zero-motion packets, and button flags during the same gestures. A zero-delta packet is observable input. Its meaning as a finger-down signal depends on its timing and repeatability. A long hold helps distinguish a landing from a tap recognized on lift.
- A valid capture can contain zero packets. If the hold is silent, check whether the sweep produces packets before drawing conclusions. The tester marks firmware buffer overflow and SPI errors as incomplete and rejects truncated USB frames. The packet timestamps reflect successful driver reads. They cannot measure finger-to-sensor latency or detect every lost hardware interrupt. Cue timestamps use the host clock and include reaction-time uncertainty.

The JSON contains the ASIC ID and firmware version, the two feed registers read back from the sensor, sample-rate and Z-idle register values, gesture cues, firmware-relative microseconds, raw packet bytes, and decoded fields. Relative mode restores the board driver's original feed settings. Absolute mode selects Cirque's single-contact packet format and records X, Y, six-bit Z and button flags. The contact sequence uses Cirque's nonzero-X convention and reports disagreement with nonzero Z. The format contains one coordinate pair per packet. It cannot establish independent multifinger tracking. [Cirque SPI example](https://github.com/cirque-corp/Cirque_Pinnacle_1CA027/blob/master/Circular_Trackpad/Single_Pad_Sample_Code/SPI_FlatOverlay/SPI_FlatOverlay.ino)

## Rebuild and restore

`tools/pad-probe/build.sh` builds both side-specific UF2s using Docker and pinned MoErgo PR36. The diagnostic driver is applied to a build-only copy. To restore normal pad behavior, re-enter the bootloader on each flashed half and flash its previous image. In this checkout, use `go60-lh-scroll-trace.uf2` to resume left-hand scroll tuning and the regular combined `go60.uf2` on the right. Flash the combined image to the right with only that bootloader mounted if you want to keep your tuned left image.
