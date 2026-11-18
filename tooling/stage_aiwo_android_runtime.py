"""Stage the bundled ARM64 runtime from the matching, verified DSH Go APK."""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
from zipfile import ZipFile

from check_runtime_bundle import check_bundle, ROOT


ABI = "arm64-v8a"
ASSETS = PurePosixPath("assets/runtime")
MANIFEST = ASSETS / "manifest.json"


def copy_member(apk, member, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with apk.open(str(member)) as source, output.open("wb") as destination:
        shutil.copyfileobj(source, destination, length=1024 * 1024)


def stage(apk_path):
    bundle = ROOT / "runtime" / "out" / ABI
    with ZipFile(apk_path) as apk:
        manifest = json.loads(apk.read(str(MANIFEST)))
        if manifest.get("abi") != ABI:
            raise ValueError(f"Expected the {ABI} runtime")
        for entry in apk.infolist():
            if entry.is_dir() or not entry.filename.startswith(f"{ASSETS}/"):
                continue
            name = PurePosixPath(entry.filename)
            if ".." in name.parts or "\\" in entry.filename:
                raise ValueError(f"Invalid runtime asset path: {entry.filename!r}")
            copy_member(apk, name, bundle.joinpath(*name.parts))
        for name in manifest["jniLibs"]:
            if PurePosixPath(name).name != name or "\\" in name or not name.startswith("lib") or not name.endswith(".so"):
                raise ValueError(f"Invalid runtime library name: {name!r}")
            copy_member(apk, f"lib/{ABI}/{name}", bundle / "jniLibs" / ABI / name)
    check_bundle("arm64")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    stage(args.apk)
