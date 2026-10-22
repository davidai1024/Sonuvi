#!/usr/bin/env python3
"""Exercise real Sparkle installation and signature rejection using isolated apps."""
from pathlib import Path
import functools, hashlib, http.server, json, plistlib, shutil, subprocess, tempfile, threading, time
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parent.parent
config = json.loads((repo / '.release-local.json').read_text())
sdk = repo / 'build/Sparkle-2.10.0'
private = config['update_signing_key']
public = (repo / 'Resources/UpdatePublicKey.txt').read_text().strip()
root = Path(tempfile.mkdtemp(prefix='sonuvi-updater-test-'))
binary = root / 'Fixture'
def run(args):
    result = subprocess.run([str(x) for x in args], text=True, capture_output=True)
    if result.returncode: print(result.stderr, flush=True); result.check_returncode()
    return result
run(['/usr/bin/swiftc', '-swift-version', '5', repo / 'Tools/UpdateInstallFixture.swift', '-F', sdk,
     '-framework', 'Sparkle', '-framework', 'AppKit', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', binary])
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:' + str(server.server_port)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
results = []
try:
    for kind in ['valid', 'tampered-archive', 'tampered-feed', 'current']:
        print('CHECK', kind, flush=True)
        directory = root / kind; directory.mkdir()
        (directory / 'Voice').mkdir(); (directory / 'Voice/model-marker').write_text('synthetic-local-model')
        app = directory / 'Sonuvi Updater Test.app'
        new = directory / 'new/Sonuvi Updater Test.app'
        identifier = 'com.wusir.sonuvi.updatertest.' + kind
        for version, bundle in [('1', app), ('1' if kind == 'current' else '2', new)]:
            (bundle / 'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(binary, bundle / 'Contents/MacOS/Fixture')
            run(['/usr/bin/ditto', sdk / 'Sparkle.framework', bundle / 'Contents/Frameworks/Sparkle.framework'])
            info = dict(CFBundleIdentifier=identifier, CFBundleName='Sonuvi Updater Test', CFBundleExecutable='Fixture',
                        CFBundlePackageType='APPL', CFBundleVersion=version, CFBundleShortVersionString='1.0.' + version,
                        FixtureRoot=str(directory), LSUIElement=True,
                        SUFeedURL=base + '/' + kind + '/appcast.xml', SUPublicEDKey=public,
                        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                        SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            (bundle / 'Contents/Resources').mkdir(exist_ok=True)
            (bundle / 'Contents/Resources/revision.txt').write_text(version)
        run(['/usr/bin/python3', repo / 'Tools/sign_code.py', app, new])
        archive = directory / 'update.zip'
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', new, archive])
        sig = run([sdk / 'bin/sign_update', '--ed-key-file', private, '-p', archive]).stdout.strip()
        rss = ET.Element('rss', version='2.0');channel=ET.SubElement(rss,'channel');ET.SubElement(channel,'title').text='Fixture'
        item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='Fixture update'
        ET.SubElement(item,'{'+ns+'}version').text='1' if kind=='current' else '2'
        ET.SubElement(item,'{'+ns+'}shortVersionString').text='1.0.2'
        ET.SubElement(item,'enclosure',{'url':base+'/'+kind+'/update.zip','length':str(archive.stat().st_size),
                      'type':'application/octet-stream','{'+ns+'}edSignature':sig})
        feed=directory/'appcast.xml';ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
        run([sdk / 'bin/sign_update', '--ed-key-file', private, '-p', feed])
        if kind=='tampered-archive':
            data=bytearray(archive.read_bytes());data[len(data)//2]^=1;archive.write_bytes(data)
        if kind=='tampered-feed':feed.write_text(feed.read_text().replace('Fixture update','Altered update'))
        run(['/usr/bin/open', '-n', app])
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            try:events=[json.loads(line) for line in (directory/'events.jsonl').read_text().splitlines()]
            except FileNotFoundError:events=[]
            if any(e['event'] in ['relaunched','rejected','start_error','no_update'] for e in events):break
            time.sleep(0.5)
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        passed = (any(e['event']=='relaunched' and e.get('model_preserved') for e in events) and info['CFBundleVersion']=='2') if kind=='valid' else (
                  any(e['event']==('no_update' if kind=='current' else 'rejected') for e in events) and info['CFBundleVersion']=='1')
        if kind=='tampered-feed':passed=passed and not any(e['event']=='downloading' for e in events)
        # Sparkle announces its "extracting" UI state before archive validation.
        # A rejected archive must never reach installation readiness or replace the app.
        if kind=='tampered-archive':
            passed=passed and not any(e['event'] in ['ready','installing'] for e in events)
            passed=passed and any(e['event']=='rejected' and e.get('code')==4005 for e in events)
        passed=passed and (app/'Contents/Resources/revision.txt').read_text()==info['CFBundleVersion']
        passed=passed and (directory/'Voice/model-marker').read_text()=='synthetic-local-model'
        results.append({'case':kind,'passed':passed,'installed_version':info['CFBundleVersion'],'events':events})
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
    report={'passed':all(r['passed'] for r in results),'cases':results,'test_root':str(root)}
    (repo / 'build/app-update-test-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    if not report['passed']:raise SystemExit(1)
finally:
    server.shutdown()
