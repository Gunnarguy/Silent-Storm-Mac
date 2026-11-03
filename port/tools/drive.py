#!/usr/bin/env python3
"""Drive a hidden test run of the engine step by step, waiting for the engine instead of sleeping blindly.

Usage: drive.py <test app> <game dir> <out dir> <step>...
  steps:  wait:<regex>[:<count>]   wait (120 s max) until the run log matches <regex> <count> times
          cmd:<console command>    write a line into _s2cmd.txt
          click:<x>,<y>            move, pause, press and release at window pixels (1280x800 window)
          key:<name>               key press through the input hook
          sleep:<seconds>
          shot:<name>              back-buffer screenshot into <out dir>/<name>.png
          final:<name>             the displayed frame (after sharpening and grading) into <out dir>/<name>.png
          raw:<line>               a line written into _s2cmd.txt exactly as the hub writes it
          input:<a;b;...>          lines for the input hook (_input.txt), ';' separated
The app must not carry the game's bundle identifier. Sound is muted through a
throwaway defaults suite. Exit code is the engine's.
"""
import os, re, subprocess, sys, time

def main():
    app, game, out = sys.argv[1:4]
    steps = sys.argv[4:]
    os.makedirs(out, exist_ok=True)
    suite = "com.silentstorm.drive"
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    if os.environ.get("S2_DRIVE_DEFAULTS"):   # measure with a copy of a real player's settings
        subprocess.run(["defaults", "import", suite, os.environ["S2_DRIVE_DEFAULTS"]], check=True)
    subprocess.run(["defaults", "write", suite, "s2.masterVolume", "-float", "0"], check=True)
    subprocess.run(["defaults", "write", suite, "s2.pauseInBackground", "-int", "0"], check=True)
    for f in ("_shot.png", "_s2cmd.txt", "_input.txt"):
        try: os.unlink(os.path.join(game, f))
        except FileNotFoundError: pass
    env = dict(os.environ, S2_HEADLESS="1", S2_NO_ACTIVATE="1", S2_HEADLESS_PRESENT="1",
               S2_LOG_RESOURCES="1", S2_NO_AUTOPLAY="1", S2_TEST_DEFAULTS_SUITE=suite)
    log_path = os.path.join(out, "run.log")
    log = open(log_path, "wb")
    proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/Silent Storm"), "--game-dir", game, "-windowed"],
                            stdout=log, stderr=subprocess.STDOUT, env=env)
    def put(name, text):
        # atomic: the engine polls these files every frame and deletes them after reading, so a plain
        # open-truncate-write let it read an empty file now and then (a lost command about one run in three)
        tmp = os.path.join(game, name + ".tmp")
        with open(tmp, "w") as f: f.write(text)
        os.replace(tmp, os.path.join(game, name))
    def logtext():
        with open(log_path, "rb") as f: return f.read().decode("latin-1")
    def wait(pattern, count=1, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if len(re.findall(pattern, logtext())) >= count: return True
            if proc.poll() is not None: return False
            time.sleep(0.5)
        print(f"TIMEOUT waiting for {pattern!r} x{count}", flush=True); return False
    try:
        steps_log = open(os.path.join(out, "steps.log"), "w")
        for step in steps:
            kind, _, arg = step.partition(":")
            steps_log.write(f"{time.strftime('%H:%M:%S')} log-line {logtext().count(chr(10))} step {step}\n"); steps_log.flush()
            if kind == "wait":
                pat, _, cnt = arg.rpartition(":")
                if not pat: pat, cnt = arg, "1"
                ok = wait(pat, int(cnt)); print(f"wait {pat!r} x{cnt}: {'ok' if ok else 'FAILED'}", flush=True)
                time.sleep(3)
            elif kind == "cmd":
                put("_s2cmd.txt", "cmd " + arg + "\n"); time.sleep(1)   # the hook's console form
            elif kind == "click":
                x, y = arg.split(",")
                put("_input.txt", f"move {x} {y}\nwait 20\nclick {x} {y}\nwait 5\n"); time.sleep(3)
            elif kind == "key":
                put("_input.txt", f"key {arg}\n"); time.sleep(2)
            elif kind == "final":   # the frame after sharpening and grading, what goes to the display
                p = os.path.join(game, "_shotfinal.png")
                try: os.unlink(p)
                except FileNotFoundError: pass
                open(os.path.join(game, "_shotfinal.req"), "w").close()
                for _ in range(40):
                    if os.path.exists(p): break
                    time.sleep(0.25)
                if os.path.exists(p): os.replace(p, os.path.join(out, arg + ".png"))
            elif kind == "raw":   # a line exactly as the hub writes it
                put("_s2cmd.txt", arg + "\n"); time.sleep(1)
            elif kind == "input":
                put("_input.txt", arg.replace(";", "\n") + "\n"); time.sleep(0.2)
            elif kind == "sleep":
                time.sleep(float(arg))
            elif kind == "shot":
                p = os.path.join(game, "_shot.png")
                open(os.path.join(game, "_shot.req"), "w").close()
                for _ in range(40):
                    if os.path.exists(p): break
                    time.sleep(0.5)
                if os.path.exists(p): os.replace(p, os.path.join(out, arg + ".png")); print(f"shot {arg}", flush=True)
                else: print(f"shot {arg}: none", flush=True)
            if proc.poll() is not None:
                print(f"engine exited early with {proc.returncode}", flush=True); break
    finally:
        if proc.poll() is None:
            put("_s2cmd.txt", "quit\n")
            try: proc.wait(20)
            except subprocess.TimeoutExpired: proc.kill()
        subprocess.run(["defaults", "delete", suite], capture_output=True)
    print(f"exit {proc.returncode}")
    return proc.returncode or 0

if __name__ == "__main__":
    sys.exit(main())
