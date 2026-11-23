#!/usr/bin/env python3
"""Capture Go60 Pinnacle packets over a local USB CDC port (macOS/POSIX)."""
import argparse
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import glob
import json
import os
import re
import select
import statistics
import sys
import termios
import time
import tty

# Cues are host timestamps relative to the READY reply. The packet clock starts
# just before that reply. Human reaction and USB latency limit cue alignment.
TRIALS = {
    "hold": [("off", "Keep your finger off.", 1),
             ("hold", "Touch straight down at the center. Hold still.", 2.5),
             ("lift", "Lift straight up and keep your finger off.", 1)],
    "catch": [("off", "Keep your finger off.", 1),
              ("flick", "Flick once and lift.", 1),
              ("catch", "Land again and hold still.", 2),
              ("lift", "Lift and keep your finger off.", 1)],
    "sweep": [("off", "Keep your finger off.", 1),
              ("sweep", "Slide in a wide circle to exercise both axes.", 2.5),
              ("pressure", "Hold one spot. Gently vary finger pressure.", 2),
              ("lift", "Lift and keep your finger off.", 1)],
}
MODES = {"absolute": "A", "relative": "R"}


@contextmanager
def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, termios.TIOCEXCL)
        attrs = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            termios.tcflush(fd, termios.TCIOFLUSH)
            yield fd
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
    finally:
        os.close(fd)


class Probe:
    def __init__(self, fd):
        self.fd = fd
        self.buffer = bytearray()

    def command(self, command):
        os.write(self.fd, command.encode("ascii"))

    def line(self, deadline):
        while b"\n" not in self.buffer:
            wait = deadline - time.monotonic()
            if wait <= 0 or not select.select([self.fd], [], [], wait)[0]:
                raise ValueError("USB reply timed out. Check the probe firmware and USB port.")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise ValueError("USB port disconnected.")
            self.buffer.extend(chunk)
            if len(self.buffer) > 4096 and b"\n" not in self.buffer:
                raise ValueError("Unframed USB reply.")
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        text = line.decode("ascii").strip()
        if text.startswith("ERROR"):
            raise ValueError(text)
        return text

    def identify(self, side):
        self.command("?")
        deadline = time.monotonic() + 3
        reply = self.line(deadline)
        while not reply:
            reply = self.line(deadline)
        if reply != f"PAD1 {side}":
            raise ValueError(f"Expected PAD1 {side} on this port. Received {reply!r}.")

    def record(self, side, mode, trial):
        self.command(mode)
        fields = self.line(time.monotonic() + 3).split()
        if len(fields) != 9 or fields[:3] != ["READY", side, mode]:
            raise ValueError(f"Unexpected setup reply {fields}")
        registers = dict(zip(("asic_id", "fw_version", "feed1", "feed2", "sample_rate", "z_idle"),
                             map(int, fields[3:])))
        if (registers["feed1"] & 3) != (3 if mode == "A" else 1):
            raise ValueError(f"Sensor feed readback disagrees with selected mode: {registers}")
        cues = []
        start = time.monotonic()
        try:
            for phase, prompt, seconds in TRIALS[trial]:
                cues.append({"phase": phase, "host_us": round((time.monotonic() - start) * 1e6)})
                print("  " + prompt, flush=True)
                time.sleep(seconds)
        finally:
            self.command("E")
        deadline = time.monotonic() + 12
        header = self.line(deadline).split()
        if len(header) != 7 or header[:3] != ["BEGIN", side, mode]:
            raise ValueError(f"Unexpected capture header {header}")
        count, dropped, errors, elapsed = map(int, header[3:])
        if not (0 <= count <= 1536 and min(dropped, errors, elapsed) >= 0):
            raise ValueError(f"Invalid capture counters {header}")
        packets = []
        for _ in range(count):
            fields = self.line(deadline).split()
            if len(fields) != 3 or fields[0] != "P" or not re.fullmatch("[0-9a-f]{12}", fields[2]):
                raise ValueError(f"Invalid packet {fields}")
            stamp = int(fields[1])
            if not (0 <= stamp <= elapsed) or (packets and stamp < packets[-1]["us"]):
                raise ValueError("Packet timestamps out of sequence.")
            raw = bytes.fromhex(fields[2])
            packets.append({"us": stamp, "raw": raw[:6 if mode == "A" else 3].hex(),
                            **decode(mode, raw)})
        if self.line(deadline) != "END":
            raise ValueError("Missing capture terminator.")
        return dict(protocol=1, utc=datetime.now(timezone.utc).isoformat(), side=side, mode=mode,
                    trial=trial, registers=registers, cues=cues, elapsed_us=elapsed,
                    discarded=dropped, io_errors=errors, packets=packets)


def decode(mode, raw):
    flags = raw[0]
    if mode == "A":
        return dict(x=raw[2] | ((raw[4] & 15) << 8), y=raw[3] | ((raw[4] >> 4) << 8),
                    z=raw[5] & 63, buttons=flags & 63)
    # Match the pinned driver's signed int8 conversion, including sign flags.
    def delta(value, sign):
        value |= 128 if flags & sign else 0
        return value - 256 if value >= 128 else value
    return dict(dx=delta(raw[1], 16), dy=delta(raw[2], 32), buttons=flags & 7)


def summarize(record):
    packets = record["packets"]
    print(f"  {len(packets)} packets, {record['discarded']} discarded, {record['io_errors']} I/O errors")
    if record["discarded"] or record["io_errors"]:
        print("  Incomplete capture. Repeat this trial.")
        return
    if not packets:
        print("  No packets observed in this window.")
        return
    if record["mode"] == "A":
        # Cirque's sample uses X != 0. Keep Z independent to expose disagreements.
        touching = False
        edges = []
        for p in packets:
            if bool(p["x"]) != touching:
                touching = bool(p["x"])
                edges.append(f"{'down' if touching else 'up'}@{p['us'] / 1e6:.3f}s")
        disagreements = sum(bool(p["x"]) != bool(p["z"]) for p in packets)
        print("  Contact sequence (X criterion):", " ".join(edges) or "none")
        print(f"  X and Z contact criteria disagreed on {disagreements} packets.")
    for i, cue in enumerate(record["cues"]):
        until = (record["cues"][i + 1]["host_us"] if i + 1 < len(record["cues"])
                 else record["elapsed_us"] + 1)
        window = [p for p in packets if cue["host_us"] <= p["us"] < until]
        if record["mode"] == "A":
            contacts = [p for p in window if p["x"]]
            detail = f"{len(contacts)} contact packets"
            if contacts:
                xs, ys, zs = ([p[k] for p in contacts] for k in ("x", "y", "z"))
                detail += f", X/Y span {max(xs) - min(xs)}/{max(ys) - min(ys)} counts, Z {min(zs)}–{max(zs)}"
        else:
            kinds = Counter("motion" if p["dx"] or p["dy"] else "stationary" for p in window)
            detail = (f"{kinds['motion']} with motion, {kinds['stationary']} with zero motion, "
                      f"{sum(bool(p['buttons']) for p in window)} with button bits set")
        gaps = [(b["us"] - a["us"]) / 1000 for a, b in zip(window, window[1:])]
        if gaps:
            detail += f", median gap {statistics.median(gaps):.1f} ms"
        print(f"  {cue['phase']:9} {detail}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("side", choices=["lh", "rh"])
    parser.add_argument("--port", help="USB serial device (auto-selects a single cu.usbmodem port)")
    parser.add_argument("--mode", choices=["both", *MODES], default="both")
    parser.add_argument("--trial", choices=["all", *TRIALS], default="all")
    parser.add_argument("--out", default="/private/tmp/go60-pad-probe.jsonl")
    args = parser.parse_args()
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not args.port and len(ports) != 1:
        parser.error("Select --port. Detected USB modem ports: " + (", ".join(ports) or "none"))
    port = args.port or ports[0]
    modes = MODES if args.mode == "both" else [args.mode]
    trials = TRIALS if args.trial == "all" else [args.trial]
    with open_port(port) as fd:
        probe = Probe(fd)
        probe.identify(args.side)
        print(f"Connected to {args.side} on {port}. Writing to {args.out}.")
        with open(args.out, "a", encoding="utf-8") as output:
            for mode in modes:
                for trial in trials:
                    print(f"\n{mode} / {trial}")
                    print("  " + " Then ".join(prompt for _, prompt, _ in TRIALS[trial][1:]))
                    input("  Start with your finger off. Press Return when ready. ")
                    record = probe.record(args.side, MODES[mode], trial)
                    output.write(json.dumps(record, separators=(",", ":")) + "\n")
                    output.flush()
                    summarize(record)
                    print("  Saved.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, EOFError) as exc:
        sys.exit(str(exc))
    except KeyboardInterrupt:
        sys.exit("Stopped.")
