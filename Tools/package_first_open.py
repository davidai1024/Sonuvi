"""Generate a first-open helper pinned to the exact signed app in a DMG."""
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess


def package(app, destination):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.wusir.musetranslate':
        raise ValueError('Not a Sonuvi app')
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid version')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    digest = hashlib.sha256((app / 'Contents/MacOS/Sonuvi').read_bytes()).hexdigest()
    asset = 'Sonuvi-Mac-Offline.dmg' if info.get('SonuviIncludesVoice') else 'Sonuvi-Mac.dmg'
    template = Path(__file__).resolve().parents[1] / 'support/Sonuvi-First-Open-v0.4.19.command'
    text = template.read_text().replace('official v0.4.19 build', 'official v' + version + ' build')
    values = {
        'SUPPORTED_VERSION': version,
        'EXPECTED_SHA256': digest,
        'DOWNLOAD_URL': 'https://github.com/davidai1024/Sonuvi/releases/download/v' + version + '/' + asset,
    }
    for name, value in values.items():
        text, count = re.subn(r"^" + name + r"='[^']*'$", name + "='" + value + "'", text, flags=re.M)
        if count != 1:
            raise ValueError('Missing helper placeholder: ' + name)
    destination = Path(destination)
    destination.write_text(text)
    destination.chmod(0o755)
    return {'version': version, 'executable_sha256': digest, 'helper': destination.name}
