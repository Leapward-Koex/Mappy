import contextlib
import csv
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("compass_lab", ROOT / "tooling/compass-lab.py")
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def row(index, **overrides):
    values = dict(e=1, i=index, s=100, m=index*200, h=0, t=0, c=2, d=0, k=0, r=1)
    values.update(overrides)
    return "[12:00:00] main.c:150> CLAB S " + " ".join(f"{k}={v}" for k, v in values.items())


class ExportTests(unittest.TestCase):
    def start(self, count=3):
        parser = lab.ExportParser()
        self.assertIsNone(parser.feed(f"CLAB B v=1 e=1 n={count} turn=65536"))
        return parser

    def test_complete_out_of_order_and_transport_duplicates(self):
        p = self.start()
        p.feed(row(2)); p.feed(row(0)); p.feed(row(0)); p.feed(row(1))
        self.assertEqual(p.feed("CLAB E e=1 n=3"), "complete")
        self.assertEqual([r['i'] for r in p.complete], [0, 1, 2])

    def test_missing_truncated_conflicting_and_aborted_exports(self):
        for bad in (row(1).replace(" k=0", ""), row(0, h=999), "CLAB X e=1"):
            p = self.start()
            p.feed(row(0)); p.feed(bad); p.feed(row(1)); p.feed(row(2))
            self.assertNotEqual(p.feed("CLAB E e=1 n=3"), "complete")
            self.assertIsNone(p.complete)
        p = self.start()
        p.feed(row(0)); p.feed(row(2))
        self.assertIn("Incomplete", p.feed("CLAB E e=1 n=3"))
        self.assertIsNone(p.complete)

    def test_retry_and_partial_newer_export(self):
        p = self.start(1)
        p.feed(row(0)); self.assertEqual(p.feed("CLAB E e=1 n=1"), "complete")
        p.feed("CLAB B v=1 e=2 n=2 turn=65536")
        self.assertIsNone(p.complete)
        p.feed(row(0, e=1))  # Late row from previous export must not contaminate it.
        self.assertEqual(p.rows, {})
        p.feed(row(0, e=2)); p.feed(row(1, e=2))
        self.assertEqual(p.feed("CLAB E e=2 n=2"), "complete")

    def test_csv_preserves_precision_flags_clock_changes_and_pauses(self):
        p = self.start(5)
        lines = [row(0, h=1), row(1, h=65535), row(2, s=99, m=400, c=0),
                 row(3, s=110, m=100, r=2), row(4, s=110, m=300, r=2, h=16384, d=1)]
        for line in lines: p.feed(line)
        self.assertEqual(p.feed("CLAB E e=1 n=5"), "complete")
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()):
            path = Path(temp) / "capture.csv"
            summary = lab.export_csv(p.complete, path)
            with path.open() as source: result = list(csv.DictReader(source))
            self.assertEqual(result[1]['magnetic_native'], '65535')
            self.assertAlmostEqual(float(result[1]['magnetic_clockwise_degrees']), 0.005493, places=6)
            self.assertAlmostEqual(float(result[1]['change_degrees']), 0.010986, places=6)
            self.assertEqual(result[2]['interval_ms'], '-800')
            self.assertEqual(result[2]['clock_went_backward'], '1')
            self.assertEqual(result[2]['magnetic_clockwise_degrees'], '')
            self.assertEqual(result[3]['segment_start'], '1')
            self.assertEqual(result[3]['observed_speed_degrees_per_second'], '')
            self.assertEqual(summary['positive_interval_max_ms'], 200)
            self.assertEqual(summary['backward_clock_steps'], 1)
            self.assertEqual(result[4]['true_clockwise_degrees'], '0.0')

    def test_malformed_header_and_test_data_label(self):
        p = lab.ExportParser()
        self.assertIn("Unsupported", p.feed("CLAB B v=99 e=1"))
        p.feed(row(0))
        self.assertIsNone(p.complete)
        p.feed("CLAB B v=1 e=2 n=1 turn=65536 test=1")
        p.feed(row(0, e=2))
        self.assertEqual(p.feed("CLAB E e=2 n=1"), "complete")
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()):
            summary = lab.export_csv(p.complete, Path(temp) / "test.csv", test_input=True)
            self.assertTrue(summary['test_input'])
    def test_transport_row_fits_pebble_log_body(self):
        body = row(2047, e=65535, s=4294967295, m=999, h=-2147483648,
                   t=-2147483648, c=-1, d=1, k=65535, r=65535).split('> ')[1]
        self.assertLessEqual(len(body.encode()), 120)


if __name__ == '__main__':
    unittest.main()
