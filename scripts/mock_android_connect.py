#!/usr/bin/env python3
"""
Mock Android Connect Server for macOS AndroidConnect Menu Bar App.
Matches Untitled Project/Models/BridgePackets.swift wire protocol verbatim.

- Runs WebSocket server on port 8989 at /bridge (pure Python standard library, zero pip deps)
- Advertises _androidconnect._tcp via macOS dns-sd
- Provides interactive terminal commands: battery, notif, otp, call, clip, help, quit
- Fully hardened input parsing to prevent crashes on mistyped commands.
"""

import asyncio
import base64
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import time
import uuid

PORT = 8989
ENDPOINT_PATH = "/bridge"
SERVICE_NAME = "Mock Moto G52"
SERVICE_TYPE = "_androidconnect._tcp"

active_connections = set()
dns_sd_proc = None
current_call = None


def make_envelope(msg_type: str, payload: dict) -> dict:
    return {
        "type": msg_type,
        "timestamp": int(time.time()),
        "payload": payload
    }


def encode_websocket_frame(text: str) -> bytes:
    payload = text.encode("utf-8")
    length = len(payload)
    header = bytearray([0x81])  # FIN + opcode 1 (text)
    if length <= 125:
        header.append(length)
    elif length <= 65535:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    return bytes(header) + payload


async def broadcast_envelope(envelope: dict):
    if not active_connections:
        print("⚠️  No Mac client connected yet. Connect from the menu bar app first.")
        return
    raw_json = json.dumps(envelope)
    frame = encode_websocket_frame(raw_json)
    for writer in list(active_connections):
        try:
            writer.write(frame)
            await writer.drain()
        except Exception as e:
            active_connections.discard(writer)
    print(f"➡️  Sent [{envelope['type']}]: {json.dumps(envelope['payload'], indent=2)}")


def handle_incoming_envelope(envelope: dict):
    msg_type = envelope.get("type")
    payload = envelope.get("payload", {})

    if msg_type == "NOTIFICATION_REPLY":
        print(f"\n💬 [Mac Inline Reply Received]")
        print(f"   Notification ID: {payload.get('notificationId')}")
        print(f"   Reply Text: \"{payload.get('replyText')}\"")
        sys.stdout.write("android> ")
        sys.stdout.flush()

    elif msg_type == "CALL_ACTION":
        action = payload.get("action")
        call_id = payload.get("callId")
        phone_number = payload.get("phoneNumber")
        print(f"\n📞 [Mac Call Action Received]: {action}")
        if call_id:
            print(f"   Call ID: {call_id}")
        if phone_number:
            print(f"   Dialing Number: {phone_number}")

        global current_call
        if action == "ANSWER":
            if current_call:
                current_call["status"] = "ACTIVE"
                asyncio.create_task(broadcast_envelope(make_envelope("CALL_STATE", current_call)))
        elif action in ("REJECT", "HANGUP"):
            if current_call:
                current_call["status"] = "ENDED"
                asyncio.create_task(broadcast_envelope(make_envelope("CALL_STATE", current_call)))
                current_call = None
        elif action == "HOLD":
            if current_call:
                current_call["status"] = "HELD"
                asyncio.create_task(broadcast_envelope(make_envelope("CALL_STATE", current_call)))
        elif action == "UNHOLD":
            if current_call:
                current_call["status"] = "ACTIVE"
                asyncio.create_task(broadcast_envelope(make_envelope("CALL_STATE", current_call)))
        elif action == "DIAL":
            current_call = {
                "callId": str(uuid.uuid4()),
                "phoneNumber": phone_number or "Unknown",
                "contactName": "Outgoing Call",
                "direction": "OUTGOING",
                "status": "ACTIVE",
                "durationSeconds": 0
            }
            asyncio.create_task(broadcast_envelope(make_envelope("CALL_STATE", current_call)))

        sys.stdout.write("android> ")
        sys.stdout.flush()

    elif msg_type == "CLIPBOARD":
        text = payload.get("text", "")
        source = payload.get("source", "")
        print(f"\n📋 [Mac Clipboard Received] (source: {source})")
        print(f"   Content: \"{text}\"")
        sys.stdout.write("android> ")
        sys.stdout.flush()

    elif msg_type == "RING_PHONE":
        duration = payload.get("durationSeconds", 10)
        print(f"\n🔔 [Find My Phone Triggered from Mac!]")
        print(f"   Ringing phone at max volume for {duration} seconds... 🎵📱")
        sys.stdout.write("android> ")
        sys.stdout.flush()

    elif msg_type == "PING":
        pong = make_envelope("PONG", {})
        asyncio.create_task(broadcast_envelope(pong))

    elif msg_type == "PONG":
        pass


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    request_line = await reader.readline()
    if not request_line:
        writer.close()
        return

    req_parts = request_line.decode("utf-8", errors="ignore").strip().split(" ")
    if len(req_parts) < 2 or req_parts[0] != "GET":
        writer.close()
        return

    path = req_parts[1]
    if path != ENDPOINT_PATH:
        writer.write(b"HTTP/1.1 404 Not Found\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    headers = {}
    while True:
        line = await reader.readline()
        if not line or line == b"\r\n" or line == b"\n":
            break
        header_str = line.decode("utf-8", errors="ignore").strip()
        if ":" in header_str:
            k, v = header_str.split(":", 1)
            headers[k.strip().lower()] = v.strip()

    sec_key = headers.get("sec-websocket-key")
    if not sec_key:
        writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    # Compute Sec-WebSocket-Accept
    guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    accept_val = base64.b64encode(hashlib.sha1((sec_key + guid).encode("utf-8")).digest()).decode("utf-8")

    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_val}\r\n\r\n"
    )
    writer.write(response.encode("utf-8"))
    await writer.drain()

    active_connections.add(writer)
    peer = writer.get_extra_info("peername")
    print(f"\n✅ [Mac Client Connected from {peer}]")

    # Send initial telemetry immediately upon connection
    init_telemetry = make_envelope("TELEMETRY", {
        "batteryPercent": 82,
        "isCharging": False,
        "signalStrength": 4,
        "networkType": "WiFi",
        "storageFreeMB": 48200
    })
    try:
        writer.write(encode_websocket_frame(json.dumps(init_telemetry)))
        await writer.drain()
    except Exception:
        pass

    sys.stdout.write("android> ")
    sys.stdout.flush()

    try:
        while True:
            head = await reader.read(2)
            if len(head) < 2:
                break
            b1, b2 = head[0], head[1]
            opcode = b1 & 0x0F
            is_masked = (b2 & 0x80) != 0
            payload_len = b2 & 0x7F

            if payload_len == 126:
                ext = await reader.read(2)
                payload_len = struct.unpack("!H", ext)[0]
            elif payload_len == 127:
                ext = await reader.read(8)
                payload_len = struct.unpack("!Q", ext)[0]

            mask_key = b""
            if is_masked:
                mask_key = await reader.read(4)

            payload_data = await reader.readexactly(payload_len)
            if is_masked:
                payload_data = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload_data))

            if opcode == 0x8:  # Close
                break
            elif opcode == 0x9:  # Ping
                pong_frame = bytearray([0x8A, len(payload_data)]) + payload_data
                writer.write(pong_frame)
                await writer.drain()
            elif opcode == 0x1:  # Text
                text = payload_data.decode("utf-8", errors="ignore")
                try:
                    envelope = json.loads(text)
                    handle_incoming_envelope(envelope)
                except Exception as e:
                    print(f"\n⚠️  Error parsing client JSON: {e}")
    except Exception:
        pass
    finally:
        active_connections.discard(writer)
        print("\n❌ [Mac Client Disconnected]")
        sys.stdout.write("android> ")
        sys.stdout.flush()


def start_mdns_advertisement():
    global dns_sd_proc
    try:
        # Advertise using macOS dns-sd CLI
        dns_sd_proc = subprocess.Popen(
            ["dns-sd", "-R", SERVICE_NAME, SERVICE_TYPE, "local", str(PORT)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        print(f"📡 Bonjour advertising registered: '{SERVICE_NAME}' ({SERVICE_TYPE}) on port {PORT}")
    except Exception as e:
        print(f"⚠️  Could not start dns-sd advertisement: {e}")


def print_help():
    print("""
Available Commands:
  battery [pct] [charging: 0|1]   - Send battery telemetry (e.g. `battery 65 1` or `battery 90`)
  notif <app> <title> <body>      - Send notification (e.g. `notif WhatsApp Alice "See you at 5!"`)
  otp [code]                      - Send OTP SMS notification (e.g. `otp 482910`)
  call incoming [name] [number]   - Trigger incoming call (e.g. `call incoming "John Doe" 555-1234`)
  call active                     - Transition call to active (talking)
  call end                        - End current call
  clip <text>                     - Send clipboard text from Android to Mac
  help                            - Show this command list
  quit / exit                     - Stop mock server
""")


async def command_loop():
    loop = asyncio.get_running_loop()
    print_help()

    while True:
        sys.stdout.write("android> ")
        sys.stdout.flush()
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        cmd_str = line.strip()
        if not cmd_str:
            continue

        parts = cmd_str.split()
        cmd = parts[0].lower()

        if cmd in ("quit", "exit"):
            print("Shutting down...")
            if dns_sd_proc:
                dns_sd_proc.terminate()
            os._exit(0)

        elif cmd == "help":
            print_help()

        elif cmd == "battery":
            try:
                pct = int(parts[1]) if len(parts) > 1 else 75
                if not (0 <= pct <= 100):
                    print("⚠️  Battery percent must be between 0 and 100.")
                    continue
                is_charging = (int(parts[2]) == 1) if len(parts) > 2 else False
                telemetry = make_envelope("TELEMETRY", {
                    "batteryPercent": pct,
                    "isCharging": is_charging,
                    "signalStrength": 4,
                    "networkType": "5G",
                    "storageFreeMB": 45120
                })
                await broadcast_envelope(telemetry)
            except (ValueError, IndexError):
                print("⚠️  Invalid battery arguments. Usage: battery [pct: 0-100] [charging: 0|1]")

        elif cmd == "notif":
            try:
                if len(parts) >= 4:
                    app = parts[1]
                    title = parts[2]
                    body = " ".join(parts[3:])
                elif len(parts) == 1:
                    app = "Slack"
                    title = "Sarah Connor"
                    body = "The deployment succeeded! Check your terminal."
                else:
                    print("⚠️  Usage: notif <app> <title> <body> (or simply `notif` for default)")
                    continue

                notif = make_envelope("NOTIFICATION", {
                    "id": str(uuid.uuid4()),
                    "appName": app,
                    "title": title,
                    "body": body,
                    "isOTP": False,
                    "otpCode": None,
                    "postedAt": int(time.time())
                })
                await broadcast_envelope(notif)
            except Exception as e:
                print(f"⚠️  Error sending notification: {e}. Usage: notif <app> <title> <body>")

        elif cmd == "otp":
            try:
                code = parts[1] if len(parts) > 1 else "654321"
                notif = make_envelope("NOTIFICATION", {
                    "id": str(uuid.uuid4()),
                    "appName": "Messages",
                    "title": "Bank Verification",
                    "body": f"Your verification code is {code}. Do not share this code.",
                    "isOTP": True,
                    "otpCode": code,
                    "postedAt": int(time.time())
                })
                await broadcast_envelope(notif)
                print(f"🔑 OTP Code {code} sent. If OTP Auto-Copy is on, Mac clipboard now has {code}!")
            except Exception as e:
                print(f"⚠️  Error sending OTP: {e}. Usage: otp [code]")

        elif cmd == "call":
            global current_call
            try:
                sub = parts[1].lower() if len(parts) > 1 else "incoming"
                if sub == "incoming":
                    name = parts[2] if len(parts) > 2 else "Alex Smith"
                    number = parts[3] if len(parts) > 3 else "+1 (555) 987-6543"
                    current_call = {
                        "callId": str(uuid.uuid4()),
                        "phoneNumber": number,
                        "contactName": name,
                        "direction": "INCOMING",
                        "status": "RINGING",
                        "durationSeconds": None
                    }
                    await broadcast_envelope(make_envelope("CALL_STATE", current_call))
                    print(f"📞 Incoming call HUD should now appear on your Mac!")
                elif sub == "active":
                    if not current_call:
                        current_call = {
                            "callId": str(uuid.uuid4()),
                            "phoneNumber": "+1 (555) 987-6543",
                            "contactName": "Alex Smith",
                            "direction": "INCOMING",
                            "status": "ACTIVE",
                            "durationSeconds": 0
                        }
                    else:
                        current_call["status"] = "ACTIVE"
                        current_call["durationSeconds"] = 0
                    await broadcast_envelope(make_envelope("CALL_STATE", current_call))
                elif sub == "end":
                    if current_call:
                        current_call["status"] = "ENDED"
                        await broadcast_envelope(make_envelope("CALL_STATE", current_call))
                        current_call = None
                    else:
                        end_payload = {
                            "callId": str(uuid.uuid4()),
                            "phoneNumber": "+1 (555) 987-6543",
                            "contactName": "Alex Smith",
                            "direction": "INCOMING",
                            "status": "ENDED",
                            "durationSeconds": 45
                        }
                        await broadcast_envelope(make_envelope("CALL_STATE", end_payload))
                    print("📞 Call ended.")
                else:
                    print("⚠️  Invalid call subcommand. Usage: call incoming [name] [number] | call active | call end")
            except (ValueError, IndexError, Exception) as e:
                print(f"⚠️  Error processing call command: {e}. Usage: call incoming | call active | call end")

        elif cmd == "clip":
            try:
                text = " ".join(parts[1:]) if len(parts) > 1 else "Hello from Moto G52 clipboard!"
                clip = make_envelope("CLIPBOARD", {
                    "text": text,
                    "source": "ANDROID"
                })
                await broadcast_envelope(clip)
                print(f"📋 Copied to Mac clipboard: \"{text}\"")
            except Exception as e:
                print(f"⚠️  Error sending clipboard: {e}. Usage: clip <text>")

        else:
            print(f"Unknown command: '{cmd}'. Type 'help' for options.")


async def main():
    start_mdns_advertisement()
    server = await asyncio.start_server(handle_client, "0.0.0.0", PORT)
    print(f"🚀 Mock Android WebSocket Server running on ws://0.0.0.0:{PORT}{ENDPOINT_PATH}")
    print("=" * 60)

    try:
        await command_loop()
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
    finally:
        if dns_sd_proc:
            dns_sd_proc.terminate()
        server.close()
        await server.wait_closed()


if __name__ == "__main__":
    def sig_handler(sig, frame):
        if dns_sd_proc:
            dns_sd_proc.terminate()
        os._exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        if dns_sd_proc:
            dns_sd_proc.terminate()
