"""Package a verified device Release app after flutter build ios --no-codesign."""
from pathlib import Path
import argparse
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def package(root: Path, app: Path, output: Path) -> Path:
    if sys.platform != "darwin":
        raise SystemExit("Unsigned IPA packaging requires macOS/Xcode.")
    match = re.search(r"^version:\s*([^+\s]+)\+([0-9]+)\s*$", (root / "pubspec.yaml").read_text(), re.M)
    if not match:
        raise SystemExit("pubspec.yaml must contain a version and build number.")
    version, build = match.groups()
    if not app.is_dir() or app.suffix != ".app":
        raise SystemExit("A successfully built device Release .app is required.")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    assert info["CFBundleIdentifier"] == "com.furryzirui.ykt-helper", "Unexpected Bundle ID"
    assert info["CFBundleShortVersionString"] == version, "Version mismatch"
    assert str(info["CFBundleVersion"]) == build, "Build number mismatch"
    assert info.get("DTPlatformName") == "iphoneos", "Device build required, not a simulator"
    binary = app / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).strip()
    assert architectures.split() == ["arm64"], f"Expected arm64 device executable, got {architectures}"
    signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True)
    assert signature.returncode != 0, "The app is signed; rebuild using --no-codesign"
    assert not (app / "embedded.mobileprovision").exists(), "Unexpected provisioning profile"

    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"ykt_helper-{version}-ios-unsigned.ipa"
    with tempfile.TemporaryDirectory(prefix="ykt-helper-ipa-") as staging:
        payload = Path(staging) / "Payload"
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        # ditto preserves executable permissions, resource forks and symlinks.
        subprocess.run(["ditto", "-c", "-k", "--keepParent", "--norsrc", str(payload), str(destination)], check=True)
    with zipfile.ZipFile(destination) as archive:
        assert archive.testzip() is None, "IPA archive integrity failed"
        expected = f"Payload/{app.name}/"
        assert all(name.startswith(expected) or name == "Payload/" for name in archive.namelist())
        packaged_info = plistlib.loads(archive.read(expected + "Info.plist"))
        assert packaged_info["CFBundleIdentifier"] == info["CFBundleIdentifier"]
        assert packaged_info["CFBundleShortVersionString"] == version
        assert expected + "embedded.mobileprovision" not in archive.namelist()

    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    checksums = output / f"SHA256SUMS-ios-{version}.txt"
    checksums.write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
    metadata = output / f"BUILD-INFO-ios-{version}.txt"
    metadata.write_text(
        f"ykt_helper {version}+{build}\n"
        f"Bundle ID: {info['CFBundleIdentifier']}\n"
        f"Minimum iOS: {info.get('MinimumOSVersion', 'unknown')}\n"
        "Platform: iphoneos arm64\n"
        "Signing: unsigned; requires user signing before device installation\n"
        "Build: flutter build ios --release --no-codesign\n"
        "Device runtime behavior was not tested during packaging.\n"
        f"SHA256: {digest}\n"
        f"Size: {destination.stat().st_size}\n",
        encoding="utf-8",
    )
    print(f"Verified unsigned IPA: {destination.name}, {destination.stat().st_size} bytes, arm64, SHA256 {digest}")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/ios/iphoneos/Runner.app"))
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[2]
    os.chdir(workspace)
    package(workspace, args.app.resolve(), args.output.resolve())
