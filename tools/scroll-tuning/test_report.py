import unittest

from report import measure


def trace_events(*events):
    return [
        {"kind": "trace_event", "sequence": 123, "event": kind, "firmware_us": time,
         "x": 0, "y": delta}
        for kind, time, delta in events
    ]


def trial(records=None):
    metadata = {"kind": "begin", "trial": "trial", "device": "cirque", "firmware": "test",
                "transport": "Bluetooth", "scenario": "swipe", "speed": "slow", "direction": "down",
                "expect_trace": records is not None}
    rows = [metadata, {"kind": "viewport", "time": 10, "x": 0, "y": 0}]
    if records is not None:
        metadata["trace_token"] = 123
        rows.append({"kind": "trace_ready", "sequence": 123})
    rows += [
        {"kind": "wheel", "time": 10.01, "dx": 0, "dy": 8, "precise": True, "phase": 0, "momentum": 0},
        {"kind": "viewport", "time": 10.01, "x": 0, "y": 8},
        {"kind": "end"},
    ]
    if records is not None:
        rows += [
            {"kind": "trace_begin", "sequence": 123, "count": len(records), "overflow": False,
             "transport": "Bluetooth"},
            *records, {"kind": "trace_end", "sequence": 123},
        ]
    return rows


class ScrollReportTests(unittest.TestCase):
    def test_first_viewport_update_counts_toward_peak(self):
        metrics, reason = measure(trial())
        self.assertIsNone(reason)
        self.assertEqual(metrics["travel"], 8)
        self.assertEqual(metrics["peak_speed"], 320)

    def test_up_swipe_counts_with_natural_or_reversed_viewport_movement(self):
        for travel in (8, -8):
            with self.subTest(travel=travel):
                rows = trial()
                rows[0]["direction"] = "up"
                rows[3]["y"] = travel
                metrics, reason = measure(rows)
                self.assertIsNone(reason)
                self.assertEqual(metrics["travel"], 8)

    def test_reversal_keeps_negative_travel_past_start(self):
        rows = trial()
        rows[0].update(direction="up", scenario="reversal")
        rows.insert(4, {"kind": "viewport", "time": 10.1, "x": 0, "y": -4})
        metrics, reason = measure(rows)
        self.assertIsNone(reason)
        self.assertEqual(metrics["travel"], -4)
        self.assertGreater(metrics["curve"][0], 0)

    def test_trace_requires_ready_token_finish_and_complete_body(self):
        records = trace_events((1, 5000, 2), (6, 29000, 0))
        rows = trial(records)
        metrics, reason = measure(rows)
        self.assertIsNone(reason)
        self.assertEqual(metrics["firmware_trace"]["coast_count"], 0)

        cases = {
            "early dump": rows[:5] + rows[6:] + [rows[5]],
            "missing ready": [row for row in rows if row["kind"] != "trace_ready"],
            "wrong token": rows[:-1] + [{"kind": "trace_end", "sequence": 124}],
            "truncated body": rows[:-2] + rows[-1:],
            "active coast at finish": trial(trace_events((1, 5000, 2), (2, 29000, 0))),
        }
        for name, capture in cases.items():
            with self.subTest(name=name):
                self.assertEqual(measure(capture), (None, "incomplete firmware trace"))

    def test_repeat_coasts_include_later_emissions_and_input_reset(self):
        records = trace_events(
            (1, 0xFFFFFF00, 4), (2, 744, 0), (3, 8744, 3),
            (1, 30744, -4), (9, 30744, 0), (4, 30744, 0),
            (1, 830744, -3), (2, 854744, 0), (3, 862744, -6),
            (7, 870744, 0), (4, 870744, 0),
        )
        rows = trial(records)
        rows[0]["scenario"] = "reversal"
        measured, reason = measure(rows)
        self.assertIsNone(reason)
        metrics = measured["firmware_trace"]
        self.assertEqual(metrics["coast_count"], 2)
        self.assertEqual(metrics["total_coast_counts"], 9)
        self.assertEqual(metrics["interruption_count"], 1)
        first, second = metrics["coasts"]
        self.assertEqual(first["handoff_ms"], 1)
        self.assertEqual(first["end_reason"], "input reset")
        self.assertEqual(second["end_reason"], "speed cutoff")
        self.assertEqual(second["trace"], [(8, 0, -6)])
        self.assertEqual(second["duration_ms"], 16)


if __name__ == "__main__":
    unittest.main()
