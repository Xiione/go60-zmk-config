"""Validate built UF2s against generated Zephyr inputs and write a sidecar."""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FAMILIES = {"lh": 0x9809B007, "rh": 0x980AB007}


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-c", f"safe.directory={directory.resolve()}", "-C", str(directory), *args],
        text=True,
    ).strip()


def verify_board(side, image):
    if not image or len(image) % 512:
        raise ValueError(f"Invalid UF2 size for {side}")
    for index in range(len(image) // 512):
        offset = index * 512
        first, second, flags, address, size, number, count, family = struct.unpack_from("<8I", image, offset)
        if (first, second) != (0x0A324655, 0x9E5D5157) or image[offset+508:offset+512] != bytes.fromhex("306fb10a"):
            raise ValueError(f"Invalid UF2 magic at {index}")
        if not flags & 0x2000 or family != FAMILIES[side] or number != index or count != len(image) // 512:
            raise ValueError(f"Unexpected board or block index for {side}")
        if not (0 < size <= 476 and 0x26000 <= address and address + size <= 0xec000):
            raise ValueError(f"Block outside the Go60 application partition: {address:#x}")


def effective(profile, side, directory):
    tuning = profile.startswith("tuning-")
    config = (directory / (".config" if tuning else "zmk.kconfig")).read_text().splitlines()
    dts = (directory / ("zephyr.dts" if tuning else "zmk.dts")).read_text()
    if f"CONFIG_BOARD_GO60_{side.upper()}=y" not in config:
        raise ValueError(f"Expected board go60_{side}")
    settings = {"kconfig_sha256": hashlib.sha256(("\n".join(config) + "\n").encode()).hexdigest(),
                "devicetree_sha256": hashlib.sha256(dts.encode()).hexdigest()}
    if profile == "probe" or profile == "tuning-trace":
        uart = "pad_probe_uart:" if profile == "probe" else "scroll_trace_uart:"
        if "CONFIG_USB_CDC_ACM=y" not in config or uart not in dts:
            raise ValueError("Missing diagnostic serial interface")
    if profile == "probe":
        if "CONFIG_INPUT_PINNACLE=y" not in config:
            raise ValueError("Missing Pinnacle driver")
    elif side == "lh":
        if "CONFIG_ZMK_POINTING_SCROLL_RESOLUTION=100" not in config:
            raise ValueError("Unexpected HID scroll resolution")
        settings["scroll_resolution"] = 100
        listener = dts.split("cirque_lh_listener: cirque_lh_listener {", 1)[1]
        chain = re.search(r"input-processors = ([^;]+);", listener)[1]
        settings["processors"] = chain
        scale = re.search(r"&zip_scroll_scaler\s+(\w+)\s+(\w+)", chain)
        ratio = [int(n, 0) for n in scale.groups()]
        if ("&left_scroll_inertia" in chain) != tuning:
            raise ValueError("Wrong inertia profile")
        if tuning:
            header = (directory / "include/generated/devicetree_generated.h").read_text()
            settings["inertia"] = props = {
                k.replace("_", "-"): int(v) for k, v in re.findall(
                    r"^#define DT_N_S_left_scroll_inertia_P_([a-z_]+)\s+(-?\d+)$", header, re.M)
            }
            if ratio != [props["scale"], props["scale-div"]]:
                raise ValueError("Live and coast scales disagree")
        elif ratio != [1, 2]:
            raise ValueError("Daily live scaler must be 1/2")
        settings["live_scale"] = ratio
    return settings


def main():
    profile, build, artifact, firmware = sys.argv[1:]
    build, artifact = Path(build), Path(artifact)
    sides = ["lh", "rh"] if profile == "daily" else ["rh" if "-rh-" in artifact.name else "lh"]
    boards = {}
    images = []
    for side in sides:
        directory = build if profile.startswith("tuning-") else build / side
        image = (directory / "zmk.uf2").read_bytes()
        verify_board(side, image)
        images.append(image)
        boards[side] = effective(profile, side, directory)
    if artifact.read_bytes() != b"".join(images):
        raise ValueError("Installed artifact differs from the verified board output")
    dependencies = json.loads((Path(firmware) / "nix/manifest.json").read_text())
    modules = {p.name: git(p, "rev-parse", "HEAD") for p in sorted((ROOT/"modules").iterdir())
               if (p/".git").exists()}
    manifest = dict(profile=profile, artifact=artifact.name, boards=boards, config_modules=modules,
                    firmware_modules={p["name"]: p["revision"] for p in dependencies
                                      if p["name"] in {"zephyr", "cirque-input-module"}},
                    firmware=git(Path(firmware), "rev-parse", "HEAD"),
                    config=git(ROOT, "rev-parse", "HEAD"),
                    config_dirty=bool(git(ROOT, "status", "--porcelain", "--untracked-files=normal",
                                          "--", "config", "modules", "tools", "firmware.env",
                                          "Dockerfile", "build.sh", "build.bat")),
                    sha256=hashlib.sha256(artifact.read_bytes()).hexdigest())
    artifact.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
