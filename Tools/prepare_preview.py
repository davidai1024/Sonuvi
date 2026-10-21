#!/usr/bin/env python3
"""Create an isolated visual fixture that never publishes macOS Services."""
import argparse
from pathlib import Path
import plistlib
import subprocess
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
source=a.source.resolve();output=a.output.resolve()
if source==output or output.exists() or output.suffix!='.app' or '/Applications/' in str(output):p.error('Choose a new preview .app outside Applications')
output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['/bin/cp','-cR',str(source),str(output)],check=True)
f=output/'Contents/Info.plist';info=plistlib.loads(f.read_bytes());info.pop('NSServices',None);info.pop('CFBundleURLTypes',None);info['CFBundleIdentifier']='com.wusir.sonuvi.preview';info['MusePreview']=True;f.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(output)],check=True)
print(output)
