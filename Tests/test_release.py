"""Publisher regression tests. No network, credentials, or real releases."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('sonuvi_release', Path(__file__).resolve().parents[1] / 'scripts/release.py')
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)


class FakeGitHub:
    def __init__(self, plan):
        self.plan = plan
        self.items = []
        self.uploads = []
        self.writes = []
        self.calls = []
        self.fail_upload = None
        self.fail_readme = False
        self.tag_commit = None
        self.annotation = None
        self.readme = ('keep introduction\nhttps://img.shields.io/badge/version-0.1.0-green\n'
                       + r.START + '\nold download\n' + r.END + '\nkeep footer')

    def releases(self):
        return copy.deepcopy(self.items)

    def command(self, *args, **kwargs):
        if args[:2] == ('auth', 'status'):
            return
        if args[:2] != ('release', 'upload'):
            raise AssertionError(args)
        path = Path(args[3])
        self.uploads.append(path.name)
        if path.name == self.fail_upload:
            raise subprocess.CalledProcessError(1, ['gh', 'release', 'upload'])
        release = self.items[0]
        release['assets'] = [a for a in release['assets'] if a['name'] != path.name]
        release['assets'].append({'name': path.name, 'state': 'uploaded', 'size': path.stat().st_size,
                                  'digest': 'sha256:' + r.sha256(path)})

    def api(self, endpoint, method='GET', data=None):
        self.calls.append((endpoint, method))
        if '/releases/tags/' in endpoint:
            raise AssertionError('Drafts must be looked up by ID')
        if endpoint == 'repos/' + r.REPO:
            return {'default_branch': 'main', 'permissions': {'push': True}}
        if '/commits/' in endpoint:
            return {'sha': self.plan['source_commit']}
        if '/git/matching-refs/tags/' in endpoint:
            if not self.tag_commit:
                return []
            return [{'ref': 'refs/tags/v' + self.plan['version'], 'object': {
                'type': 'tag' if self.annotation else 'commit', 'sha': self.tag_commit}}]
        if '/git/tags/' in endpoint:
            return {'object': {'type': 'commit', 'sha': self.annotation}}
        if '/contents/README.md' in endpoint:
            if method == 'PUT':
                if self.fail_readme:
                    raise RuntimeError('409 concurrent README update')
                self.readme = base64.b64decode(data['content']).decode()
                self.writes.append('readme')
            return {'content': base64.b64encode(self.readme.encode()).decode(), 'sha': 'current-file-sha'}
        if endpoint.endswith('/releases') and method == 'POST':
            release = dict(data, id=123, assets=[], html_url='https://github.com/' + r.REPO + '/releases/tag/untagged-example')
            self.items.append(release)
            self.writes.append('create')
            return copy.deepcopy(release)
        if endpoint.endswith('/releases/latest'):
            return copy.deepcopy(next(x for x in self.items if not x['draft']))
        if endpoint.endswith('/releases/123'):
            if method == 'PATCH':
                self.items[0].update(data)
                self.items[0]['html_url'] = 'https://github.com/' + r.REPO + '/releases/tag/v' + self.plan['version']
                self.writes.append('publish')
            return copy.deepcopy(self.items[0])
        raise AssertionError((endpoint, method))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.asset = self.folder / r.ASSET_NAME
        self.asset.write_bytes(b'test package, not an actual DMG')
        self.plan = {'schema': 1, 'version': '1.2.3', 'build': '42', 'minimum_macos': '26.2',
                     'architecture': 'arm64', 'voice_count': 28, 'signature': 'ad-hoc',
                     'repository': r.REPO, 'source_commit': 'a' * 40, 'asset': r.ASSET_NAME,
                     'size': self.asset.stat().st_size, 'sha256': r.sha256(self.asset)}
        (self.folder / 'SHA256SUMS.txt').write_text(self.plan['sha256'] + '  ' + r.ASSET_NAME + '\n')
        (self.folder / 'release-notes.md').write_text('test release notes')
        self.plan['notes_sha256'] = r.sha256(self.folder / 'release-notes.md')
        self.path = self.folder / 'release.json'
        r.write_json(self.path, self.plan)
        self.gh = FakeGitHub(self.plan)
        self.downloads = []

    def publish(self, check=None):
        r.publish(self.path, client=self.gh,
                  download_check=check or (lambda url, size: self.downloads.append((url, size))))

    def test_draft_without_tag_publishes_and_preserves_readme(self):
        self.publish()
        self.assertEqual(self.gh.uploads, [r.ASSET_NAME, 'SHA256SUMS.txt'])
        self.assertEqual(self.gh.writes, ['create', 'publish', 'readme'])
        self.assertIn('keep introduction', self.gh.readme)
        self.assertIn('keep footer', self.gh.readme)
        self.assertIn('version-1.2.3-green', self.gh.readme)
        self.assertTrue((self.folder / 'publish-result.json').exists())

    def test_failed_second_upload_resumes_without_reuploading_dmg(self):
        self.gh.fail_upload = 'SHA256SUMS.txt'
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.gh.items[0]['draft'])
        self.gh.fail_upload = None
        self.publish()
        self.assertEqual(self.gh.uploads.count(r.ASSET_NAME), 1)
        self.assertEqual(self.gh.writes.count('create'), 1)

    def test_public_release_rerun_is_idempotent(self):
        self.publish()
        before = list(self.gh.writes)
        self.publish()
        self.assertEqual(self.gh.writes, before)
        self.assertEqual(len(self.gh.uploads), 2)

    def test_public_package_cannot_be_overwritten(self):
        self.publish()
        self.gh.items[0]['assets'][0]['digest'] = 'sha256:' + 'b' * 64
        with self.assertRaisesRegex(RuntimeError, '公开版本'):
            self.publish()
        self.assertEqual(len(self.gh.uploads), 2)

    def test_wrong_draft_attachment_is_preserved(self):
        self.gh.fail_upload = 'SHA256SUMS.txt'
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.gh.items[0]['assets'][0]['digest'] = 'sha256:' + 'b' * 64
        self.gh.fail_upload = None
        with self.assertRaisesRegex(RuntimeError, '草稿内已有'):
            self.publish()
        self.assertTrue(self.gh.items[0]['draft'])

    def test_incomplete_placeholder_can_be_retried(self):
        self.gh.fail_upload = 'SHA256SUMS.txt'
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.gh.items[0]['assets'][0].update(state='starter', size=0, digest=None)
        self.gh.fail_upload = None
        self.publish()
        self.assertEqual(self.gh.uploads.count(r.ASSET_NAME), 2)

    def test_failed_download_keeps_readme_and_can_resume(self):
        original = self.gh.readme
        def unavailable(*args):
            raise RuntimeError('download unavailable')
        with self.assertRaisesRegex(RuntimeError, 'download unavailable'):
            self.publish(unavailable)
        self.assertEqual(self.gh.readme, original)
        self.assertFalse((self.folder / 'publish-result.json').exists())
        self.publish()
        self.assertEqual(len(self.gh.uploads), 2)

    def test_missing_readme_marker_prevents_remote_changes(self):
        self.gh.readme = 'hand-edited README without markers'
        with self.assertRaisesRegex(RuntimeError, '标记'):
            self.publish()
        self.assertEqual(self.gh.writes, [])

    def test_readme_conflict_does_not_claim_success(self):
        self.gh.fail_readme = True
        with self.assertRaisesRegex(RuntimeError, '409'):
            self.publish()
        self.assertFalse((self.folder / 'publish-result.json').exists())
        self.gh.fail_readme = False
        self.publish()
        self.assertEqual(len(self.gh.uploads), 2)

    def test_edit_during_upload_is_preserved(self):
        original = self.gh.command
        def command(*args, **kwargs):
            result = original(*args, **kwargs)
            if args[:2] == ('release', 'upload'):
                self.gh.readme += '\nnew contributor paragraph'
            return result
        self.gh.command = command
        self.publish()
        self.assertIn('new contributor paragraph', self.gh.readme)

    def test_package_tampering_fails_before_network(self):
        self.asset.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, '安装包被修改'):
            self.publish()
        self.assertEqual(self.gh.calls, [])

    def test_notes_tampering_fails_before_network(self):
        (self.folder / 'release-notes.md').write_text('changed notes')
        with self.assertRaisesRegex(RuntimeError, '发布说明已变化'):
            self.publish()
        self.assertEqual(self.gh.calls, [])

    def test_check_only_never_instantiates_network_client(self):
        with patch.object(r, 'GitHub', side_effect=AssertionError('network')):
            r.publish(self.path, check_only=True)

    def test_tag_commit_conflict_stops_before_upload(self):
        self.gh.tag_commit = 'b' * 40
        with self.assertRaisesRegex(RuntimeError, '标签指向不同'):
            self.publish()
        self.assertEqual(self.gh.uploads, [])

    def test_annotated_tag_resolves_to_source(self):
        self.gh.tag_commit = 'b' * 40
        self.gh.annotation = self.plan['source_commit']
        self.publish()
        self.assertTrue(any('/git/tags/' in endpoint for endpoint, _ in self.gh.calls))

    def test_no_downgrade(self):
        self.gh.items = [{'tag_name': 'v1.10.0', 'draft': False, 'prerelease': False}]
        with self.assertRaisesRegex(RuntimeError, '不能将 latest'):
            self.publish()
        self.assertEqual(self.gh.writes, [])

    def test_duplicate_drafts_rejected(self):
        with self.assertRaisesRegex(RuntimeError, '多个草稿'):
            r.existing_release([{'tag_name': 'v1.2.3'}, {'tag_name': 'v1.2.3'}], '1.2.3')

    def test_versions_sorted_numerically_and_prerelease_rejected(self):
        for version in ('1.9.0', '1.10.0', '1.2.3'):
            folder = self.folder / ('v' + version)
            folder.mkdir()
            r.write_json(folder / 'release.json', dict(self.plan, version=version))
        self.assertEqual(r.choose_plan(self.folder).parent.name, 'v1.10.0')
        with self.assertRaises(RuntimeError):
            r.version_key('1.2.3-beta.1')

    def test_changelog_matches_exact_version(self):
        text = '# Updates\n## 1.2.30\nwrong\n## 1.2.3 · today\nright\n## 1.2.2\nold'
        self.assertEqual(r.changelog_section(text, '1.2.3'), 'right')
        with self.assertRaises(RuntimeError):
            r.changelog_section(text, '1.2.4')

    def test_newer_release_during_upload_does_not_publish(self):
        original = self.gh.releases
        count = [0]
        def releases():
            count[0] += 1
            result = original()
            if count[0] > 1:
                result.append({'tag_name': 'v9.0.0', 'draft': False, 'prerelease': False})
            return result
        self.gh.releases = releases
        with self.assertRaisesRegex(RuntimeError, '不能将 latest'):
            self.publish()
        self.assertTrue(self.gh.items[0]['draft'])
        self.assertNotIn('readme', self.gh.writes)

    def test_build_record_is_bound_to_dmg_and_source(self):
        record = {'schema': 1, 'source_commit': self.plan['source_commit'],
                  'dmg_size': self.asset.stat().st_size, 'dmg_sha256': r.sha256(self.asset),
                  'metadata': {'version': '1.2.3'}}
        r.write_json(r.build_record_path(self.asset), record)
        with patch.object(r, 'run'), patch.object(r, 'inspect_dmg', side_effect=AssertionError('mount')):
            self.assertEqual(r.inspect_package(self.asset, self.plan['source_commit']), {'version': '1.2.3'})
            with self.assertRaisesRegex(RuntimeError, '源码'):
                r.inspect_package(self.asset, 'b' * 40)
            self.asset.write_bytes(b'altered image')
            with self.assertRaisesRegex(RuntimeError, '打包记录不一致'):
                r.inspect_package(self.asset, self.plan['source_commit'])

    def test_package_without_build_record_uses_readonly_inspection(self):
        with patch.object(r, 'inspect_dmg', return_value={'version': '1.2.3'}) as inspect:
            self.assertEqual(r.inspect_package(self.asset, self.plan['source_commit']), {'version': '1.2.3'})
            inspect.assert_called_once_with(self.asset)

    def test_simultaneous_publish_is_blocked(self):
        with r.locked(self.folder):
            with self.assertRaisesRegex(RuntimeError, '正在运行'):
                self.publish()
        self.assertEqual(self.gh.calls, [])


if __name__ == '__main__':
    unittest.main()
