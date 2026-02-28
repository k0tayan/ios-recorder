#!/usr/bin/env python3
"""
iOS App Recorder - Live Stream Client

Starts MPEG-TS streaming from the device and opens ffplay for playback.
Ctrl+C to stop streaming and exit.

Usage:
  python3 stream_client.py                  # Start streaming & open ffplay
  python3 stream_client.py --no-play        # Start streaming only (no ffplay)
  python3 stream_client.py stop             # Stop streaming
  python3 stream_client.py --record         # Stream + record simultaneously
"""

import socket
import subprocess
import signal
import sys
import argparse
import time

DEVICE_IP = "192.168.1.145"
CONTROL_PORT = 8190
STREAM_PORT = 8191


def send_command(command, host=DEVICE_IP, port=CONTROL_PORT):
    """Send a command via TCP and return the response."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect((host, port))
        sock.sendall((command + "\n").encode())
        return sock.recv(4096).decode().strip()
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(description="iOS App Recorder - Live Stream Client")
    parser.add_argument("action", nargs="?", default="start",
                        choices=["start", "stop", "status"],
                        help="start (default) / stop / status")
    parser.add_argument("--no-play", action="store_true",
                        help="Don't launch ffplay (streaming only)")
    parser.add_argument("--record", action="store_true",
                        help="Also start recording simultaneously")
    parser.add_argument("--host", default=DEVICE_IP,
                        help=f"Device IP (default: {DEVICE_IP})")
    parser.add_argument("--port", type=int, default=CONTROL_PORT,
                        help=f"Control port (default: {CONTROL_PORT})")
    parser.add_argument("--stream-port", type=int, default=STREAM_PORT,
                        help=f"Stream port (default: {STREAM_PORT})")
    parser.add_argument("--low-latency", action="store_true", default=True,
                        help="Use low-latency ffplay flags (default)")
    parser.add_argument("--ffplay-args", default="",
                        help="Extra arguments to pass to ffplay")
    args = parser.parse_args()

    host = args.host
    port = args.port
    stream_port = args.stream_port

    # Handle stop/status subcommands
    if args.action == "stop":
        print("[*] Sending: STREAM STOP")
        resp = send_command("STREAM STOP", host, port)
        print(f"[*] Response: {resp}")
        sys.exit(0 if resp.startswith("OK") else 1)

    if args.action == "status":
        print("[*] Sending: STATUS")
        resp = send_command("STATUS", host, port)
        print(f"[*] Response: {resp}")
        sys.exit(0 if resp.startswith("OK") else 1)

    # --- Start streaming ---
    try:
        print(f"[*] Sending: STREAM START")
        resp = send_command("STREAM START", host, port)
        print(f"[*] Response: {resp}")
        if not resp.startswith("OK"):
            sys.exit(f"ERROR: {resp}")
    except ConnectionRefusedError:
        sys.exit(f"ERROR: Connection refused ({host}:{port}). Is the app running?")

    # Also start recording if requested
    if args.record:
        print("[*] Sending: START (recording)")
        resp = send_command("START", host, port)
        print(f"[*] Response: {resp}")

    stream_url = f"tcp://{host}:{stream_port}"

    if args.no_play:
        print(f"\n[*] Streaming started. Connect with:")
        print(f"    ffplay {stream_url}")
        print(f"\n[*] Press Ctrl+C to stop streaming")
    else:
        print(f"\n[*] Launching ffplay: {stream_url}")
        print(f"[*] Close ffplay or press Ctrl+C to stop streaming")

    # Build ffplay command
    ffplay_cmd = None
    if not args.no_play:
        ffplay_cmd = [
            "ffplay",
            "-fflags", "nobuffer+discardcorrupt",
            "-flags", "low_delay",
            "-framedrop",
            "-analyzeduration", "500000",   # 500ms
            "-probesize", "500000",         # 500KB
            "-sync", "audio",
            "-af", "aresample=async=1",
            stream_url,
        ]
        if args.ffplay_args:
            ffplay_cmd.extend(args.ffplay_args.split())

    ffplay_proc = None

    def cleanup(signum=None, frame=None):
        nonlocal ffplay_proc
        print("\n[*] Stopping...")

        # Stop ffplay
        if ffplay_proc and ffplay_proc.poll() is None:
            ffplay_proc.terminate()
            try:
                ffplay_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ffplay_proc.kill()

        # Stop streaming
        try:
            print("[*] Sending: STREAM STOP")
            resp = send_command("STREAM STOP", host, port)
            print(f"[*] Response: {resp}")
        except Exception as e:
            print(f"[!] Failed to stop streaming: {e}")

        # Stop recording if we started it
        if args.record:
            try:
                print("[*] Sending: STOP (recording)")
                resp = send_command("STOP", host, port)
                print(f"[*] Response: {resp}")
            except Exception as e:
                print(f"[!] Failed to stop recording: {e}")

        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    if ffplay_cmd:
        # Launch ffplay with a short delay for the stream to stabilize
        time.sleep(0.3)
        try:
            ffplay_proc = subprocess.Popen(
                ffplay_cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            print("[!] ffplay not found. Install ffmpeg and ensure ffplay is in PATH.")
            print(f"[*] You can manually connect: ffplay {stream_url}")
            print("[*] Press Ctrl+C to stop streaming")

        # Wait for ffplay to exit
        if ffplay_proc:
            ffplay_proc.wait()
            print("\n[*] ffplay exited")
            cleanup()
    else:
        # No ffplay, just wait for Ctrl+C
        while True:
            time.sleep(1)


if __name__ == "__main__":
    main()
