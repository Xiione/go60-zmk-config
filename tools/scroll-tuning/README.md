# Go60 scroll tuning

The reference is the built-in MacBook trackpad. The first target is the left Cirque
over Bluetooth. Keep the current 100-count HID resolution fixed during the tuning
sweeps and leave mouse-scroll utilities off while recording.

## Build and flash a candidate

Start Docker Desktop and initialize this repo's submodules. Use the following
commands to build the baseline and individual candidates.

```sh
tools/scroll-tuning/build-left.sh
tools/scroll-tuning/build-left.sh --set stop=2
tools/scroll-tuning/build-left.sh --set friction=35
tools/scroll-tuning/build-left.sh --set decay-fast=995
```

The script keeps a dedicated Docker container with the pinned PR36 source,
Nix toolchain, CMake/Ninja build trees, and a bounded compiler cache. It rebuilds
only the left half and writes `go60-lh-scroll-trace.uf2`. Candidate overrides
affect the copied build input. Each candidate starts from the versioned tuning
keymap in this directory. Pass all settings you want to combine in the same invocation.
Changing `scale` or `scale-div` updates the live and coast scales together.

Use `--release` for a left-half build without diagnostics
(`go60-lh-scroll-tuned.uf2`). With `--stop-container`, the build state survives
until the next invocation. `--reset-container` removes this worktree's dedicated
container and its cached build state. The regular firmware build still produces
`go60.uf2` for both halves.

Set `ZMK_BUILD_JOBS=8` to use eight compiler workers. The default is four.

Put only the left half in bootloader mode before running the flash command.

```sh
./flash-go60.sh ./go60-lh-scroll-trace.uf2
```

Keep a data-capable USB cable attached to read the serial trace. Select the
Go60's Bluetooth host profile and prefer Bluetooth output. Check that the
Mac receives scrolling over Bluetooth while the cable is connected. Use USB
output for the USB validation trials. The report excludes trials if the
transport recorded by the firmware differs from the selected connection.

## Record and compare

```sh
swiftc tools/scroll-tuning/Capture.swift -o /tmp/go60-scroll-capture
ls /dev/cu.usbmodem*
/tmp/go60-scroll-capture /tmp/go60-session.jsonl --serial /dev/cu.usbmodemXXXX
python3 tools/scroll-tuning/report.py /tmp/go60-session.jsonl --out /tmp/go60-report.html
```

Use the serial path that appears on plugging in the Go60. For a release
build or a host-events-only run, omit `--serial`. Open the HTML report in a
browser. For USB trials, add `--transport USB` to the report command. The
command also writes the metrics and traces as JSON beside the HTML.

After a USB disconnect or a Go60 power cycle, press **⇧⌘R** in the recorder
to reopen the serial port. If macOS assigns a different device path, edit the
**USB serial** field before reconnecting. The recorder times out unanswered
requests and excludes the interrupted trial from the report.

1. Select a speed, direction, scenario and connection, and enter a candidate
   label such as `baseline`, `stop2`, or `friction35`.
2. Press **⌘1** to start a MacBook trial or **⌘2** to start a Cirque trial.
   Move the pointer over the matching pane and swipe. Label the direction
   consistently by how you swipe. The report normalizes viewport sign for
   ordinary swipes, so natural scrolling can move the viewport either way. Use
   similar finger travel on both devices and avoid arrow keys or touching the
   other device during the trial. For Cirque diagnostics, wait until the
   recorder confirms the Go60 is armed before swiping.
3. The red border marks the recording pane. After movement ends, press the
   same shortcut again or use **⌘Return** to finish. For a Cirque diagnostic
   trial, the blue banner acknowledges the keypress and shows trace progress.
   Wait for the green **Trial saved** banner before starting another trial.
   Pauses between swipes stay inside the same trial. Press **⇧⌘D** to discard
   a trial after a mistake.
4. Alternate devices across eight vertical swipes per speed and direction to
   establish baselines. Compare variants in the same bins, then use fresh
   vertical, horizontal, diagonal and reversal swipes to validate the winner.

The progress grid reads the session JSONL and updates when you change the
candidate label, connection, scenario, or direction, or save a trial. Use
eight ordinary vertical swipes per speed, direction, and device. For
**re-contact**, **repeat**, and **reversal**, use four medium trials per
starting vertical direction and device. Other speeds and off-axis directions
show how many trials you recorded. Discarded and incomplete trials do not
count. The grid uses the entered label for both devices. The report still
pools MacBook trials into the reference.

- **Re-contact** uses a flick followed by a gentle same-direction drag during
  the coast. Check whether the new drag takes control promptly.
- **Repeat** uses two same-direction flicks within one trial. Check whether
  the second flick adds momentum without a pause.
- **Reversal** uses a flick followed by movement in the opposite direction
  during the coast. Select the first direction and check how quickly the
  viewport turns around.

The recorder reports actual viewport movement in points. The firmware trace
is measured separately in HID counts and device-clock microseconds. The
MacBook exposes its scroll phase and momentum phase. For the Cirque, the last
nonzero input is a proxy for lift-off.

Rebuild and flash the diagnostic firmware when updating to the recorder
with firmware arming. The report excludes older firmware traces that lack
trial identifiers.

## Tune in order

- Compare slow-swipe distance and adjust `scale` and `scale-div` together with
  the live scaler. This tool maintains the match automatically.
- Compare how often each swipe starts coasting. Adjust `start`, `move`, and
  `min-events` to correct missed or accidental coasts. Use `release`,
  `gain`/`blend`, and `decel-samples`/`decel-ratio` when the trace points to a
  handoff problem.
- Change one coast parameter at a time. Compare `stop` at 1 and 2, `friction` at
  0, 15 and 35, and `decay-fast` at 985, 990 and 995. Try a separate tail only if
  a single rate can't match the early and late coast. For example, try
  `fast=20`, `slow=6` and `decay-tail=995` to activate the lower band.
- Compare gentle re-contact, repeated flicks and reversals. Change
  `handoff-ms` or `suppress-limit` only when the interruption tests show lag or
  lost motion. Keep other caps and timing settings at the baseline unless a
  trace implicates them.
- Pick the closest curves over equivalent speed and direction bins, check how
  the ending feels, and retest the winning settings with `--release` over
  Bluetooth and USB. Daily builds use their own left keymap. Promote a candidate by explicitly
  attaching the processor and matching the live and coast scales in that profile.
