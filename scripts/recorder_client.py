#!/usr/bin/env python3
"""
iOS App Recorder - Remote Control Client

Connects directly to the recorder's TCP control server on the iPad.

Usage:
  python3 recorder_client.py start                # Start recording
  python3 recorder_client.py stop                  # Stop and pull file
  python3 recorder_client.py stop --no-pull        # Stop without pulling
  python3 recorder_client.py status                # Check status
  python3 recorder_client.py list                  # List recordings
  python3 recorder_client.py cleanup               # Clean up tmp files
  python3 recorder_client.py set fps=60            # Change setting
  python3 recorder_client.py set resolution=1920x1440
"""

import socket
import sys
import os
import argparse

DEVICE_IP = "192.168.1.145"
DEVICE_PORT = 8190
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "recordings")


def send_command(command, host=DEVICE_IP, port=DEVICE_PORT):
    """Send a command via TCP and return the response."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(30)
    try:
        sock.connect((host, port))
        sock.sendall((command + "\n").encode())
        return sock.recv(4096).decode().strip()
    finally:
        sock.close()


def pull_file(remote_path, host=DEVICE_IP, port=DEVICE_PORT):
    """Pull a file from the device via the PULL command."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    local_path = os.path.join(OUTPUT_DIR, os.path.basename(remote_path))

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(30)
    try:
        sock.connect((host, port))
        sock.sendall(f"PULL {remote_path}\n".encode())

        # Read header line byte by byte until \n
        header = b""
        while True:
            b = sock.recv(1)
            if not b:
                sys.exit("ERROR: Connection closed while reading header")
            if b == b"\n":
                break
            header += b

        header_str = header.decode().strip()
        if header_str.startswith("ERR"):
            sys.exit(f"ERROR: {header_str}")

        # Parse "OK <size>"
        file_size = int(header_str.split()[1])
        print(f"Pulling: {remote_path} ({file_size / (1024*1024):.1f} MB)")

        # Receive file data
        received = 0
        sock.settimeout(60)
        with open(local_path, "wb") as f:
            while received < file_size:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                f.write(chunk)
                received += len(chunk)

        if received != file_size:
            sys.exit(f"ERROR: Transfer incomplete ({received}/{file_size} bytes)")

        print(f"Saved:   {local_path} ({received / (1024*1024):.1f} MB)")
        return local_path
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(description="iOS App Recorder - Remote Control")
    parser.add_argument("command", help="start / stop / status / list / set / cleanup")
    parser.add_argument("params", nargs="*", help="Parameters (e.g. fps=60)")
    parser.add_argument("--no-pull", action="store_true", help="Don't pull file after stop")
    parser.add_argument("-o", "--output-dir", help="Output directory for recordings")
    parser.add_argument("--host", default=DEVICE_IP, help=f"Device IP (default: {DEVICE_IP})")
    parser.add_argument("--port", type=int, default=DEVICE_PORT, help=f"Device port (default: {DEVICE_PORT})")
    args = parser.parse_args()

    global OUTPUT_DIR
    if args.output_dir:
        OUTPUT_DIR = args.output_dir

    host = args.host
    port = args.port

    # Build command string
    cmd = args.command.upper()
    if args.params:
        cmd += " " + " ".join(args.params)

    try:
        # Send command
        print(f"[*] Sending: {cmd}")
        response = send_command(cmd, host, port)
        print(f"[*] Response: {response}")

        # Pull file after STOP
        if cmd == "STOP" and not args.no_pull and response.startswith("OK /"):
            remote_path = response[3:].strip()
            print()
            pull_file(remote_path, host, port)

    except ConnectionRefusedError:
        sys.exit(f"ERROR: Connection refused ({host}:{port}). Is the app running with the tweak loaded?")

    sys.exit(0 if response.startswith("OK") else 1)


if __name__ == "__main__":
    main()
