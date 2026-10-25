"""No adb calls: exercise the shared target guard used by all emulator tools."""
import os
import unittest
from unittest.mock import patch
from emulator_serial import emulator_serial


class EmulatorSerialTest(unittest.TestCase):
    def test_default_and_environment(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(emulator_serial([]), 'emulator-5580')
        with patch.dict(os.environ, {'ANDROID_SERIAL': 'emulator-5630'}, clear=True):
            self.assertEqual(emulator_serial([]), 'emulator-5630')

    def test_explicit_serial_overrides_environment(self):
        with patch.dict(os.environ, {'ANDROID_SERIAL': 'physical'}, clear=True):
            self.assertEqual(emulator_serial(['--serial', 'emulator-5624']), 'emulator-5624')
            self.assertEqual(os.environ['ANDROID_SERIAL'], 'emulator-5624')
            self.assertEqual(emulator_serial(['--serial=emulator-5630']), 'emulator-5630')

    def test_physical_missing_and_malformed_serials_are_refused(self):
        for serial in ('phone', '', 'emulator-', 'emulator-123x', 'emulator-123\n', 'emulator-12;echo'):
            with patch.dict(os.environ, {'ANDROID_SERIAL': serial}, clear=True):
                with self.assertRaises(ValueError): emulator_serial([])
        with self.assertRaises(ValueError): emulator_serial(['--serial'])


if __name__ == '__main__':
    unittest.main()
