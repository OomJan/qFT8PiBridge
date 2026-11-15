import ast
import json
from pathlib import Path
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch, Mock
from qft8_pages import PressGesture, CpuAverage, cpu_counters, memory_line, SystemPages

class ButtonTests(unittest.TestCase):
    def test_short_press_limits(self):
        for seconds, expected in [(0.049, None), (0.05, None), (0.051, 'short'),
                                  (0.5, 'short'), (1, 'short'), (1.001, None), (2.99, None)]:
            with self.subTest(seconds=seconds):
                button = PressGesture(3, short=True)
                button.update(False, 0)
                button.update(True, 1)
                self.assertEqual(button.update(False, 1+seconds), expected)

    def test_wifi_long_once(self):
        b = PressGesture(3, short=True)
        b.update(False, 0)
        b.update(True, 1)
        self.assertIsNone(b.update(True, 3.999))
        self.assertEqual(b.update(True, 4), 'long')
        self.assertIsNone(b.update(True, 9))
        self.assertIsNone(b.update(False, 10))

    def test_shutdown_five_seconds(self):
        b = PressGesture(5)
        b.update(False, 0)
        b.update(True, 1)
        self.assertIsNone(b.update(True, 5.999))
        self.assertEqual(b.update(True, 6), 'long')
        self.assertIsNone(b.update(False, 7))

    def test_boot_held_button_ignored(self):
        b = PressGesture(3, short=True)
        self.assertIsNone(b.update(True, 0))
        self.assertIsNone(b.update(True, 10))
        self.assertIsNone(b.update(False, 11))

    def test_release_crosses_long_threshold(self):
        for duration in (3, 5):
            b = PressGesture(duration, short=True)
            b.update(False, 0)
            b.update(True, 1)
            self.assertEqual(b.update(False, 1+duration), 'long')

class StatsTests(unittest.TestCase):
    def test_cpu_four_core_values_and_no_guest_double_count(self):
        counters = cpu_counters('cpu 99 0 0 0\ncpu0 10 0 0 90 0 0 0 0 8 0\ncpu1 20 0 0 80 0 0 0 0\n')
        self.assertEqual(counters[0], (100, 90))
        avg = CpuAverage()
        self.assertIn('collecting', avg.add(0, {i:(0,0) for i in range(4)}))
        self.assertEqual(avg.add(5, {i:(1000,996-i) for i in range(4)}), 'CPU%: 0.4 0.5 0.6 0.7')

    def test_rolling_window_excludes_old_load(self):
        avg = CpuAverage()
        avg.add(0, {0:(0,0)})
        avg.add(5, {0:(100,0)})  # Full load for the first five seconds.
        for second in range(10, 306, 5):
            result = avg.add(second, {0:(second*20,(second-5)*20)})
        self.assertEqual(result, 'CPU%: 0.0')
        self.assertLessEqual(len(avg.samples), 62)

    def test_memory_available_not_just_free(self):
        self.assertEqual(memory_line('MemTotal: 424960 kB\nMemAvailable: 293888 kB\nMemFree: 100 kB\n'), 'RAM: 128/415MiB')


if __name__ == '__main__':
    unittest.main(verbosity=2)
