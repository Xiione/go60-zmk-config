# Go60 Cirque experiment log

## November 2026 baseline

The daily profile uses the resolution descriptor from [ZMK PR 3483](https://github.com/zmkfirmware/zmk/pull/3483), declares 100 counts per unit and applies a 1/2 live scaler to default left-hand scrolling. The historical tuning profile attaches the inertia processor before a 1/3 live scaler and uses 1/3 for generated coast reports. Experiments below used that tuning profile unless otherwise specified.

| Candidate | Change from historical tuning baseline | Operator observation |
|---|---|---|
| Stock → resolution only | Added the HID descriptor patch, with inertia bypassed | Tiny movements registered better. Interpolated wheel steps became much less visible in apps that smooth them. USB and Bluetooth felt similar during ordinary use. |
| Inertia baseline | Start 8, move 24, four events, stop 1, friction 15 | The stop and friction changes aimed to reduce the sensation of hitting a wall. The resulting coast still lasted too long, like a “lubricated ball bearing.” Catch needing a nudge had also occurred with stock firmware and LinearMouse smoothing. |
| `decayfast980` | `decay-fast=980` | Hard to distinguish by feel. A very fast flick sometimes moved little under the finger, coasted no farther than a medium swipe, or failed to launch. |
| `split15` | `fast=15 decay-fast=990 decay-slow=980` | Fast flicks seemed to travel a little farther. Use was limited to the capture app, so target-stopping performance is unknown. |
| `split15-tail960` | Split15 plus `slow=4 decay-tail=960` | Extra braking was perceptible but insufficient. The larger complaint was slow response to medium and fast swipes, including during contact. The operator chose resolution-only scrolling with a higher live scale for daily use. |
| Raw pad probes | Recorded each half directly in absolute and relative modes | Both pads reported contact while stationary and showed two down/up pairs in absolute catch trials. The right hold and sweep ended while the finger was still down. |

### Measurements and conditions

The archived Bluetooth report includes 742 usable trials and 38 exclusions across both devices. Of those exclusions, 23 had incomplete firmware traces, 11 were discarded and four had a transport mismatch. The four rankings span 9, 6, 6 and 4 qualifying bins respectively. Compare common bins and inspect individual curves before interpreting a score.

All scroll trials used the same MacBook and scrolling settings in one day. Go60 diagnostics used USB serial while host input normally used Bluetooth. USB/Bluetooth similarity was an informal impression. Firmware times and host timestamps are separate clocks.

- The operator attributed candidate identity using rebuild timing (roughly 15–29 seconds after changing parameters versus one second for a repeated build). Historical traces have no installed-image fingerprint. One `decayfast 980` label came from a shortcut entering a space in the name box and had zero firmware records.
- A change in slow-swipe technique coincided with more coasts in one direction. Some wrong-direction trials were retained and more correct trials added. Preserve the original rows. Replay and direction validation are follow-ups.
- LinearMouse PID 930 was observed during planning with a process start predating the trials. A later process and executable-path check during preservation found it had exited. The saved September 12 config gives the Go60 rule scroll speed 2.25, acceleration 0.1 and vertical smoothing disabled. A separate Go60 Left rule sets vertical acceleration 0.13. The MacBook trackpad rule sets speed 0, vertical acceleration 1, automatic vertical distance and vertical smoothing disabled. Device matching and event modification were not recorded per trial. Compare host curves under those conditions. Raw sensor packets are independent of the Mac utility.
- The checked-in [left catch](../tools/pad-probe/fixtures/lh-catch.jsonl) and [right hold](../tools/pad-probe/fixtures/rh-hold.jsonl) are original single-trial records. End-of-file on the right hold marks the recorder stopping while contact was active.

### Archive and provenance

The private snapshot lives beside the config checkout at `../go60-cirque-initialtests/2026-11-22/`. Run `shasum -a 256 -c SHA256SUMS` from the snapshot directory. It contains original sessions and reports, available build logs, source snapshots, worktree diffs, submodule revisions and UF2s.

| Item | SHA-256 |
|---|---|
| Scroll session | `0b7f7718f59a5d8a6e74f7522a3e3f5bffb656cc616e108d8d039fca98c0a08d` |
| Pad session | `b5ad5af42938d6d6d2d0655c16566e69680f4ea53c4a622d76487840a6dbb572` |
| Combined image present when archived | `e591fa754aa53a1b9e7eab43cfff614bb2ec8c6ebca6fb6e1d941308119c11b6` |
| Intended daily image observed earlier, before preservation | `890f69a85e4e89bbcb085dadc013deb79850386d1d4a4cc6e210219c9ba00919` |

Only the first combined binary listed above was available by that filename at archive time. New builds write their own manifest. A hardware-confirmed rollback pair remains pending operator flash and daily-use confirmation.

## Roadmap

1. Replay the same timestamped packets against production gesture code with virtual time. Include catch, direction reversal, incomplete lifts and delayed input. Compare onset and live travel independently of coast.
2. Prototype left-only contact-aware scrolling and USB-onset instrumentation. Keep MacBook reference data and held-out sessions for evaluation.
3. Revisit hue drift on the GOL0–GOL9 gold ramp. The [separate firmware experiment](https://github.com/Xiione/go60-zmk-firmware/tree/xiione/gol-brightness-experiment) tried brightness remapping. Hue drift persisted and brightness +/- steps felt slower. Test against the original ramp before considering a different renderer change.
