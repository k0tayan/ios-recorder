#!/usr/bin/env python3
"""
iOS App Recorder - Remote Control Client

Connects to the recorder's UNIX socket on the iPad via SSH socket forwarding.
Auto-discovers the sandbox socket path, starts/stops recording, and pulls files.

Usage:
  python3 recorder_client.py start                # Start recording
  python3 recorder_client.py stop                  # Stop and pull file
  python3 recorder_client.py stop --no-pull        # Stop without pulling
  python3 recorder_client.py status                # Check status
  python3 recorder_client.py cleanup               # Clean up tmp files
  python3 recorder_client.py set fps=60            # Change setting
  python3 recorder_client.py set resolution=1920x1440
"""

import socket
import subprocess
import sys
import os
import time
import argparse
import signal
import atexit

SSH_HOST = "ipad"
LOCAL_SOCK = "/tmp/ios_recorder_local.sock"
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "recordings")

_tunnel_proc = None


def cleanup():
    global _tunnel_proc
    if _tunnel_proc and _tunnel_proc.poll() is None:
        _tunnel_proc.terminate()
        _tunnel_proc.wait()
    if os.path.exists(LOCAL_SOCK):
        os.unlink(LOCAL_SOCK)


atexit.register(cleanup)
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))


def find_remote_socket():
    """Find the recorder socket in the app sandbox."""
    result = subprocess.run(
        ["ssh", SSH_HOST,
         "find /var/mobile/Containers/Data/Application -name rec.sock -type s 2>/dev/null"],
        capture_output=True, text=True, timeout=10
    )
    path = result.stdout.strip().split("\n")[0]
    if not path:
        sys.exit("ERROR: Socket not found. Is the app running with the tweak loaded?")
    return path


def open_tunnel(remote_sock):
    """Open SSH socket forwarding tunnel."""
    global _tunnel_proc

    if os.path.exists(LOCAL_SOCK):
        os.unlink(LOCAL_SOCK)

    _tunnel_proc = subprocess.Popen(
        ["ssh", "-N", "-L", f"{LOCAL_SOCK}:{remote_sock}", SSH_HOST],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    # Wait for socket to appear
    for _ in range(20):
        if os.path.exists(LOCAL_SOCK):
            return
        time.sleep(0.1)

    err = ""
    if _tunnel_proc.poll() is not None:
        err = _tunnel_proc.stderr.read().decode().strip()
    sys.exit(f"ERROR: SSH tunnel failed to start. {err}")


def send_command(command):
    """Send a command via the forwarded UNIX socket."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(30)
    try:
        sock.connect(LOCAL_SOCK)
        sock.sendall((command + "\n").encode())
        return sock.recv(4096).decode().strip()
    finally:
        sock.close()


def pull_file(remote_path):
    """Pull recording file from iPad via scp."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    local_path = os.path.join(OUTPUT_DIR, os.path.basename(remote_path))

    print(f"Pulling: {remote_path}")
    subprocess.run(
        ["scp", f"{SSH_HOST}:{remote_path}", local_path],
        check=True, timeout=300,
    )
    size_mb = os.path.getsize(local_path) / (1024 * 1024)
    print(f"Saved:   {local_path} ({size_mb:.1f} MB)")
    return local_path


def main():
    parser = argparse.ArgumentParser(description="iOS App Recorder - Remote Control")
    parser.add_argument("command", help="start / stop / status / set")
    parser.add_argument("params", nargs="*", help="Parameters (e.g. fps=60)")
    parser.add_argument("--no-pull", action="store_true", help="Don't pull file after stop")
    parser.add_argument("-o", "--output-dir", help="Output directory for recordings")
    args = parser.parse_args()

    global OUTPUT_DIR
    if args.output_dir:
        OUTPUT_DIR = args.output_dir

    # Build command string
    cmd = args.command.upper()
    if args.params:
        cmd += " " + " ".join(args.params)

    # Find socket and open tunnel
    print(f"[*] Finding recorder socket...")
    remote_sock = find_remote_socket()
    print(f"[*] Socket: {remote_sock}")

    print(f"[*] Opening SSH tunnel...")
    open_tunnel(remote_sock)

    # Send command
    print(f"[*] Sending: {cmd}")
    response = send_command(cmd)
    print(f"[*] Response: {response}")

    # Pull file after STOP
    if cmd == "STOP" and not args.no_pull and response.startswith("OK /"):
        remote_path = response[3:].strip()
        print()
        pull_file(remote_path)

    sys.exit(0 if response.startswith("OK") else 1)


if __name__ == "__main__":
    main()
