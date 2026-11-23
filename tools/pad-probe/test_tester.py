"""Exercise framed serial transfers, including a quiet pad and truncated data."""
from contextlib import redirect_stdout
import io
import json
import os
import pty
import tempfile
import threading
import unittest
from unittest.mock import patch

import tester


class ProbeTest(unittest.TestCase):
    def exchange(self, side, mode, rows, header, end="END"):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        feed = 3 if mode == "A" else 129
        replies = [("?", f"\nPAD1 {side}\n"), (mode, f"READY {side} {mode} 7 1 {feed} 31 100 5\n"),
                   ("E", f"BEGIN {side} {mode} {header}\n" + "".join(row + "\n" for row in rows)
                    + end + "\n")]
        received = []

        def run_board():
            for _, reply in replies:
                received.append(os.read(master, 1).decode())
                os.write(master, reply.encode())

        with tester.open_port(os.ttyname(slave)) as fd:
            board = threading.Thread(target=run_board, daemon=True)
            board.start()
            probe = tester.Probe(fd)
            probe.identify(side)
            with patch.dict(tester.TRIALS, hold=[]):
                record = probe.record(side, mode, "hold")
            board.join(1)
        self.assertEqual(received, [command for command, _ in replies])
        return record

    def test_absolute_sequence(self):
        record = self.exchange("lh", "A", ["P 40 00003456a30c", "P 130 000000000000"],
                               "2 0 0 500")
        down, up = record["packets"]
        self.assertEqual((down["x"], down["y"], down["z"]), (0x334, 0xa56, 12))
        self.assertEqual((up["x"], up["y"], up["z"]), (0, 0, 0))
        self.assertEqual(record["registers"]["sample_rate"], 100)

    def test_relative_flags(self):
        record = self.exchange("rh", "R", ["P 5 11fb04000000"], "1 2 1 400")
        packet, = record["packets"]
        self.assertEqual((packet["dx"], packet["dy"], packet["buttons"]), (-5, 4, 1))
        self.assertEqual(record["discarded"], 2)
        self.assertEqual(record["io_errors"], 1)

    def test_silent_sensor(self):
        record = self.exchange("rh", "A", [], "0 0 0 500")
        self.assertEqual(record["packets"], [])

    def test_missing_packet(self):
        with self.assertRaisesRegex(ValueError, "Invalid packet"):
            self.exchange("lh", "A", [], "1 0 0 500")

    def test_guided_session_appends(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        port = os.ttyname(slave)
        replies = ["PAD1 rh", "READY rh A 7 1 3 31 100 5",
                   "BEGIN rh A 1 0 0 5000\nP 1000 00003456a30c\nEND",
                   "READY rh R 7 1 129 197 100 5", "BEGIN rh R 0 0 0 5000\nEND"]
        received = []

        def run_board():
            for reply in replies:
                received.append(os.read(master, 1).decode())
                os.write(master, (reply + "\n").encode())

        with tempfile.NamedTemporaryFile(mode="w+") as output:
            output.write('{"previous":true}\n')
            output.flush()
            board = threading.Thread(target=run_board, daemon=True)
            board.start()
            args = ["tester.py", "rh", "--port", port, "--trial", "hold", "--out", output.name]
            with patch("sys.argv", args), patch("builtins.input", return_value=""), \
                    patch("time.sleep"), redirect_stdout(io.StringIO()):
                tester.main()
            board.join(1)
            output.seek(0)
            previous, absolute, relative = map(json.loads, output)
        self.assertEqual(received, ["?", "A", "E", "R", "E"])
        self.assertEqual(previous, {"previous": True})
        self.assertEqual((absolute["mode"], relative["mode"]), ("A", "R"))
        self.assertEqual([c["phase"] for c in absolute["cues"]], ["off", "hold", "lift"])

    def test_wrong_hand(self):
        probe = tester.Probe(None)
        with patch.object(probe, "command"), patch.object(probe, "line", return_value="PAD1 rh"):
            with self.assertRaisesRegex(ValueError, "Expected PAD1 lh"):
                probe.identify("lh")

    def test_wrong_terminator(self):
        with self.assertRaisesRegex(ValueError, "terminator"):
            self.exchange("lh", "A", [], "0 0 0 500", "READY")


if __name__ == "__main__":
    unittest.main()
