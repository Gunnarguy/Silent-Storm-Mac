#!/usr/bin/env python3
"""Ask the installed game's developer API for its menu and a fresh render capture."""
from pathlib import Path
import shutil
import time

game = Path.home() / 'Library/Application Support/Silent Storm/Silent Storm'
evidence = Path(__file__).resolve().parents[3] / 'verification/2026-10-25'
command = game / '_s2cmd.txt'
if command.exists():
    raise SystemExit('A diagnostic command is already queued; do not overwrite it.')
command.write_text('cmd mainmenu\n')
deadline = time.monotonic() + 40
while command.exists() and time.monotonic() < deadline:
    time.sleep(.25)
if command.exists():
    raise SystemExit('Game did not acknowledge the diagnostic command.')
time.sleep(4)
shot = game / '_shot.png'
previous = shot.stat().st_mtime_ns if shot.exists() else 0
(game / '_shot.req').touch()
while time.monotonic() < deadline:
    if shot.exists() and shot.stat().st_mtime_ns > previous:
        shutil.copy2(shot, evidence / 'installed-menu.png')
        print(evidence / 'installed-menu.png')
        break
    time.sleep(.25)
else:
    raise SystemExit('Fresh installed-app capture timed out.')
