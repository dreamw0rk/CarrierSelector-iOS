#!/usr/bin/env python3
"""Check the actual shipped IPA, including its Mach-O deployment requirement."""
import json
import plistlib
import struct
import sys
import zipfile


def main(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, "Damaged ZIP entry"
        names = set(archive.namelist())
        assert not any(part == "__MACOSX" or part == ".DS_Store" or part.startswith("._")
                       for name in names for part in name.split("/")), "macOS metadata included in IPA"
        prefix = "Payload/CarrierSelector.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["MinimumOSVersion"] == "26.0", "Unexpected plist minimum OS"
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            icon = info.get(key, {}).get("CFBundlePrimaryIcon", {})
            assert icon.get("CFBundleIconName") == "AppIcon", "Missing primary app icon"
            assert icon.get("CFBundleIconFiles"), "Missing compiled app icon files"
        assert prefix + "Assets.car" in archive.namelist(), "Missing compiled icon catalog"
        assert "_remotepairing-pairable-host._tcp" in info.get("NSBonjourServices", []), "Missing pairing Bonjour declaration"
        assert info["CFBundleIdentifier"] + ".pairing.*" in info.get("BGTaskSchedulerPermittedIdentifiers", []), "Background pairing identifier mismatch"
        assert "processing" in info.get("UIBackgroundModes", []), "Missing background processing mode"
        executable = archive.read(prefix + info["CFBundleExecutable"])
        magic, cpu, _, filetype, commands, _, _, _ = struct.unpack_from("<8I", executable)
        assert magic == 0xFEEDFACF and cpu == 0x100000C and filetype == 2, "Expected arm64 Mach-O executable"
        offset = 32
        found = False
        for _ in range(commands):
            command, size = struct.unpack_from("<II", executable, offset)
            assert size >= 8 and offset + size <= len(executable), "Invalid Mach-O load command"
            if command == 0x32:  # LC_BUILD_VERSION
                platform, minimum = struct.unpack_from("<II", executable, offset + 8)
                assert platform == 2, "Expected physical iOS platform"
                assert minimum == (26 << 16), "Mach-O requires a different iOS version"
                found = True
            offset += size
        assert found, "No LC_BUILD_VERSION found"
        for model in ("Library", "LibraryV2"):
            assert prefix + f"Library.momd/{model}.mom" in names, "Missing Core Data migration model"
        model_versions = plistlib.loads(archive.read(prefix + "Library.momd/VersionInfo.plist"))
        assert model_versions["NSManagedObjectModel_CurrentVersionName"] == "LibraryV2", "Wrong current Core Data model"
        for dependency in ("CarrierSelector", "idevice", "ZIPFoundation", "CarrierSIM"):
            assert archive.read(prefix + dependency + "-LICENSE.txt").strip(), "Missing dependency license"
        assert len(json.loads(archive.read(prefix + "apn.json"))) == 13
        profiles = json.loads(archive.read(prefix + "profiles.json"))
        assert len(profiles) > 1000
        capabilities = json.loads(archive.read(prefix + "profile-capabilities.json"))
        assert set(capabilities) == {p['path'] for p in profiles}, "Missing profile descriptions"
        research = json.loads(archive.read(prefix + "russia-research.json"))
        assert research['rules'] and research['sources'], "Missing Russia trial evidence"
        native = json.loads(archive.read(prefix + "native-profiles.json"))
        assert native['families'] and set(native['supportedSIMs']) == {p['path'] for p in profiles}, "Missing stock profile mapping"
        assert json.loads(archive.read(prefix + "models.json")), "Missing supported models"
        print("IPA verified: physical arm64 iOS 26.0+, matching Info.plist and Mach-O, resources present")


if __name__ == "__main__":
    main(sys.argv[1])
