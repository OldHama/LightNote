#!/usr/bin/env python3
"""Exercise real NSApplication quit in isolated subprocesses; no personal notes."""
import os
import json
import pathlib
import subprocess
import sys
import tempfile

binary = sys.argv[1] if len(sys.argv) > 1 else "/Applications/LightNote.app/Contents/MacOS/LightNote"
for failing in (False, True):
    with tempfile.TemporaryDirectory(prefix="LightNote-quit-test-") as directory:
        args = [binary, "--self-test", "--quit-save-test"]
        if failing:
            args.append("--fail-save")
        result = subprocess.run(args, capture_output=True, text=True, timeout=30,
                                env={**os.environ, "LIGHTNOTE_TEST_DIRECTORY": directory})
        if result.returncode:
            raise RuntimeError(f"Quit test failed ({result.returncode}): {result.stdout}\n{result.stderr}")
        notes = list(pathlib.Path(directory).glob("*.lightnote"))
        assert len(notes) == 1, "Lifecycle test did not retain exactly one note"
        saved = json.loads(notes[0].read_text())
        if failing:
            assert "QUIT_FAILURE_CANCELLED_AND_CONTENT_PRESERVED" in result.stdout, result.stderr
            assert saved["strokes"] == [], "Failure overwrote original file"
            print("PASS: failed quit cancelled; dirty input and original file preserved")
        else:
            expected = json.loads((pathlib.Path(directory) / "expected.json").read_text())
            assert saved == expected, "Actual quit omitted latest input"
            assert len(saved["strokes"]) == 2
            print("PASS: actual NSApplication quit waited for old autosave and saved latest input")
