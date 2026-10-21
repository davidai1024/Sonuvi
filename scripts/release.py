#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Prepare and publish stable Sonuvi offline releases. Python 3.9+, stdlib only."""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Resources'))
from runtime_compat import validate_tree
REPO = 'davidai1024/Sonuvi'
ASSET_NAME = 'Sonuvi-Mac.dmg'
START = '<!-- sonuvi-download:start -->'
END = '<!-- sonuvi-download:end -->'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def version_key(version):
    require(re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version),
            '仅发布 x.y.z 格式的正式版本；测试版不能占用 latest 下载入口。')
    return tuple(map(int, version.split('.')))


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


@contextlib.contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / '.publish.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('另一个发布任务正在运行，请勿重复打开。')
        yield


def inspect_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == 'com.wusir.musetranslate', '这不是 Sonuvi 安装包。')
    bundled = info.get('SonuviIncludesVoice') is True
    require(bundled or info.get('SonuviVoiceDelivery') == 'download', '缺少语音资源分发配置。')
    version = str(info['CFBundleShortVersionString'])
    version_key(version)
    if bundled:
        voices = json.loads((app / 'Contents/Resources/BundledVoice/manifest.json').read_text())
    else:
        catalog = json.loads(run([app / 'Contents/MacOS/Sonuvi', '--voice-catalog-check'], stdout=subprocess.PIPE).stdout)
        voices = {'architecture': catalog['architecture'], 'minimum_macos': catalog['minimumMacOS'], 'voices': catalog['voices']}
        require(not (app / 'Contents/Resources/BundledVoice').exists(), '轻量包不应包含语音模型。')
    require(voices['architecture'] == 'arm64', '此发布通道仅支持 Apple Silicon 完整离线包。')
    minimum = max((info['LSMinimumSystemVersion'], voices['minimum_macos']),
                  key=lambda v: tuple(map(int, v.split('.'))))
    validate_tree(app, minimum)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], stdout=subprocess.DEVNULL)
    signature = run(['/usr/bin/codesign', '-dv', app], stderr=subprocess.PIPE).stderr.decode()
    resources = app / 'Contents/Resources'
    require((resources / 'LICENSE').is_file() and (resources / 'THIRD_PARTY_NOTICES.txt').is_file(),
            '安装包缺少许可证。')
    require(any((resources / 'Source').glob('*.zip')), '安装包缺少对应的源码归档。')
    return {'version': version, 'build': str(info['CFBundleVersion']), 'minimum_macos': minimum,
            'architecture': 'arm64', 'voice_count': len(voices['voices']), 'voice_delivery': 'bundled' if bundled else 'download',
            'signature': 'ad-hoc' if 'Signature=adhoc' in signature else 'signed'}


def inspect_dmg(dmg):
    require(sys.platform == 'darwin', '检查 DMG 需要 macOS。')
    run(['/usr/bin/hdiutil', 'verify', dmg], stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='sonuvi-release-') as folder:
        mount = Path(folder) / 'volume'
        mount.mkdir()
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
             '-mountpoint', mount, dmg], stdout=subprocess.DEVNULL)
        try:
            app = mount / 'Sonuvi.app'
            return inspect_app(app)
        finally:
            run(['/usr/bin/hdiutil', 'detach', mount], stdout=subprocess.DEVNULL)


def changelog_section(text, version):
    pattern = r'^##\s+v?' + re.escape(version) + r'(?=\s|$)[^\n]*\n(.*?)(?=^##\s|\Z)'
    match = re.search(pattern, text, re.M | re.S)
    require(match is not None and match.group(1).strip(), 'CHANGELOG.md 缺少该版本记录；请补齐或使用 --notes。')
    return match.group(1).strip()


def build_record_path(dmg):
    return Path(str(dmg) + '.release-build.json')


def record_build(dmg, staged_app, source_commit):
    # Called by build_dmg.py with the very app copied into this DMG.
    # This is trusted local build provenance, not a cryptographic attestation.
    metadata = inspect_app(staged_app)
    write_json(build_record_path(dmg), {'schema': 1, 'source_commit': source_commit,
        'dmg_sha256': sha256(dmg), 'dmg_size': dmg.stat().st_size, 'metadata': metadata})


def inspect_package(dmg, source_commit):
    record = build_record_path(dmg)
    if not record.exists():
        return inspect_dmg(dmg)
    data = json.loads(record.read_text())
    require(data.get('schema') == 1 and data['source_commit'] == source_commit,
            '打包记录对应的源码与 --source-ref 不一致。')
    require(data['dmg_size'] == dmg.stat().st_size and data['dmg_sha256'] == sha256(dmg),
            'DMG 与打包记录不一致，请重新构建；未使用失效元信息。')
    run(['/usr/bin/hdiutil', 'verify', dmg], stdout=subprocess.DEVNULL)
    metadata = data['metadata']
    version_key(metadata['version'])
    return metadata


def download_block(plan):
    url = 'https://github.com/' + plan['repository'] + '/releases/latest'
    return '\n'.join([
        START,
        '[![下载 Mac 版](https://img.shields.io/badge/下载_Mac_版-macOS_安装包-238636?style=for-the-badge&logo=apple&logoColor=white)](' + url + '/download/' + plan.get('asset', ASSET_NAME) + ')',
        '', '**[点击直接下载 DMG](' + url + '/download/' + plan.get('asset', ASSET_NAME) + ')** · [版本与更新说明](' + url + ')',
        '', 'Apple Silicon（M 系列芯片） · macOS ' + plan['minimum_macos'] + ' 及以上 · v' + plan['version'] + ' · 约 ' + str(round(plan['size'] / 1000000)) + ' MB',
        '', ('本地语音资源在应用内按需下载，包含 ' + str(plan['voice_count']) + ' 个英文音色；已有模型会保留，可独立更新。' if plan.get('voice_delivery') == 'download' else '内置本地模型、' + str(plan['voice_count']) + ' 个英文音色与运行环境，无需另装 Python 或 Speak11。'), END])


def update_readme(text, plan):
    require(text.count(START) == 1 and text.count(END) == 1 and text.index(START) < text.index(END),
            'README 下载区标记缺失或重复，未自动覆盖文档。')
    text = text[:text.index(START)] + download_block(plan) + text[text.index(END) + len(END):]
    pattern = r'(https://img\.shields\.io/badge/version-)[0-9]+\.[0-9]+\.[0-9]+(-)'
    text, count = re.subn(pattern, lambda m: m[1] + plan['version'] + m[2], text)
    require(count == 1, 'README 版本徽章缺失或重复。')
    return text


def release_notes(plan, changes):
    base = 'https://github.com/' + plan['repository']
    signing = ('当前安装包为 ad-hoc 签名，尚未完成 Apple Developer ID 签名与公证。'
               if plan['signature'] == 'ad-hoc' else '应用签名检查通过；本工具不据此宣称已完成 Apple 公证。')
    edition = '轻量版' if plan.get('voice_delivery') == 'download' else '完整离线版'
    voice_copy = (f"本地语音资源按需下载，包含 {plan['voice_count']} 个英文音色与完整运行环境。已有模型会保留，后续可独立更新。下载后可离线朗读；翻译需要联网及自己的 DeepSeek API Key。" if plan.get('voice_delivery') == 'download' else f"内置本地模型、{plan['voice_count']} 个英文音色与运行环境。英文朗读可离线；翻译需要联网及自己的 DeepSeek API Key。")
    return f'''# Sonuvi v{plan['version']} · {edition}

**[点击直接下载 Mac 安装包]({base}/releases/download/v{plan['version']}/{plan.get('asset', ASSET_NAME)})**

Apple Silicon · macOS {plan['minimum_macos']} 及以上 · 约 {round(plan['size'] / 1000000)} MB。
{voice_copy}

## 本次更新

{changes}

## 安装与升级

下载 `.dmg`，双击后将 Sonuvi.app 拖到 Applications，再从「应用程序」打开。
升级前先退出旧版，再拖入替换；已有配置保留。`Source code` 是源码，不是安装包。

{signing} 请核对下载来源，并按 macOS「隐私与安全性」中的提示处理首次打开检查。无需关闭系统整体安全保护。
当前不支持 Intel Mac、Windows 和应用内自动更新；更新后可能需要重新授权。

## 校验与源码

下载 `SHA256SUMS.txt` 后，在文件所在目录执行 `shasum -a 256 -c SHA256SUMS.txt`。

对应源码提交：[{plan['source_commit'][:12]}]({base}/tree/{plan['source_commit']})。安装包也包含源码与第三方许可文件。
'''


def prepare(args):
    dmg = args.dmg.expanduser().resolve()
    require(dmg.is_file() and dmg.suffix.lower() == '.dmg', '请选择已构建完成的 DMG。')
    require(re.fullmatch('[0-9a-f]{40}', args.source_ref), '--source-ref 必须是对应构建源码的完整 40 位提交 SHA。')
    print('检查 DMG、应用签名和内置模型……', flush=True)
    plan = inspect_package(dmg, args.source_ref)
    changes = (args.notes.read_text(encoding='utf-8').strip() if args.notes else
               changelog_section((ROOT / 'CHANGELOG.md').read_text(encoding='utf-8'), plan['version']))
    require(changes, '更新说明不能为空。')
    plan.update(schema=1, repository=REPO, source_commit=args.source_ref, asset=ASSET_NAME,
                size=dmg.stat().st_size, sha256=sha256(dmg))
    folder = args.output.resolve() / ('v' + plan['version'])
    with locked(folder):
        path = folder / 'release.json'
        if path.exists():
            old = validate_plan(path)
            require(old['sha256'] == plan['sha256'] and old['source_commit'] == plan['source_commit'],
                    '该版本已准备过不同的安装包或源码，请递增版本号；未覆盖。')
            print('同一版本发布包已准备好，复用：' + str(path))
            return path
        target = folder / ASSET_NAME
        temporary = folder / (ASSET_NAME + '.tmp')
        shutil.copyfile(dmg, temporary)
        require(sha256(temporary) == plan['sha256'], '复制期间安装包发生变化。')
        temporary.replace(target)
        (folder / 'SHA256SUMS.txt').write_text(plan['sha256'] + '  ' + ASSET_NAME + '\n', encoding='utf-8')
        (folder / 'release-notes.md').write_text(release_notes(plan, changes), encoding='utf-8')
        plan['notes_sha256'] = sha256(folder / 'release-notes.md')
        write_json(path, plan)
        print('已准备：' + str(path) + '\n现在可双击仓库根目录的「发布到GitHub.command」。', flush=True)
        return path


def validate_plan(path):
    plan = json.loads(path.read_text(encoding='utf-8'))
    require(plan.get('schema') == 1 and plan['repository'] == REPO and plan['asset'] in (ASSET_NAME, 'Sonuvi-Mac-Offline.dmg'),
            '发布清单格式或目标仓库不匹配。')
    version_key(plan['version'])
    require(re.fullmatch('[0-9a-f]{40}', plan['source_commit']), '源码提交格式不正确。')
    require(re.fullmatch('[0-9a-f]{64}', plan['sha256']), '安装包校验值格式不正确。')
    require(plan['architecture'] == 'arm64' and plan['signature'] in ('ad-hoc', 'signed'), '安装包平台或签名元信息不正确。')
    require(re.fullmatch(r'\d+(?:\.\d+){1,2}', plan['minimum_macos']), '最低系统版本格式不正确。')
    require(isinstance(plan['voice_count'], int) and plan['voice_count'] > 0, '音色数量无效。')
    asset = path.parent / plan['asset']
    require(asset.stat().st_size == plan['size'] and sha256(asset) == plan['sha256'], '安装包被修改或不完整，请重新构建新版本。')
    require((path.parent / 'SHA256SUMS.txt').read_text().strip() == plan['sha256'] + '  ' + plan['asset'], '校验清单被修改。')
    require(sha256(path.parent / 'release-notes.md') == plan['notes_sha256'], '发布说明已变化，请检查准备目录。')
    return plan


def choose_plan(directory):
    candidates = list(directory.glob('v*/release.json'))
    require(candidates, '没有待发布版本。请先运行 release.py prepare；方法见 docs/releasing.md。')
    return max(candidates, key=lambda p: version_key(json.loads(p.read_text())['version']))


class GitHub:
    def __init__(self):
        local_path = ROOT / '.release-local.json'
        local = json.loads(local_path.read_text()) if local_path.exists() else {}
        executable = local.get('gh_path') or shutil.which('gh')
        require(executable, '未找到 GitHub CLI。请安装官方 gh，或在 .release-local.json 中配置路径。')
        self.executable = str((ROOT / executable).resolve()) if not Path(executable).is_absolute() else executable
        self.env = dict(os.environ)
        if local.get('gh_config_dir'):
            self.env['GH_CONFIG_DIR'] = str((ROOT / local['gh_config_dir']).resolve())

    def command(self, *args, capture=False):
        return run([self.executable, *args], env=self.env,
                   stdout=subprocess.PIPE if capture else None).stdout

    def api(self, endpoint, method='GET', data=None):
        args = [self.executable, 'api', endpoint, '--method', method]
        if data is not None:
            args += ['--input', '-']
        result = run(args, env=self.env, stdout=subprocess.PIPE,
                     input=json.dumps(data).encode() if data is not None else None)
        return json.loads(result.stdout or b'{}')

    def releases(self):
        items = []
        for page in range(1, 101):
            batch = self.api('repos/' + REPO + '/releases?per_page=100&page=' + str(page))
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise RuntimeError('发布列表过长，停止以免遗漏版本。')


def existing_release(releases, version):
    matches = [r for r in releases if r['tag_name'] == 'v' + version]
    require(len(matches) < 2, '同一版本存在多个草稿，请先检查。')
    return matches[0] if matches else None


def prevent_downgrade(releases, version):
    for release in releases:
        tag = release['tag_name'].removeprefix('v')
        if not release['draft'] and not release.get('prerelease') and re.fullmatch(r'\d+\.\d+\.\d+', tag):
            require(version_key(tag) <= version_key(version), '已有更新版本，不能将 latest 下载入口降级。')


def verify_asset(item, path, expected):
    return bool(item and item.get('state') == 'uploaded' and item['size'] == path.stat().st_size
                and item.get('digest') == 'sha256:' + expected)


def verify_tag_source(gh, tag, commit):
    refs = gh.api('repos/' + REPO + '/git/matching-refs/tags/' + tag)
    ref = next((r for r in refs if r['ref'] == 'refs/tags/' + tag), None)
    if ref is None:
        return
    obj = ref['object']
    for _ in range(10):
        if obj['type'] == 'commit':
            require(obj['sha'] == commit, '现有版本标签指向不同源码，未移动标签或覆盖发布。')
            return
        require(obj['type'] == 'tag', '无法确认版本标签对应的源码。')
        obj = gh.api('repos/' + REPO + '/git/tags/' + obj['sha'])['object']
    raise RuntimeError('版本标签引用过深，停止发布。')


def verify_download(url, size):
    # GitHub redirects may take a moment to become available after publication.
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'Sonuvi-Release'})
            with urllib.request.urlopen(request, timeout=30) as response:
                require(response.status == 200 and int(response.headers.get('Content-Length', 0)) == size,
                        '下载响应或文件大小不符。')
                return
        except (urllib.error.URLError, RuntimeError):
            if attempt == 2:
                raise
            time.sleep(2)


def publish(path, check_only=False, client=None, download_check=verify_download):
    with locked(path.parent):
        plan = validate_plan(path)
        tag = 'v' + plan['version']
        print('本次发布：' + tag + ' · ' + str(round(plan['size'] / 1000000)) + ' MB · macOS ' + plan['minimum_macos'] + '+', flush=True)
        if check_only:
            print('本地检查通过。未登录、上传或修改 GitHub。')
            return
        gh = client or GitHub()
        # Do not misinterpret a network failure as an expired login.
        gh.command('auth', 'status', '--hostname', 'github.com')
        repository = gh.api('repos/' + REPO)
        branch = repository['default_branch']
        require(repository.get('permissions', {}).get('push'), '当前账号没有仓库写入权限。')
        require(gh.api('repos/' + REPO + '/commits/' + plan['source_commit'])['sha'] == plan['source_commit'], '对应源码尚未上传 GitHub。')
        verify_tag_source(gh, tag, plan['source_commit'])
        readme_endpoint = 'repos/' + REPO + '/contents/README.md?ref=' + branch
        # Check document compatibility before creating or publishing anything.
        update_readme(base64.b64decode(gh.api(readme_endpoint)['content']).decode(), plan)
        releases = gh.releases()
        prevent_downgrade(releases, plan['version'])
        release = existing_release(releases, plan['version'])
        if release is None:
            release = gh.api('repos/' + REPO + '/releases', 'POST', {
                'tag_name': tag, 'target_commitish': plan['source_commit'], 'name': 'Sonuvi ' + tag + (' · 轻量版' if plan.get('voice_delivery') == 'download' else ' · 完整离线版'),
                'body': (path.parent / 'release-notes.md').read_text(), 'draft': True, 'prerelease': False})
        endpoint = 'repos/' + REPO + '/releases/' + str(release['id'])
        require(release['target_commitish'] == plan['source_commit'], '同版本发布指向不同源码，未覆盖。')
        require(not release.get('prerelease'), '该版本已作为测试版存在，未改动。')
        files = [(path.parent / plan['asset'], plan['sha256']),
                 (path.parent / 'SHA256SUMS.txt', sha256(path.parent / 'SHA256SUMS.txt'))]
        for file, expected in files:
            release = gh.api(endpoint)
            item = next((a for a in release['assets'] if a['name'] == file.name), None)
            if verify_asset(item, file, expected):
                print(file.name + ' 已上传且校验一致，跳过。', flush=True)
                continue
            require(release['draft'], '公开版本附件缺失或不一致，请发布新版本；未覆盖。')
            # Only incomplete placeholder assets may be replaced automatically.
            require(item is None or item.get('state') == 'starter', '草稿内已有同名但内容不同的附件，未覆盖。')
            args = ['release', 'upload', tag, str(file), '--repo', REPO]
            if item:
                args.append('--clobber')
            print('正在上传 ' + file.name + '，完成后会自动校验……', flush=True)
            gh.command(*args)
        release = gh.api(endpoint)
        for file, expected in files:
            item = next((a for a in release['assets'] if a['name'] == file.name), None)
            require(verify_asset(item, file, expected), 'GitHub 附件校验未通过；保持草稿，README 未更新。')
        # Re-check in case another release was published while this file uploaded.
        prevent_downgrade(gh.releases(), plan['version'])
        if release['draft']:
            release = gh.api(endpoint, 'PATCH', {'draft': False, 'make_latest': 'true',
                'body': (path.parent / 'release-notes.md').read_text()})
        latest = gh.api('repos/' + REPO + '/releases/latest')
        require(latest['id'] == release['id'], '该版本不是 latest；没有修改 README。')
        url = 'https://github.com/' + REPO + '/releases/latest/download/' + plan['asset']
        download_check(url, plan['size'])
        remote = gh.api(readme_endpoint)
        old = base64.b64decode(remote['content']).decode()
        updated = update_readme(old, plan)
        require(gh.api('repos/' + REPO + '/releases/latest')['id'] == release['id'], 'latest 在校验期间发生变化，未更新 README。')
        # Fresh contents + SHA preserves unrelated edits and detects concurrent writes.
        if updated != old:
            gh.api('repos/' + REPO + '/contents/README.md', 'PUT', {
                'message': 'docs: update download information for ' + tag,
                'content': base64.b64encode(updated.encode()).decode(), 'sha': remote['sha'], 'branch': branch})
        final = base64.b64decode(gh.api(readme_endpoint)['content']).decode()
        require(download_block(plan) in final, 'README 下载信息验证失败。')
        result = {'tag': tag, 'release_id': release['id'], 'release': release['html_url'],
                  'download': url, 'sha256': plan['sha256'], 'source_commit': plan['source_commit']}
        write_json(path.parent / 'publish-result.json', result)
        print('\n发布完成，安装包与 README 均已验证：\n' + url, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare', help='只检查与准备文件，不访问 GitHub')
    prep.add_argument('dmg', type=Path)
    prep.add_argument('--source-ref', required=True, help='对应构建源码的完整提交 SHA；须由构建者确认')
    prep.add_argument('--notes', type=Path, help='本次更新内容，默认取 CHANGELOG 对应版本')
    prep.add_argument('--output', type=Path, default=ROOT / 'dist/releases')
    pub = commands.add_parser('publish', help='发布已准备版本，可重复运行恢复失败步骤')
    pub.add_argument('--manifest', type=Path)
    pub.add_argument('--directory', type=Path, default=ROOT / 'dist/releases')
    pub.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args)
    else:
        publish((args.manifest or choose_plan(args.directory)).resolve(), args.check_only)


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('\n未完成：' + str(error) + '\n请保留准备目录，解决原因后再次运行；已校验的附件会跳过。', file=sys.stderr)
        sys.exit(1)
