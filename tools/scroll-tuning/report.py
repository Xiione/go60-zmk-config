#!/usr/bin/env python3
"""Summarize host scroll traces and firmware timing without mixing clock domains."""
import argparse
from collections import defaultdict
import html
import json
import math
from pathlib import Path
from statistics import median

ACTIVE_ENDED = 8
GRID_MS = range(0, 3001, 25)
METRICS = ("travel", "duration_ms", "peak_speed", "last_speed")
COAST_ENDS = {4: "stopped", 5: "interrupted", 7: "speed cutoff",
              8: "duration cap", 9: "input reset"}


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * fraction)]


def read_trials(path):
    trials = defaultdict(list)
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            row = json.loads(line)
            trials[row["trial"]].append(row)
        except (ValueError, KeyError, TypeError) as error:
            raise SystemExit(f"{path}:{number}: {error}") from error
    return trials.values()


def elapsed_ms(start, end):
    return ((end - start) & 0xFFFFFFFF) / 1000


def firmware_metrics(records):
    coasts = []
    start = last_input = end_reason = None
    for row in records:
        event, timestamp = row["event"], row["firmware_us"]
        if event == 1:
            last_input = timestamp
        elif event == 2:
            if start is not None:
                return None
            start = timestamp
            handoff = elapsed_ms(last_input, start) if last_input is not None else None
            emitted = []
            end_reason = None
        elif event == 3:
            if start is None:
                return None
            emitted.append((elapsed_ms(start, timestamp), row["x"], row["y"]))
        elif event in {7, 8, 9}:
            if start is None:
                return None
            end_reason = event
        elif event in {4, 5}:
            if start is None:
                return None
            reason = end_reason or event
            coasts.append({
                "handoff_ms": handoff, "duration_ms": elapsed_ms(start, timestamp),
                "counts": sum(math.hypot(x, y) for _, x, y in emitted),
                "end_reason": COAST_ENDS[reason], "interrupted": reason in {5, 9},
                "trace": emitted,
            })
            start = None
    if start is not None:
        return None
    return {
        "coast_count": len(coasts),
        "total_coast_counts": sum(coast["counts"] for coast in coasts),
        "interruption_count": sum(coast["interrupted"] for coast in coasts),
        "coasts": coasts,
    }


def trial_firmware_trace(rows, begin, end):
    token = begin.get("trace_token")
    trace = [row for row in rows if row["kind"].startswith("trace_")]
    if (token is None or len(trace) < 4
            or [row["kind"] for row in (trace[0], trace[1], trace[-1])]
            != ["trace_ready", "trace_begin", "trace_end"]
            or rows.index(trace[0]) >= rows.index(end) or rows.index(trace[1]) <= rows.index(end)
            or any(row.get("sequence") != token for row in trace)):
        return None, "incomplete firmware trace"
    header = trace[1]
    records = trace[2:-1]
    if (header["overflow"] or header["count"] != len(records)
            or any(row["kind"] != "trace_event" for row in records)
            or not any(row["event"] == 1 for row in records)):
        return None, "incomplete firmware trace"
    if header["transport"] != begin["transport"]:
        return None, "firmware transport mismatch"
    metrics = firmware_metrics(records)
    return (metrics, None) if metrics is not None else (None, "incomplete firmware trace")


def host_curve(viewport, direction, scenario):
    axis = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}
    first = viewport[0]
    move_x = viewport[-1]["x"] - first["x"]
    move_y = viewport[-1]["y"] - first["y"]
    length = math.hypot(move_x, move_y)
    projection = axis.get(direction) or ((move_x / length, move_y / length) if length else (0, 1))
    points = [(row["time"], (row["x"] - first["x"]) * projection[0]
               + (row["y"] - first["y"]) * projection[1]) for row in viewport]
    moving = [(t, p) for i, (t, p) in enumerate(points[1:], 1) if p != points[i - 1][1]]
    if not moving:
        return None, None
    # The direction label groups gestures. Normalize viewport sign so a finger-up
    # swipe under natural scrolling compares by travel even when document Y increases.
    travel = moving[-1][1] if scenario == "swipe" else moving[0][1]
    sign = -1 if (travel or moving[0][1]) < 0 else 1
    start = moving[0][0]
    # Integrate sampled viewport positions using the latest observed value.
    times = [(max(0, (t - start) * 1000), sign * position) for t, position in moving]
    position = 0
    index = 0
    curve = []
    for ms in GRID_MS:
        while index < len(times) and times[index][0] <= ms:
            position = times[index][1]
            index += 1
        curve.append(round(position, 3))
    return times, curve


def measure(rows):
    if any(row["kind"] == "discard" for row in rows):
        return None, "discarded"
    begin = next((row for row in rows if row["kind"] == "begin"), None)
    end = next((row for row in rows if row["kind"] == "end"), None)
    if not begin or not end:
        return None, "incomplete"
    firmware_trace = None
    if begin.get("expect_trace"):
        firmware_trace, reason = trial_firmware_trace(rows, begin, end)
        if reason:
            return None, reason
    viewport = sorted((row for row in rows if row["kind"] == "viewport"), key=lambda row: row["time"])
    wheel = sorted((row for row in rows if row["kind"] == "wheel"), key=lambda row: row["time"])
    if len(viewport) < 2 or not wheel:
        return None, "no motion"
    times, curve = host_curve(viewport, begin["direction"], begin["scenario"])
    if times is None:
        return None, "no motion"
    distance = times[-1][1]
    velocity = [(b - a) * 1000 / GRID_MS.step for a, b in zip([0, *curve], curve)]
    release = next((row["time"] for row in wheel if row["phase"] & ACTIVE_ENDED), None)
    momentum = [row for row in wheel if row["momentum"] and (row["dx"] or row["dy"])]
    end_time = times[-1][0]
    end_position = times[-1][1]
    previous = next(((t, p) for t, p in reversed(times) if t <= end_time - 50), (0, 0))
    last_speed = abs(end_position - previous[1]) * 1000 / max(50, end_time - previous[0])
    host_momentum_ms = None
    host_coast_travel = None
    if release is not None and momentum:
        host_momentum_ms = round((momentum[-1]["time"] - release) * 1000, 1)
        first_motion = next(
            row["time"] for row in viewport
            if (row["x"], row["y"]) != (viewport[0]["x"], viewport[0]["y"])
        )
        release_ms = (release - first_motion) * 1000
        release_position = next((p for t, p in reversed(times) if t <= release_ms), 0)
        host_coast_travel = round(distance - release_position, 2)
    return {
        "trial": begin["trial"], "device": begin["device"], "firmware": begin["firmware"],
        "transport": begin["transport"], "scenario": begin["scenario"],
        "direction": begin["direction"], "speed": begin["speed"], "curve": curve,
        "travel": round(distance, 2), "duration_ms": round(end_time, 1),
        "peak_speed": round(max(map(abs, velocity), default=0), 1), "last_speed": round(last_speed, 1),
        "precise": sum(row["precise"] for row in wheel) / len(wheel),
        "host_momentum_ms": host_momentum_ms, "host_coast_travel": host_coast_travel,
        "firmware_trace": firmware_trace,
    }, None


def group(rows):
    bins = defaultdict(list)
    for row in rows:
        bins[row["device"], row["firmware"] if row["device"] == "cirque" else "reference",
             row["speed"], row["direction"]].append(row)
    return [
        {"device": device, "firmware": firmware, "speed": speed, "direction": direction,
         "n": len(bucket), "curve": [median(column) for column in zip(*(r["curve"] for r in bucket))],
         "metrics": {key: median([row[key] for row in bucket]) for key in METRICS},
         "spread": {key: percentile([r[key] for r in bucket], .75) - percentile([r[key] for r in bucket], .25)
                    for key in METRICS}}
        for (device, firmware, speed, direction), bucket in sorted(bins.items())
    ]


def ranks(groups):
    references = {(g["speed"], g["direction"]): g for g in groups if g["device"] == "macbook"}
    candidates = defaultdict(list)
    for g in groups:
        if g["device"] == "cirque":
            candidates[g["firmware"]].append(g)
    result = []
    for label, bins in candidates.items():
        covered = {(g["speed"], g["direction"]) for g in bins if g["n"] >= 4}
        preferred = {key: g for key, g in references.items() if g["n"] >= 4}
        scores = []
        matched = 0
        for g in bins:
            key = g["speed"], g["direction"]
            if key not in preferred or key not in covered:
                continue
            ref = preferred[key]
            matched += 1
            scores += [abs(g["metrics"][m] - ref["metrics"][m]) /
                       max(ref["spread"][m], abs(ref["metrics"][m]) * 0.10, 1) for m in METRICS]
            divergence = sum(abs(a - b) for a, b in zip(g["curve"], ref["curve"])) / len(GRID_MS)
            scores.append(divergence / max(abs(ref["metrics"]["travel"]) * 0.10, 1))
        result.append({"firmware": label, "bins": matched, "available": len(preferred),
                       "score": round(sum(scores) / len(scores), 3) if scores else None})
    return sorted(result, key=lambda rank: (-rank["bins"],
                                             rank["score"] if rank["score"] is not None else math.inf))


def write_report(path, data):
    groups, trials, ranking = (data[key] for key in ("groups", "trials", "ranking"))
    def cells(values):
        return "<tr>" + "".join(f"<td>{html.escape(str(v))}</td>" for v in values) + "</tr>"
    rank_rows = "\n".join(cells((r["firmware"], f'{r["bins"]}/{r["available"]}', r["score"])) for r in ranking)
    group_rows = "\n".join(cells((g["device"], g["firmware"], g["speed"], g["direction"], g["n"],
                                 *(round(g["metrics"][m], 1) for m in METRICS))) for g in groups)
    trace_rows = "\n".join(cells((r["trial"][:8], r["device"], r["firmware"], r["scenario"],
                                 r["host_momentum_ms"], r["host_coast_travel"], t.get("coast_count"),
                                 t.get("total_coast_counts"), t.get("interruption_count")))
                           for r in trials for t in [r["firmware_trace"] or {}])
    coast_rows = "\n".join(cells((r["trial"][:8], index, coast["handoff_ms"],
                                 coast["duration_ms"], coast["counts"], coast["end_reason"]))
                           for r in trials
                           for index, coast in enumerate((r["firmware_trace"] or {}).get("coasts", []), 1))
    payload = json.dumps(groups).replace("<", "\\u003c")
    rejected = html.escape(", ".join(f"{reason}: {n}" for reason, n in data["rejected"].items()) or "none")
    path.write_text(f"""<!doctype html><meta charset="utf-8"><title>Go60 scroll tuning</title>
<style>
body{{font:15px system-ui;margin:2rem auto;max-width:1080px;padding:0 1rem;color:#171b2a;background:#fafbfe}}
canvas{{width:100%;border:1px solid #d0d5e2;background:white;display:block;margin:.75rem 0}}
table{{border-collapse:collapse;margin-bottom:1rem}}th,td{{padding:.35rem .65rem;border-bottom:1px solid #d0d5e2;text-align:left}}
</style><h1>Go60 scroll tuning</h1><p>Excluded trials — {rejected}</p>
<label>Swipe group <select id="bin"></select></label>
<canvas id="distance" width="1040" height="270" aria-label="Cumulative viewport travel"></canvas>
<canvas id="velocity" width="1040" height="270" aria-label="Viewport velocity"></canvas>
<div id="legend"></div>
<h2>Candidate ranking</h2><p>Lower is closer to the reference. Compare candidates over the same bins. Each scored bin needs at least four swipes per device.</p>
<table><tr><th>Firmware</th><th>Matched bins</th><th>Error</th></tr>{rank_rows}</table>
<h2>Median host metrics</h2><table><tr><th>Device</th><th>Firmware</th><th>Speed</th><th>Direction</th><th>Swipes</th>
<th>Travel (pt)</th><th>Duration (ms)</th><th>Peak (pt/s)</th><th>End (pt/s)</th></tr>{group_rows}</table>
<h2>Whole-trial timing</h2>
<table><tr><th>Trial</th><th>Device</th><th>Firmware</th><th>Scenario</th><th>macOS momentum (ms)</th><th>macOS coast (pt)</th>
<th>Coasts</th><th>Total coast counts</th><th>Interruptions</th></tr>{trace_rows}</table>
<h2>Individual coasts</h2><p>Firmware times are relative to its own input and coast events.</p>
<table><tr><th>Trial</th><th>Coast</th><th>Handoff (ms)</th><th>Duration (ms)</th><th>Counts</th><th>End reason</th></tr>{coast_rows}</table>
<script>
const groups = {payload};
const select = document.getElementById("bin");
const colors = ["#204eb6", "#bd4217", "#157150", "#a13788", "#7a5610"];
for (const name of new Set(groups.map(g => g.speed + " " + g.direction))) {{
  const option = document.createElement("option"); option.textContent = name; select.append(option);
}}
function chart(id, values, label) {{
  const canvas = document.getElementById(id), ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const left = 60, top = 28, width = canvas.width - 80, height = canvas.height - 62;
  const maximum = Math.max(1, ...values.flat()), minimum = Math.min(0, ...values.flat());
  const y = value => top + height * (maximum - value) / (maximum - minimum);
  ctx.font = "13px system-ui"; ctx.fillStyle = "#171b2a";
  ctx.fillText(label, 12, 18);
  ctx.fillText(String(Math.round(maximum)), 10, y(maximum) + 4);
  ctx.fillText(String(Math.round(minimum)), 10, y(minimum) + 4);
  ctx.strokeStyle = "#d0d5e2";
  ctx.beginPath(); ctx.moveTo(left, y(0)); ctx.lineTo(left + width, y(0)); ctx.stroke();
  for (let t = 0; t <= 3000; t += 500) {{
    ctx.fillText(t + " ms", left + width * t / 3000 - 10, canvas.height - 10);
  }}
  values.forEach((curve, i) => {{
    ctx.strokeStyle = colors[i % colors.length]; ctx.lineWidth = 2; ctx.beginPath();
    curve.forEach((v, j) => {{
      const x = left + width * j / (curve.length - 1);
      if (j) ctx.lineTo(x, y(v)); else ctx.moveTo(x, y(v));
    }});
    ctx.stroke();
  }});
}}
function draw() {{
  const bin = groups.filter(g => g.speed + " " + g.direction === select.value);
  chart("distance", bin.map(g => g.curve), "Viewport displacement (points)");
  chart("velocity", bin.map(g => g.curve.map((v, i) => (v - (g.curve[i - 1] ?? 0)) * 40)), "Viewport velocity (points/s)");
  const legend = document.getElementById("legend"); legend.replaceChildren();
  bin.forEach((g, i) => {{
    const label = document.createElement("div"); label.style.color = colors[i % colors.length];
    label.textContent = g.device + " / " + g.firmware + " (" + g.n + " swipes)"; legend.append(label);
  }});
}}
select.addEventListener("change", draw); draw();
</script>""", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--transport", choices=["Bluetooth", "USB"], default="Bluetooth")
    parser.add_argument("--out", type=Path, required=True, help="HTML report; also writes a JSON summary")
    args = parser.parse_args()
    trials = []
    rejected = defaultdict(int)
    for rows in read_trials(args.capture):
        trial, reason = measure(rows)
        if reason:
            rejected[reason] += 1
        elif trial["device"] == "macbook" or trial["transport"] == args.transport:
            trials.append(trial)
    groups = group(row for row in trials if row["scenario"] == "swipe")
    data = {"groups": groups, "trials": trials, "ranking": ranks(groups), "rejected": dict(rejected)}
    write_report(args.out, data)
    args.out.with_suffix(".json").write_text(json.dumps(data, indent=2))
    print(f"{len(trials)} usable trials, {sum(rejected.values())} excluded. Report: {args.out}")


if __name__ == "__main__":
    main()
