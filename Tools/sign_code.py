#!/usr/bin/env python3
"""Sign with the existing local identity. Never creates keys or changes trust."""
from pathlib import Path
import argparse, hashlib, json, re, stat, subprocess, sys
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--profile',type=Path)
parser.add_argument('targets',nargs='+',type=Path)
args=parser.parse_args()
profile=args.profile
if profile is None:
    settings=root/'.release-local.json'
    if settings.is_file(): profile=Path(json.loads(settings.read_text()).get('signing_profile',''))
if profile is None or not profile.is_file():sys.exit('Fixed signing profile is missing; refusing to fall back to an ad-hoc signature.')
if stat.S_IMODE(profile.stat().st_mode)&0o077:sys.exit('Signing profile permissions must be private (0600).')
config=json.loads(profile.read_text())
if not re.fullmatch(r'[A-Fa-f0-9]{40}',config.get('fingerprint','')):sys.exit('Invalid signing certificate fingerprint.')
if not Path(config.get('keychain','')).is_file():sys.exit('Signing keychain is missing; do not generate a replacement identity.')
source=root/'Tools/LocalCodeSigner.swift'
cache=root/'build/signing-tools';cache.mkdir(parents=True,exist_ok=True)
helper=cache/('local-signer-'+hashlib.sha256(source.read_bytes()).hexdigest()[:12])
if not helper.exists():subprocess.run(['/usr/bin/swiftc','-suppress-warnings',str(source),'-framework','Security','-o',str(helper)],check=True)
for target in args.targets:
    if not target.exists():sys.exit('Signing target is missing: '+str(target))
request={k:config[k] for k in ['keychain','password','fingerprint']}
request['targets']=[str(p.resolve()) for p in args.targets]
subprocess.run([str(helper)],input=json.dumps(request),text=True,check=True)
for target in args.targets:
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(target)],check=True)
    result=subprocess.run(['/usr/bin/codesign','-d','-r-',str(target)],text=True,capture_output=True,check=True)
    if config['fingerprint'].lower() not in (result.stdout+result.stderr).lower():sys.exit('Signed identity does not match the configured fixed certificate.')
print('Verified fixed certificate on '+str(len(args.targets))+' signing target(s).')
