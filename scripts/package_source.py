"""Package the source tree without local SDK paths, secrets or build caches."""
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
version = next(line.split(":", 1)[1].strip().split("+")[0]
               for line in (root / "pubspec.yaml").read_text(encoding="utf-8").splitlines()
               if line.startswith("version:"))
destination = root / "dist" / f"ykt_helper-{version}-source.zip"
destination.parent.mkdir(exist_ok=True)
paths = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    cwd=root,
).decode("utf-8").split("\0")
with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(set(filter(None, paths))):
        source = (root / name).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            continue
        archive.write(source, "ykt_helper/" + name)
print(destination)
