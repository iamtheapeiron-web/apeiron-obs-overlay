"""Build the Windows GUI launcher with its exact embedded runtime."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--go", default="go")
    parser.add_argument("--windres", default="x86_64-w64-mingw32-windres")
    parser.add_argument("--preprocessor")
    parser.add_argument("--output", default="dist/APEIRON OBS Overlay.exe")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    launcher = root / "launcher"
    payload = launcher / "payload"
    payload.mkdir(exist_ok=True)
    for name in ("overlay.ps1", "APEIRON.ico", "APEIRON_icon.png"):
        shutil.copyfile(root / "runtime" / name, payload / name)
    resource = [args.windres, "-J", "rc", "-O", "coff", "-i", "app.rc", "-o", "resource_windows_amd64.syso"]
    if args.preprocessor:
        resource.insert(1, "--preprocessor=" + args.preprocessor)
    subprocess.run(resource, cwd=launcher, check=True)
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, GOOS="windows", GOARCH="amd64", CGO_ENABLED="0")
    subprocess.run([args.go, "build", "-buildvcs=false", "-trimpath",
        "-ldflags=-H windowsgui -s -w", "-o", str(output), "."], cwd=launcher, env=env, check=True)
    print(output)

if __name__ == "__main__":
    main()
