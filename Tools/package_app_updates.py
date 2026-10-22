#!/usr/bin/env python3
"""Sign immutable release DMGs and both appcast feeds with the existing Ed25519 key."""
from pathlib import Path
import argparse, datetime, hashlib, json, plistlib, stat, subprocess
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--light-app', type=Path, required=True)
parser.add_argument('--full-app', type=Path, required=True)
parser.add_argument('--light-dmg', type=Path, required=True)
parser.add_argument('--full-dmg', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--notes', type=Path, required=True)
args = parser.parse_args()
config = json.loads((repo / '.release-local.json').read_text())
key = Path(config['update_signing_key'])
if not key.is_file() or stat.S_IMODE(key.stat().st_mode) & 0o077:
    raise SystemExit('Existing private update key is required with permissions 0600. Never regenerate it.')
sdk = repo / 'build/Sparkle-2.10.0'
signer = sdk / 'bin/sign_update'
public = (repo / 'Resources/UpdatePublicKey.txt').read_text().strip()
signing = json.loads(Path(config['signing_profile']).read_text())
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
args.output.mkdir(parents=True, exist_ok=True)
results = []
for full, app, archive in [(False, args.light_app, args.light_dmg), (True, args.full_app, args.full_dmg)]:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    feed = 'appcast-full.xml' if full else 'appcast.xml'
    assert info['CFBundleIdentifier'] == 'com.wusir.musetranslate'
    assert info['SonuviFixedSigning'] is True and info['SonuviIncludesVoice'] is full
    assert info['SUPublicEDKey'] == public
    assert info['SURequireSignedFeed'] is True and info['SUVerifyUpdateBeforeExtraction'] is True
    assert info['SUFeedURL'] == 'https://sonuvi.davidai1024.com/updates/' + feed
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    requirement = f'=identifier "com.wusir.musetranslate" and certificate root = H"{signing["fingerprint"]}"'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, str(app)], check=True)
    signature = subprocess.check_output([str(signer), '--ed-key-file', str(key), '-p', str(archive)], text=True).strip()
    subprocess.run([str(signer), '--verify', '--ed-key-file', str(key), str(archive), signature], check=True)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Sonuvi Updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Sonuvi ' + version
    ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')
    ET.SubElement(item, '{' + ns + '}version').text = build
    ET.SubElement(item, '{' + ns + '}shortVersionString').text = version
    ET.SubElement(item, '{' + ns + '}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, 'description').text = args.notes.read_text()
    release = 'https://github.com/davidai1024/Sonuvi/releases/tag/v' + version
    ET.SubElement(item, 'link').text = release
    ET.SubElement(item, '{' + ns + '}fullReleaseNotesLink').text = release
    url = 'https://github.com/davidai1024/Sonuvi/releases/download/v' + version + '/' + archive.name
    ET.SubElement(item, 'enclosure', {'url': url, 'length': str(archive.stat().st_size),
                  'type': 'application/x-apple-diskimage', '{' + ns + '}edSignature': signature})
    path = args.output / feed
    ET.ElementTree(rss).write(path, encoding='utf-8', xml_declaration=True)
    subprocess.run([str(signer), '--ed-key-file', str(key), '-p', str(path)], check=True)
    subprocess.run([str(signer), '--verify', '--ed-key-file', str(key), str(path)], check=True)
    results.append({'feed': feed, 'version': version, 'build': build, 'asset': archive.name,
                    'bytes': archive.stat().st_size, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                    'edSignature': signature, 'feed_sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
assert len({r['version'] for r in results}) == 1 and len({r['build'] for r in results}) == 1
(args.output / 'update-manifest.json').write_text(json.dumps(results, indent=2) + '\n')
print('Verified signed appcasts and archives for light and full editions.')
