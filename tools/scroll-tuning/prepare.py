#!/usr/bin/env python3
"""Prepare a diagnostic module copy and a stable, candidate-specific keymap."""
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path("/config")
MODULE = ROOT / "modules/zmk-input-processor-scroll-inertia"
TUNING = ROOT / "tools/scroll-tuning"
PROPERTIES = {
    "start", "move", "min-events", "stop", "friction", "release", "gain", "blend",
    "decay-fast", "decay-slow", "decay-tail", "fast", "slow", "decel-samples",
    "decel-ratio", "peak-decay", "gesture-timeout", "suppress-limit", "handoff-ms",
    "limit", "span", "tick", "scale", "scale-div",
}


def prepare(work, mode):
    target = work / "inertia"
    shutil.copytree(MODULE, target, ignore=shutil.ignore_patterns(".git"), dirs_exist_ok=True)
    conf = (ROOT / "config/go60_lh.conf").read_text()
    if mode == "trace":
        conf = re.sub(r"^CONFIG_ZMK_USB_LOGGING=.*\n?", "", conf, flags=re.M)
        conf += ("\nCONFIG_ZMK_USB_LOGGING=n\nCONFIG_SERIAL=y\n"
                 "CONFIG_UART_INTERRUPT_DRIVEN=y\nCONFIG_USB_CDC_ACM=y\n")
        source = target / "src/input_processor_scroll_inertia.c"
        code = source.read_text()
        insertions = {
            '#include "scroll_inertia_math.h"':
                '#include "scroll_inertia_math.h"\n#include "scroll_tuning_trace.h"',
            "bool was_coasting = (data->state == SS_COASTING);":
                'bool was_coasting = (data->state == SS_COASTING);\n'
                '    if (data->state != SS_IDLE) {\n'
                '        trace_scroll(was_coasting ? TRACE_STOP : TRACE_NO_COAST, 0, 0);\n'
                '    }',
            "static void to_tracking_from_coasting(struct scroll_inertia_data *data) {":
                'static void to_tracking_from_coasting(struct scroll_inertia_data *data) {\n'
                '    trace_scroll(TRACE_INTERRUPT, 0, 0);',
            "data->state = SS_COASTING;":
                'data->state = SS_COASTING;\n'
                '    trace_scroll(TRACE_START, data->vel_x, data->vel_y);',
            "zmk_hid_mouse_scroll_set(out_x, out_y);":
                'trace_scroll(TRACE_EMIT, out_x, out_y);\n'
                '        zmk_hid_mouse_scroll_set(out_x, out_y);',
            "if (stopped) {\n        to_idle(data);":
                'if (stopped) {\n'
                '        trace_scroll(TRACE_CUTOFF, data->vel_x, data->vel_y);\n'
                '        to_idle(data);',
            "if (k_uptime_get() - data->inertia_start_time > cfg->span_ms) {\n        to_idle(data);":
                'if (k_uptime_get() - data->inertia_start_time > cfg->span_ms) {\n'
                '        trace_scroll(TRACE_SPAN, 0, 0);\n'
                '        to_idle(data);',
            "if (should_reset_on_timeout(data, cfg, now)) {\n        to_idle(data);":
                'if (should_reset_on_timeout(data, cfg, now)) {\n'
                '        if (data->state == SS_COASTING) {\n'
                '            trace_scroll(TRACE_INPUT_RESET, 0, 0);\n'
                '        }\n'
                '        to_idle(data);',
            "if (ec == EC_UNTRACKED) {\n        return ZMK_INPUT_PROC_CONTINUE;\n    }":
                'if (ec == EC_UNTRACKED) {\n        return ZMK_INPUT_PROC_CONTINUE;\n    }\n'
                '    if (event->value != 0) {\n'
                '        bool horizontal = event->code == INPUT_REL_HWHEEL;\n'
                '        trace_scroll(TRACE_INPUT, horizontal ? event->value : 0,\n'
                '                     horizontal ? 0 : event->value);\n'
                '    }',
        }
        for anchor, replacement in insertions.items():
            if code.count(anchor) != 1:
                raise SystemExit(f"Unexpected inertia source at trace insertion: {anchor}")
            code = code.replace(anchor, replacement)
        shutil.copyfile(TUNING / "trace.h", source.with_name("scroll_tuning_trace.h"))
        source.write_text(code)
    (work / "config/go60_lh.conf").write_text(conf)


def keymap(work):
    source = ROOT / "config"
    destination = work / "config"
    for path in source.iterdir():
        if path.name not in {"go60_lh.keymap", "go60_lh.conf"}:
            link = destination / path.name
            if not link.is_symlink():
                link.symlink_to(path)
    text = (TUNING / "go60_lh.keymap").read_text()
    overrides = {}
    for setting in os.environ.get("GO60_TUNING_SETTINGS", "").splitlines():
        name, _, value = setting.partition("=")
        if name not in PROPERTIES or not re.fullmatch(r"\d{1,5}", value) or name in overrides:
            raise SystemExit(f"Invalid or repeated tuning setting: {setting}")
        overrides[name] = int(value)
    if any(value > 999 for key, value in overrides.items() if key.startswith("decay-") or key == "peak-decay"):
        raise SystemExit("Decay rates must be below 1000.")
    if overrides.get("stop") == 0 or overrides.get("tick") == 0 or overrides.get("scale-div") == 0:
        raise SystemExit("Stop, tick and scale-div must be positive.")
    node = re.search(r"(left_scroll_inertia:\s+left_scroll_inertia\s*\{)(.*?)(\n\s*\};)", text, re.S)
    if not node:
        raise SystemExit("Missing left_scroll_inertia node")
    props = node[2]
    for name, value in overrides.items():
        assignment = rf"(?m)^(\s*{re.escape(name)}\s*=\s*)<\d+>(;)"
        props, replaced = re.subn(assignment, rf"\g<1><{value}>\2", props)
        if not replaced:
            props += f"\n        {name} = <{value}>;"
    text = text[:node.start(2)] + props + text[node.end(2):]
    if {"scale", "scale-div"} & overrides.keys():
        scale = int(re.search(r"\bscale\s*=\s*<(\d+)>", props)[1])
        divisor = int(re.search(r"\bscale-div\s*=\s*<(\d+)>", props)[1])
        text, replaced = re.subn(
            r"&zip_scroll_scaler \d+ \d+", f"&zip_scroll_scaler {scale} {divisor}", text
        )
        if replaced != 1:
            raise SystemExit("Expected one live scroll scaler")
    if os.environ["GO60_TUNING_MODE"] == "trace":
        text += """

&zephyr_udc0 {
    scroll_trace_uart: scroll_trace_uart {
        compatible = "zephyr,cdc-acm-uart";
    };
};
"""
    target = destination / "go60_lh.keymap"
    if not target.exists() or target.read_text() != text:
        target.write_text(text)
    print("Candidate settings:", ", ".join(f"{k}={v}" for k, v in overrides.items()) or "historical baseline")


if __name__ == "__main__":
    command, directory, *args = sys.argv[1:]
    if command == "prepare":
        prepare(Path(directory), args[0])
    elif command == "keymap":
        keymap(Path(directory))
    else:
        raise SystemExit(f"Unknown command: {command}")
