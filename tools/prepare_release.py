#!/usr/bin/env python3
"""Name the verified IPA and produce a portable SHA-256 manifest."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="", help="Release tag, if this is a tagged build")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    ipa = root / "build/CarrierSelector-unsigned.ipa"
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read("Payload/CarrierSelector.app/Info.plist"))
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("IPA must contain an X.Y.Z release version")
    if args.tag and args.tag != f"v{version}":
        parser.error(f"Tag {args.tag!r} does not match IPA version {version}")
    destination = root / "build/release"
    destination.mkdir(exist_ok=True)
    output = destination / f"CarrierSelector-{version}-unsigned.ipa"
    shutil.copyfile(ipa, output)
    with output.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    (destination / "SHA256SUMS.txt").write_text(f"{digest}  {output.name}\n")
    print(f"Release artifact: {output.name}")


if __name__ == "__main__":
    main()
