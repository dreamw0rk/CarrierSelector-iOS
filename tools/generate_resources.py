#!/usr/bin/env python3
"""Generate native metadata from the pinned, verified upstream archive."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import zipfile
from profile_capabilities import extract_settings, merge_settings

ROOT = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1])
expected = 'f6dbfd8bb075f210ee25b9c38b46cb1f57ea4f5c3cb46f99a796054c7f4e4fad'
assert hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() == expected
out = ROOT / 'Resources'
out.mkdir(exist_ok=True)
profiles = []
capabilities = {}
native_sims = {}
with zipfile.ZipFile(archive) as z:
    catalog = json.loads(z.read('embedded_catalog/catalog.json'))
    models = {product: family['hardwares'] for family in catalog['families'] for product in family['products']}
    (out / 'models.json').write_text(json.dumps(models, indent=2))
    names = set(z.namelist())
    directories = {}
    for name in names:
        if '.bundle/' in name:
            directory, relative = name.split('.bundle/', 1)
            directories.setdefault(directory + '.bundle', []).append(relative)
    for directory, entries in sorted(directories.items()):
        if directory.rsplit('/', 1)[-1] in {'Default.bundle', 'DefaultBCAM.bundle', 'OtherKnown.bundle'}:
            continue
        if not {'Info.plist', 'carrier.plist', 'signatures/common.plist'} <= set(entries):
            continue
        info = plistlib.loads(z.read(directory + '/Info.plist'))
        if not str(info.get('CFBundleIdentifier', '')).startswith('com.apple.'):
            continue
        carrier = plistlib.loads(z.read(directory + '/carrier.plist'))
        native_sims[directory.removeprefix('embedded_catalog/')] = [v for v in carrier.get('SupportedSIMs', [])
            if isinstance(v, str) and re.fullmatch(r'[0-9]{5,6}', v)]
        variants = []
        for entry in sorted(entries):
            if entry.startswith('overrides_') and entry.endswith('.plist'):
                override = plistlib.loads(z.read(directory + '/' + entry))
                variants.append(extract_settings(merge_settings(carrier, override),
                                Path(entry).stem.removeprefix('overrides_').split('_')))
        capabilities[directory.removeprefix('embedded_catalog/')] = variants or [extract_settings(carrier, [])]
        supported = []
        if 'supported_devices.plist' in entries:
            for key, value in plistlib.loads(z.read(directory + '/supported_devices.plist')).items():
                if 'supported' in key.lower():
                    supported.extend(value if isinstance(value, list) else [value])
        profiles.append(dict(path=directory.removeprefix('embedded_catalog/'),
            name=str(info.get('CFBundleName', Path(directory).stem)) + ' · ' + str(carrier.get('CarrierName', '')),
            identifier=info['CFBundleIdentifier'], version=str(info['CFBundleVersion']),
            supported=[str(v) for v in supported],
            overrides=[Path(e).stem.removeprefix('overrides_').split('_') for e in sorted(entries)
                       if e.startswith('overrides_') and e.endswith('.plist')]))
(out / 'profiles.json').write_text(json.dumps(profiles, ensure_ascii=False, separators=(',', ':')))
(out / 'profile-capabilities.json').write_text(json.dumps(capabilities, ensure_ascii=False, separators=(',', ':')))
(out / 'native-profiles.json').write_text(json.dumps(dict(
    families=[dict(products=f['products'], hardwares=f['hardwares'], roots=[f['catalog_root']] + f.get('extra_roots', []))
              for f in catalog['families']], supportedSIMs=native_sims), separators=(',', ':')))
# APN reference data and third-party licenses are maintained separately in Resources.
print(f'{len(profiles)} profile variants')
