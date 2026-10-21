#!/usr/bin/env python3
"""Build a Finder drag-to-Applications installer without mounting a writable image.

Build-only dependencies: ds_store==1.3.3, mac_alias==2.2.3.
The HFS+ catalog layout follows Apple Technical Note TN1150.
"""
import argparse
import datetime
import importlib.util
import json
import plistlib
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from ds_store import DSStore
from mac_alias import Alias, VolumeInfo, TargetInfo

u16 = lambda b, o: struct.unpack_from('>H', b, o)[0]
u32 = lambda b, o: struct.unpack_from('>I', b, o)[0]
epoch = datetime.datetime(1904, 1, 1, tzinfo=datetime.timezone.utc)
volume_name = 'Sonuvi'


def store(path, metadata=None):
    m = metadata or dict(volumeCreated=1, fileCreated=1, folder=2, file=3)
    volume = VolumeInfo(volume_name, epoch + datetime.timedelta(seconds=m['volumeCreated']), b'H+', 0, 0, b'\0\0', posix_path='/Volumes/' + volume_name)
    target = TargetInfo(0, 'install.png', m['folder'], m['file'], epoch + datetime.timedelta(seconds=m['fileCreated']), b'\0'*4, b'\0'*4,
        folder_name='.background', cnid_path=[m['folder']], carbon_path=volume_name + ':.background:\0install.png', posix_path='/.background/install.png')
    alias = Alias(volume=volume, target=target).to_bytes()
    with DSStore.open(str(path), 'w+') as d:
        d['.']['bwsp'] = dict(ShowToolbar=False, ShowSidebar=False, ShowStatusBar=False, ShowPathbar=False, ShowTabView=False,
            ContainerShowSidebar=False, WindowBounds='{{220, 180}, {660, 592}}', PreviewPaneVisibility=False)
        d['.']['icvp'] = dict(viewOptionsVersion=1, backgroundType=2, backgroundColorRed=0.05, backgroundColorGreen=0.05,
            backgroundColorBlue=0.05, backgroundImageAlias=alias, gridOffsetX=0.0, gridOffsetY=0.0,
            gridSpacing=100.0, arrangeBy='none', showIconPreview=True, showItemInfo=False, labelOnBottom=True,
            textSize=13.0, iconSize=96.0)
        d['.']['vstl'] = ('type', b'icnv')
        d['.']['vSrn'] = ('long', 1)
        d['Sonuvi.app']['Iloc'] = (175, 225)
        d['Applications']['Iloc'] = (485, 225)
        d['打开隐私与安全性.inetloc']['Iloc'] = (330, 410)


def finalize_catalog(image, store_file):
    with image.open('r+b') as f:
        f.seek(512); first = f.read(512); assert first[:2] == b'PM'
        base = None
        for n in range(1, u32(first, 4) + 1):
            f.seek(n*512); part = f.read(512)
            if part[48:80].rstrip(b'\0') == b'Apple_HFS':
                assert base is None; base = u32(part, 8)*512
        assert base is not None
        f.seek(base+1024); vh=f.read(512); assert vh[:2] in (b'H+', b'HX')
        block=u32(vh,40)
        extents=[(u32(vh,288+i*8),u32(vh,292+i*8)) for i in range(8)]
        assert sum(c for _,c in extents)*block >= struct.unpack_from('>Q',vh,272)[0]
        def position(offset,length):
            for start,count in extents:
                size=count*block
                if offset<size:
                    assert offset+length<=size
                    return base+start*block+offset
                offset-=size
            raise ValueError('Invalid catalog offset')
        def read(offset,length):
            f.seek(position(offset,length));return f.read(length)
        header=read(0,512);assert struct.unpack_from('>b',header,8)[0]==1
        node_size=u16(header,32);node=u32(header,24);records={};seen=set()
        while node:
            assert node not in seen;seen.add(node)
            data=read(node*node_size,node_size)
            assert struct.unpack_from('>b',data,8)[0]==-1
            for i in range(u16(data,10)):
                rec=u16(data,node_size-2*(i+1));value=rec+2+u16(data,rec);value+=(value%2)
                kind=u16(data,value)
                if kind not in (1,2):continue
                parent=u32(data,rec+2);length=u16(data,rec+6)
                name=data[rec+8:rec+8+length*2].decode('utf-16-be');cnid=u32(data,value+8)
                records[cnid]=dict(parent=parent,name=name,offset=node*node_size+value,kind=kind,created=u32(data,value+12))
            node=u32(data,0)
        def find(parent,name):
            values=[(i,r) for i,r in records.items() if r['parent']==parent and r['name']==name]
            assert len(values)==1,(parent,name)
            return values[0]
        app_id,_=find(2,'Sonuvi.app')
        def inside(cnid):
            visited=set()
            while cnid in records and cnid not in visited:
                if cnid==app_id:return True
                visited.add(cnid);cnid=records[cnid]['parent']
            return False
        count=0
        for cnid,r in records.items():
            if inside(cnid) and read(r['offset']+48,32)!=bytes(32):
                f.seek(position(r['offset']+48,32));f.write(bytes(32));count+=1
        folder,_=find(2,'.background');file,picture=find(folder,'install.png')
        # DiscRecording writes the volume creation date as local wall time;
        # Carbon aliases use the UTC creation date returned by getattrlist.
        offset=int(datetime.datetime.now().astimezone().utcoffset().total_seconds())
        store(store_file,dict(volumeCreated=u32(vh,16)-offset,fileCreated=picture['created'],folder=folder,file=file))
        _,ds=find(2,'.DS_Store');record=read(ds['offset'],248)
        logical=struct.unpack_from('>Q',record,88)[0]
        start=u32(record,104);blocks=u32(record,108)
        data=store_file.read_bytes()
        assert len(data)==logical and blocks*block>=logical, 'Unexpected Finder store allocation'
        f.seek(base+start*block);f.write(data)
        print(f'Normalized {count} app records; background alias references the actual image volume')


def main():
    global volume_name
    parser=argparse.ArgumentParser();parser.add_argument('--app',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--workdir',type=Path,required=True)
    parser.add_argument('--prepare-release',action='store_true',help='DMG 完成后准备通用发布包，不上传')
    parser.add_argument('--source-ref',help='与构建对应的完整源码提交 SHA')
    parser.add_argument('--release-notes',type=Path,help='本次更新内容；默认取 CHANGELOG 对应版本')
    args=parser.parse_args()
    if args.prepare_release and not args.source_ref:parser.error('--prepare-release 需要 --source-ref，不能猜测构建对应的源码提交')
    app=args.app.resolve();output=args.output.resolve();work=args.workdir.resolve();work.mkdir(parents=True,exist_ok=True)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    bundled=info.get('SonuviIncludesVoice') is True
    volume_name='Sonuvi ' + info['CFBundleShortVersionString']
    stage=work/'stage'
    if stage.exists():shutil.rmtree(stage)
    stage.mkdir()
    staged=stage/'Sonuvi.app'
    if staged.exists():shutil.rmtree(staged)
    subprocess.run(['/bin/cp','-cR',str(app),str(staged)],check=True)
    (stage/'.background').mkdir(exist_ok=True)
    tools=Path(__file__).resolve().parent
    shortcut=stage/'打开隐私与安全性.inetloc'
    shortcut.write_bytes(plistlib.dumps({'URL':'x-apple.systempreferences:com.apple.preference.security?General'}))
    subprocess.run(['/usr/bin/swift','-module-cache-path',str(tools.parent/'build/module-cache'),str(tools/'PrivacyShortcutIcon.swift'),str(shortcut),str(stage/'.background/privacy-icon.png')],check=True)
    subprocess.run(['/usr/bin/swift','-module-cache-path',str(tools.parent/'build/module-cache'),str(tools/'InstallerBackground.swift'),str(stage/'.background/install.png')]+(['--bundled-voice'] if bundled else []),check=True)
    link=stage/'Applications'
    if not link.is_symlink():link.symlink_to('/Applications',target_is_directory=True)
    docs=stage/'.Documentation';docs.mkdir(exist_ok=True)
    for name in ('LICENSE','THIRD_PARTY_NOTICES.txt'):shutil.copy2(app/'Contents/Resources'/name,docs/name)
    (docs/'使用说明.txt').write_text(volume_name + '\n\n请先退出旧版，将 Sonuvi.app 拖入 Applications。选择替换后，从应用程序打开。\n首次打开若提示“无法验证开发者”或“Apple 无法检查”，请点“完成”“好”或“取消”关闭提示，先不要点“移到废纸篓”。然后双击安装窗口下方的“打开隐私与安全性”，在“安全性”区域找到 Sonuvi，点击“仍要打开”，再按系统提示确认。若未自动定位，请手动打开“系统设置 → 隐私与安全性”，向下滚动到“安全性”；需先尝试打开一次 Sonuvi 才会出现对应提示。真正损坏或被系统判定包含恶意内容的文件不适用此流程，应重新下载并核对来源。\n该入口只是系统设置链接，不运行脚本，不修改权限或隔离标记。辅助功能和屏幕录制仍需在系统设置中授权。\n本地语音资源在应用内按需下载，包含运行环境及28个英文音色；下载后可以离线朗读，后续支持独立更新。翻译 API 可以稍后配置。\nApple Silicon / macOS 14.0+，至少预留3GB。\n个人分享版本，尚未公证；接收者按系统提示处理首次打开检查。\n',encoding='utf-8')
    if bundled:
        readme=docs/'使用说明.txt'
        readme.write_text(readme.read_text().replace('本地语音资源在应用内按需下载，包含运行环境及28个英文音色；下载后可以离线朗读，后续支持独立更新。', '已内置本地朗读模型、运行环境及28个英文音色；首次使用自动在本机准备，无需另行下载。英文朗读免费且可离线使用，后续模型支持独立更新。'))
    store(stage/'.DS_Store')
    raw=work/'Sonuvi-uncompressed.dmg'
    subprocess.run(['/usr/bin/hdiutil','makehybrid','-hfs','-hfs-volume-name',volume_name,'-hfs-openfolder',str(stage),'-ov','-o',str(raw),str(stage)],check=True)
    finalize_catalog(raw,work/'Final.DS_Store')
    output.parent.mkdir(exist_ok=True,parents=True)
    subprocess.run(['/usr/bin/hdiutil','convert',str(raw),'-format','ULMO','-ov','-o',str(output)],check=True)
    subprocess.run(['/usr/bin/hdiutil','verify',str(output)],check=True)
    print(json.dumps({'dmg':str(output),'bytes':output.stat().st_size}))
    if args.source_ref:
        spec=importlib.util.spec_from_file_location('sonuvi_release',tools.parent/'scripts/release.py')
        release=importlib.util.module_from_spec(spec);spec.loader.exec_module(release)
        release.record_build(output,staged,args.source_ref)
    if args.prepare_release:
        command=[sys.executable,str(tools.parent/'scripts/release.py'),'prepare',str(output),'--source-ref',args.source_ref]
        if args.release_notes:command+=['--notes',str(args.release_notes.resolve())]
        subprocess.run(command,check=True)


if __name__=='__main__':main()
