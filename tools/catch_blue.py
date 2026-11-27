#!/usr/bin/env python3
"""Catch the M245T01 in its blue "No Signal" phase and halt it there.

Loop: m1ddc set input 17 (HDMI, nothing plugged) -> watch the workbench camera's view of the
monitor -> the moment it turns blue, halt the scaler over ISP and read the colour registers.
No blue within WATCH_S -> wait for the picture to return (Source=Auto falls back) and retry.
Only halts on blue, so a miss costs nothing.
"""
import os, subprocess, sys, threading, time

CROP = "600:350:1400:420"          # monitor face in the 3840x2160 workbench frame
WATCH_S, TRIES = 8.0, 10
RTD = os.path.expanduser("~/.local/bin/rtd-isp")
latest = {"t": 0.0, "rgb": (0, 0, 0)}


def camera():
    src = subprocess.Popen(["ssh", "-T", "frigate",
        "docker exec frigate curl -sN 'http://127.0.0.1:1984/api/stream.mjpeg?src=workbench_mjpeg'"],
        stdout=subprocess.PIPE)
    ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-f", "mjpeg", "-i", "-",
        "-vf", f"crop={CROP},scale=8:8", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        stdin=src.stdout, stdout=subprocess.PIPE)
    while (b := ff.stdout.read(192)) and len(b) == 192:
        latest["rgb"] = tuple(sum(b[i::3]) // 64 for i in range(3))
        latest["t"] = time.time()


def is_blue(rgb):
    r, g, b = rgb
    # camera sees the no-signal blue as ~(0,121,252); desktop content stays far below b=200
    return b > 200 and r < 40   # ponytail: fixed threshold; tune if room light changes


def ddc(*a):
    return subprocess.run(["m1ddc", *a], capture_output=True, text=True)


threading.Thread(target=camera, daemon=True).start()
while time.time() - latest["t"] > 1:
    time.sleep(0.2)
print("camera live, baseline rgb", latest["rgb"], flush=True)

for n in range(1, TRIES + 1):
    while ddc("get", "luminance").returncode != 0:      # wait for picture/DDC back
        time.sleep(0.5)
    time.sleep(2)
    print(f"try {n}: input -> HDMI", flush=True)
    ddc("set", "input", "17")
    t0, seen, hits = time.time(), [], 0
    while time.time() - t0 < WATCH_S:
        rgb = latest["rgb"]
        seen.append((round(time.time() - t0, 2), rgb))
        hits = hits + 1 if is_blue(rgb) else 0
        if hits >= 2:
            print(f"BLUE at +{time.time()-t0:.2f}s rgb={rgb} -> halting", flush=True)
            out = subprocess.run([RTD, "scaler", "r:28", "r:6C", "bg", "w:9F=07", "r:F0", "r:FC", "w:9F=00"],
                                 capture_output=True, text=True)
            print(out.stdout + out.stderr, flush=True)
            sys.exit(0)
        time.sleep(0.05)
    print("  no blue; colour trace:", seen[::10], flush=True)
print("gave up", flush=True)
