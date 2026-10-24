"""Shared emulator-only target guard, including shell entry points. Never chooses an adb default."""
import os
import re
import sys


def emulator_serial(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    selected = os.environ.get("ANDROID_SERIAL", "emulator-5580")
    for index, value in enumerate(arguments):
        if value == "--serial":
            if index + 1 >= len(arguments):
                raise ValueError("--serial requires an emulator serial")
            selected = arguments[index + 1]
        elif value.startswith("--serial="):
            selected = value.split("=", 1)[1]
    if re.fullmatch(r"emulator-\d+", selected) is None:
        raise ValueError("Only emulator-<port> serials are supported; physical devices are refused")
    os.environ["ANDROID_SERIAL"] = selected
    return selected


if __name__ == "__main__":
    print(emulator_serial())
