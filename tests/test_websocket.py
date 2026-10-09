"""Execute production PowerShell functions against a local OBS v5 test server."""
import asyncio
import base64
import hashlib
import json
import logging
import os
from pathlib import Path
import sys
import websockets

PASSWORD = "fixture-only-password"
SALT = "fixture-salt"
CHALLENGE = "fixture-challenge"
MIC = "Studio microphone"
state = {"muted": False, "exists": True, "connections": 0, "requests": 0, "auth": True}

def auth():
    secret = base64.b64encode(hashlib.sha256((PASSWORD + SALT).encode()).digest())
    return base64.b64encode(hashlib.sha256(secret + CHALLENGE.encode()).digest()).decode()

async def handler(ws):
    state["connections"] += 1
    hello = {"obsWebSocketVersion": "5.0.0", "rpcVersion": 1}
    if state["auth"]:
        hello["authentication"] = {"salt": SALT, "challenge": CHALLENGE}
    await ws.send(json.dumps({"op": 0, "d": hello}))
    try:
        identify = json.loads(await ws.recv())
        if identify.get("op") != 1 or (state["auth"] and identify["d"].get("authentication") != auth()):
            await ws.close(code=4009, reason="Authentication failed")
            return
        await ws.send(json.dumps({"op": 2, "d": {"negotiatedRpcVersion": 1}}))
        async for raw in ws:
            request = json.loads(raw)["d"]
            state["requests"] += 1
            name = request["requestType"]
            data = request.get("requestData", {})
            result = {}; code = 100; comment = ""
            if name == "GetInputList":
                result = {"inputs": [{"inputName": "Video only", "inputKind": "image_source"}] +
                    ([{"inputName": MIC, "inputKind": "wasapi_input_capture"}] if state["exists"] else [])}
            elif name in ("GetInputMute", "SetInputMute"):
                if data.get("inputName") == "Video only":
                    code = 604; comment = "Input does not support audio"
                elif not state["exists"] or data.get("inputName") != MIC:
                    code = 600; comment = "Input not found"
                elif name == "GetInputMute": result = {"inputMuted": state["muted"]}
                else: state["muted"] = bool(data["inputMuted"])
            elif name == "_testRemoveInput": state["exists"] = False
            elif name == "_testRestoreInput": state["exists"] = True
            elif name == "_testSetExternal": state["muted"] = bool(data["muted"])
            elif name == "_testDropConnection": pass
            elif name == "_testAuthOff": state["auth"] = False
            else: raise AssertionError(f"Unexpected request: {name}")
            await ws.send(json.dumps({"op": 7, "d": {"requestType": name, "requestId": request["requestId"],
                "requestStatus": {"result": code == 100, "code": code, "comment": comment}, "responseData": result}}))
            if name == "_testDropConnection":
                await ws.close(code=1001, reason="Fixture OBS restart")
                return
    except websockets.exceptions.ConnectionClosed:
        pass

async def main():
    # The production reachability check intentionally opens a TCP connection
    # without a WebSocket handshake before the real client connection.
    logging.getLogger("websockets.server").setLevel(logging.CRITICAL)
    executable = os.environ["APEIRON_TEST_PWSH"]
    script = Path(__file__).with_name("test_websocket.ps1")
    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        args = [executable, "-NoLogo", "-NoProfile", "-File", str(script), "-Port", str(port)]
        if os.environ.get("APEIRON_TEST_SOURCE"):
            args += ["-Source", os.environ["APEIRON_TEST_SOURCE"]]
        process = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT)
        output, _ = await process.communicate()
        sys.stdout.write(output.decode())
        if process.returncode:
            raise SystemExit(process.returncode)
    print(f"OBS v5 fixture: {state['connections']} connections; {state['requests']} real WebSocket requests.")

if __name__ == "__main__":
    asyncio.run(main())
