#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI regression checks: fail-open selection and tamper-resistant product transport."""
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent

def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

changes, products, metrics = load('ci-changes'), load('ci-products'), load('ci-metrics')
PATHS = json.loads((ROOT/'.github/ci/paths.json').read_text())


class Selection(unittest.TestCase):
    def test_every_original_path_still_triggers_its_area(self):
        for area, patterns in PATHS.items():
            for pattern in patterns:
                with self.subTest(area=area, pattern=pattern):
                    example = pattern.replace('**', 'nested/file.swift').replace('*', 'fixture')
                    self.assertTrue(changes.select('pull_request', 'base', PATHS, [example])[area])

    def test_direct_workflow_scripts_and_app_privacy_changes_run_their_consumers(self):
        for area, workflow in [('boards','ux-boards'),('whistle','ux-whistle'),('browser_setup','ux-browser-setup')]:
            body = (ROOT/'.github/workflows'/f'{workflow}.yml').read_text()
            for script in re.findall(r'python3\s+(scripts/[\w.-]+\.py)',body):
                with self.subTest(area=area,script=script):
                    self.assertTrue(changes.select('pull_request','base',PATHS,[script])[area])
        for source in ['Cassini/Transcription/TranscriptionQueue.swift','Cassini/Cassini.entitlements','Cassini/Info.plist']:
            self.assertTrue(changes.select('pull_request','base',PATHS,[source])['whistle'])

    def test_unknown_base_and_detection_failure_run_everything(self):
        self.assertTrue(all(changes.select('pull_request', '', PATHS).values()))
        with patch.object(changes.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(128, 'git')):
            self.assertTrue(all(changes.select('pull_request', 'missing', PATHS).values()))

    def test_main_nightly_and_manual_are_full_runs(self):
        for event in ['push', 'schedule', 'workflow_dispatch']:
            self.assertTrue(all(changes.select(event, 'base', PATHS, ['README.md']).values()))

    def test_documentation_only_retains_original_ux_filter_behavior(self):
        self.assertFalse(any(changes.select('pull_request', 'base', PATHS, ['README.md']).values()))

    def test_shared_dependency_or_ci_change_runs_everything(self):
        for name in ['.github/actions/ci-products/action.yml', 'Sources/CassiniKit/Reader.swift', 'Tests/CassiniPlaybackTests/Seek.swift']:
            self.assertTrue(all(changes.select('pull_request', 'base', PATHS, [name]).values()))


def ci_job(name):
    """The body of one top-level job in ci.yml (its lines up to the next two-space key)."""
    body = (ROOT/'.github/workflows/ci.yml').read_text()
    found = re.search(rf'^  {name}:\n(.*?)(?=^  \S|^\S|\Z)', body, re.M | re.S)
    assert found, name
    return found.group(1)


def step_condition(job, marker):
    """The `if:` of the step whose text contains marker (searching back to its `- ` line)."""
    at = job.index(marker)
    start = job.rindex('\n    - ', 0, at + len('\n    - ')) + 1  # the last step start at or before marker
    end = job.find('\n    - ', at)
    found = re.search(r'^\s+if: (.+)$', job[start:end if end >= 0 else None], re.M)
    assert found, marker
    return found.group(1)


class FoldedJobs(unittest.TestCase):
    """D66 mac-P2-1: every path area still selects a job, and the merged jobs keep the checks,
    order and conditions of the jobs they replace."""
    CI = (ROOT/'.github/workflows/ci.yml').read_text()

    def test_every_area_is_an_output_that_some_job_reads(self):
        outputs = set(re.findall(r'^      (\w+): \$\{\{ steps\.paths\.outputs\.(\w+) \}\}$', self.CI, re.M))
        self.assertEqual({key for key, value in outputs if key == value}, set(PATHS))
        for area in PATHS:
            with self.subTest(area=area):
                self.assertTrue(f"needs.changes.outputs.{area} != 'false'" in self.CI, f'no job reads the {area} area')
        self.assertEqual(set(re.findall(r'needs\.changes\.outputs\.(\w+)', self.CI)), set(PATHS))

    def test_scripts_of_the_merged_jobs_trigger_their_area(self):
        for area, body in [('shot', (ROOT/'.github/workflows/ux-shot.yml').read_text()),
                           ('exports', ci_job('package_tests'))]:
            scripts = re.findall(r'python3\s+(scripts/[\w.-]+\.py)', body)
            self.assertTrue(scripts, area)
            for script in scripts:
                with self.subTest(area=area, script=script):
                    self.assertTrue(changes.select('pull_request', 'base', PATHS, [script])[area])

    def test_one_intel_job_runs_each_area_only_when_selected(self):
        job = ci_job('package_tests')
        self.assertIn('runs-on: macos-15-intel', job)
        self.assertIn("needs.changes.outputs.exports != 'false' || needs.changes.outputs.model_download != 'false'", job)
        downloader = job.index('--filter ModelDownloaderTests')
        self.assertIn("if: env.MODEL_DOWNLOAD == 'true'", job[:downloader])
        # D66 mac-P1-3: no setup-python before the downloader's fixture server.
        self.assertLess(downloader, job.index('actions/setup-python'))
        exports = job.index("--filter 'ExportGoldenTests|")
        self.assertLess(exports, job.index('check-export-reference.py'))
        # Each exports step's own condition (not a neighbour's) names the area.
        for marker in ['- uses: actions/setup-python', '      id: exports\n', '- name: Independent pure metadata',
                       'name: exports-macos-15-intel']:
            with self.subTest(step=marker):
                self.assertIn("env.EXPORTS == 'true'", step_condition(job, marker))
        self.assertIn("env.MODEL_DOWNLOAD == 'true'", step_condition(job, 'name: downloader-macos-15-intel'))
        # No other job repeats the Intel downloader or the export filter on any runner.
        others = self.CI.replace(job, '')
        for workflow in (ROOT/'.github/workflows').glob('*.yml'):
            text = others if workflow.name == 'ci.yml' else workflow.read_text()
            with self.subTest(workflow=workflow.name):
                self.assertNotIn('--filter ModelDownloaderTests', text)
                self.assertNotIn("--filter 'ExportGoldenTests|", text)

    def test_kit_runs_the_arm64_export_checks(self):
        kit = ci_job('kit')
        self.assertIn("assets: 'true'", kit)
        test = kit[kit.index('- name: Test\n'):kit.index('run: swift test --skip-build\n')]
        self.assertIn('CASSINI_OPUS_ASSETS: ${{ github.workspace }}/build/Opus', test)
        self.assertIn('CASSINI_EXPORT_REPORT_DIR: ${{ github.workspace }}/build/export-cases', test)
        self.assertIn('python3 scripts/check-export-reference.py build/format-reference build/export-cases', kit)

    def test_window_captures_run_before_the_display_mode_changes(self):
        shot = (ROOT/'.github/workflows/ux-shot.yml').read_text()
        self.assertEqual(shot.count('runs-on:'), 1)
        self.assertLess(shot.index('python3 scripts/check-window-screenshots.py build/window-screenshots\n'),
                        shot.index('python3 scripts/hosted-display.py'))
        self.assertLess(shot.index('python3 scripts/hosted-display.py'),
                        shot.index('python3 scripts/check-window-screenshots.py build/board-screenshots 1120x720'))
        self.assertFalse((ROOT/'.github/workflows/ux-board-shot.yml').exists())


class Transport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.patch = patch.object(products, 'ROOT', self.root); self.patch.start()
        self.identity = dict(kind='swiftpm', commit='a'*40, arch='arm64', xcode='Xcode 16.4', pins={})
        self.identity_patch = patch.object(products, 'identity', return_value=self.identity); self.identity_patch.start()
        folder = self.root/'.build/arm64/debug'; folder.mkdir(parents=True)
        self.executable = folder/'worker'; self.executable.write_bytes(b'fixture'); self.executable.chmod(0o755)
        (self.root/'.build/debug').symlink_to('arm64/debug')
        self.output = self.root/'upload'

    def tearDown(self):
        self.identity_patch.stop(); self.patch.stop(); self.temp.cleanup()

    def test_stale_opus_pin_is_rejected_before_staging(self):
        source=self.root/'assets/Opus';source.mkdir(parents=True)
        expected=self.root/'Opus';expected.mkdir()
        (expected/'pins.json').write_text('{"version":"new"}')
        (source/'pins.json').write_text('{"version":"old"}')
        (source/'unsigned-sha256.json').write_text('{}')
        destination=self.root/'staged'
        with patch.dict(os.environ,CASSINI_CI_ASSETS=str(self.root/'assets')):
            with self.assertRaisesRegex(ValueError,'Opus pin mismatch'):
                products.stage_assets('Opus',destination)
            self.assertFalse(destination.exists())
            (source/'pins.json').write_text((expected/'pins.json').read_text())
            products.stage_assets('Opus',destination)
            self.assertEqual((destination/'pins.json').read_bytes(),(expected/'pins.json').read_bytes())

    def test_archive_preserves_executable_and_relative_link(self):
        products.pack('swiftpm', self.output)
        self.executable.unlink()
        products.unpack('swiftpm', self.output)
        self.assertTrue(os.access(self.executable, os.X_OK))
        self.assertEqual((self.root/'.build/debug/worker').read_bytes(), b'fixture')

    def test_different_commit_or_arch_is_rejected_before_extract(self):
        products.pack('swiftpm', self.output)
        for key in ['commit', 'arch', 'xcode', 'pins']:
            with self.subTest(key=key), patch.object(products, 'identity', return_value={**self.identity,key:'different'}):
                with self.assertRaisesRegex(ValueError, 'do not match'): products.unpack('swiftpm',self.output)

    def test_modified_archive_is_rejected_before_extract(self):
        products.pack('swiftpm', self.output)
        with (self.output/'swiftpm.tar.gz').open('ab') as stream: stream.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'digest'): products.unpack('swiftpm',self.output)

    def test_an_incomplete_download_is_retryable_and_a_mismatch_is_not(self):
        products.pack('swiftpm', self.output)
        with (self.output/'swiftpm.tar.gz').open('ab') as stream: stream.write(b'truncated')
        with self.assertRaises(products.TransferError): products.unpack('swiftpm',self.output)
        (self.output/'swiftpm.tar.gz').unlink()
        with self.assertRaises(products.TransferError): products.unpack('swiftpm',self.output)
        products.pack('swiftpm', self.output)
        with patch.object(products, 'identity', return_value={**self.identity,'commit':'b'*40}):
            with self.assertRaises(ValueError) as caught: products.unpack('swiftpm',self.output)
        self.assertNotIsInstance(caught.exception, products.TransferError)

    def test_the_cli_exits_75_only_for_an_incomplete_download(self):
        products.pack('swiftpm', self.output)
        with (self.output/'swiftpm.tar.gz').open('ab') as stream: stream.write(b'truncated')
        with patch.object(products.sys,'argv',['ci-products.py','unpack','swiftpm',str(self.output)]), patch('sys.stderr',io.StringIO()):
            with self.assertRaises(SystemExit) as caught: products.main()
        self.assertEqual(caught.exception.code, products.TRANSFER_EXIT)
        products.pack('swiftpm', self.output)
        with patch.object(products.sys,'argv',['ci-products.py','unpack','swiftpm',str(self.output)]), \
             patch.object(products, 'identity', return_value={**self.identity,'arch':'x86_64'}):
            with self.assertRaisesRegex(ValueError,'do not match'): products.main()

    def test_release_tool_state_in_build_never_enters_the_swiftpm_product(self):
        # A restored .build cache held the DMG-tool venv, whose interpreter link is absolute.
        venv = self.root/'.build/dmg-tools-e0741352c4b67aea-3.15/bin'; venv.mkdir(parents=True)
        (venv/'python3.15').symlink_to('/opt/homebrew/opt/python@3.15/bin/python3.15')
        (venv/'python3').symlink_to('python3.15')
        cache = self.root/'.build/dmg-pip-cache/http'; cache.mkdir(parents=True); (cache/'entry').write_bytes(b'x')
        named = self.root/'.build/dmg-tools-notes.txt'; named.write_text('a file, not a tool directory')
        products.pack('swiftpm', self.output)
        with tarfile.open(self.output/'swiftpm.tar.gz') as packed: names = packed.getnames()
        self.assertFalse([n for n in names if n.startswith(('.build/dmg-tools-e', '.build/dmg-pip-cache'))], names)
        self.assertIn('.build/arm64/debug/worker', names); self.assertIn('.build/debug', names)
        self.assertIn('.build/dmg-tools-notes.txt', names, 'only the named directories are left out')
        products.unpack('swiftpm', self.output)
        # Any other external link still fails, packed or not.
        (self.root/'.build/escape').symlink_to('/opt/homebrew/bin/python3')
        products.pack('swiftpm', self.output)
        with self.assertRaisesRegex(ValueError, 'Unsafe product link: .build/escape'): products.unpack('swiftpm', self.output)

    def test_the_dmg_tools_live_outside_swiftpms_tree(self):
        release = (ROOT/'scripts/release.py').read_text(); build = (ROOT/'.github/workflows/ci-build.yml').read_text()
        self.assertIn("ROOT/'build'/('dmg-tools-'", release); self.assertIn("ROOT/'build/dmg-pip-cache'", release)
        self.assertNotIn(".build/dmg-", release); self.assertNotIn('.build/dmg-pip-cache', build)

    def test_traversal_and_external_links_are_rejected(self):
        for name, link in [('../outside', None), ('.build/link','../../outside'),('.build/link','/tmp/outside')]:
            with self.subTest(name=name,link=link):
                self.output.mkdir(exist_ok=True)
                archive=self.output/'swiftpm.tar.gz'
                with tarfile.open(archive,'w:gz') as target:
                    item=tarfile.TarInfo(name)
                    if link:
                        item.type=tarfile.SYMTYPE;item.linkname=link;target.addfile(item)
                    else:
                        item.size=1;target.addfile(item,io.BytesIO(b'x'))
                (self.output/'swiftpm.json').write_text(json.dumps({**self.identity,'sha256':products.digest(archive)}))
                with self.assertRaisesRegex(ValueError,'Unsafe'): products.unpack('swiftpm',self.output)


class Concurrency(unittest.TestCase):
    """D66 mac-P1-1: only a pull request's own newer run cancels it; every other run (push,
    nightly, manual) has a group of its own, so GitHub never cancels or replaces it while pending."""
    def test_only_pull_requests_share_a_cancellable_group(self):
        body = (ROOT/'.github/workflows/ci.yml').read_text()
        group = re.search(r'^concurrency:\n  group: (.+)\n  cancel-in-progress: (.+)$', body, re.M)
        self.assertIsNotNone(group)
        self.assertIn("github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)", group.group(1))
        self.assertIn("format('run-{0}', github.run_id)", group.group(1), 'non-PR runs need a unique group, not the commit')
        self.assertNotIn('github.sha', group.group(1))
        self.assertEqual(group.group(2).strip(), "${{ github.event_name == 'pull_request' }}")
class ProductDownloads(unittest.TestCase):
    """D66 mac-P0-4: the products action downloads strictly and retries an incomplete product
    once; its shell steps run here with a stub python3 standing in for ci-products.py."""
    ACTION = (ROOT/'.github/actions/ci-products/action.yml').read_text()
    KINDS = ['swiftpm','assets','parakeet','runtime','debug','release']

    def script(self, marker):
        lines = self.ACTION.split('\n')
        start = next(i for i,line in enumerate(lines) if marker in line)
        run = next(i for i in range(start,len(lines)) if lines[i].strip() == 'run: |')
        body = []
        for line in lines[run+1:]:
            if line.strip() and not line.startswith(' '*8): break
            body.append(line[8:])
        return '\n'.join(body)

    def run_step(self, marker, statuses, env):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder); stub = folder/'python3'
            stub.write_text('#!/bin/sh\n' + ''.join(f'[ "$3" = {kind} ] && exit {code}\n' for kind,code in statuses.items()) + 'exit 0\n')
            stub.chmod(0o755); output = folder/'output'; output.write_text('')
            result = subprocess.run(['bash','-e','-c',self.script(marker)],cwd=folder,capture_output=True,text=True,
                                    env={**os.environ,'PATH':f'{folder}:{os.environ["PATH"]}','GITHUB_OUTPUT':str(output),**env})
            return result, output.read_text()

    def test_downloads_are_strict_and_each_retried_at_most_once(self):
        self.assertNotIn('continue-on-error', self.ACTION)
        for kind in self.KINDS:
            with self.subTest(kind=kind):
                self.assertEqual(self.ACTION.count(f"if: inputs.{kind} == 'true'"), 2)
                self.assertEqual(self.ACTION.count(f"contains(steps.verify.outputs.retry, ' {kind} ')"), 1)

    def test_only_an_incomplete_product_is_downloaded_again_with_a_warning(self):
        env = {f'RESTORE_{kind.upper()}':'true' for kind in self.KINDS}
        result, output = self.run_step('- id: verify', {'debug':75}, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('retry= debug ', output); self.assertIn('::warning::CI product debug', result.stdout)
        result, _ = self.run_step('- id: verify', {'debug':1}, env)
        self.assertNotEqual(result.returncode, 0, 'any other mismatch fails at once')

    def test_a_second_incomplete_download_fails_the_job(self):
        result, _ = self.run_step("- if: steps.verify.outputs.retry != ' '", {'debug':75}, {'RETRY':' debug '})
        self.assertNotEqual(result.returncode, 0)
        result, _ = self.run_step("- if: steps.verify.outputs.retry != ' '", {}, {'RETRY':' debug '})
        self.assertEqual(result.returncode, 0)


class ParakeetCoverage(unittest.TestCase):
    def test_runtime_and_service_changes_recheck_all_app_consumers(self):
        for name in ['Parakeet/model-manifest.json','ModelDownloads/Service.swift']:
            self.assertTrue(all(changes.select('pull_request','base',PATHS,[name]).values()))

    def test_optional_golden_weights_do_not_enter_legacy_or_shipped_products(self):
        self.assertEqual(products.PRODUCTS['assets'],['build/Whistle','build/Opus'])
        self.assertEqual(products.PRODUCTS['parakeet'],['build/Parakeet','build/ParakeetModel'])
        self.assertEqual(products.PRODUCTS['runtime'],['build/Parakeet'])
        self.assertNotIn('build/ParakeetModel',products.PRODUCTS['debug'])
        self.assertNotIn('build/ParakeetModel',products.PRODUCTS['release'])


class ReleaseOffTheCriticalPath(unittest.TestCase):
    """D66 mac-P2-2: the Release app builds in its own job after the producer; only packaging and
    the Parakeet checks wait for it, so the Debug and SwiftPM consumers start without it."""
    WORKFLOWS = ROOT/'.github/workflows'

    def test_the_producer_no_longer_builds_release(self):
        producer = (self.WORKFLOWS/'ci-build.yml').read_text()
        self.assertNotIn('-configuration Release', producer)
        self.assertNotIn('ci-release', producer)
        self.assertIn('pack runtime', producer)
        release = (self.WORKFLOWS/'ci-build-release.yml').read_text()
        self.assertIn('-configuration Release', release)
        self.assertIn('pack release', release)
        self.assertIn('scripts/package-release.py', release)
        self.assertIn('name: Cassini-${{ github.sha }}', release)
        self.assertIn("assets: 'true'", release); self.assertIn("runtime: 'true'", release)

    def test_only_packaging_and_parakeet_wait_for_the_release_build(self):
        ci = (self.WORKFLOWS/'ci.yml').read_text()
        jobs = dict(re.findall(r'^  (\w+):\n(.*?)(?=^  \S|^\S|\Z)', ci.split('\njobs:\n',1)[1], re.M | re.S))
        self.assertIn('needs: [build]', jobs['build_release'])
        self.assertIn('uses: ./.github/workflows/ci-build-release.yml', jobs['build_release'])
        waiting = {name for name, body in jobs.items() if 'build_release' in body and name != 'build_release'}
        self.assertEqual(waiting, {'parakeet'})
        self.assertIn("needs.build_release.result == 'success'", jobs['parakeet'])
        for workflow in self.WORKFLOWS.glob('*.yml'):
            with self.subTest(workflow=workflow.name):
                restores = "release: 'true'" in workflow.read_text()
                self.assertEqual(restores, workflow.name == 'ux-parakeet.yml')
                self.assertEqual('package-release.py' in workflow.read_text(), workflow.name == 'ci-build-release.yml')
        standalone = (self.WORKFLOWS/'ux-parakeet.yml').read_text()
        self.assertIn('uses: ./.github/workflows/ci-build-release.yml', standalone)
        self.assertIn('needs: [build, release]', standalone)

    def test_no_workflow_publishes_a_github_release(self):
        # D58.4: a GitHub release carries only the exact QA-passed, notarized DMG that
        # publish-release.py put on cassini.talk, attached by hand. No workflow starts on a tag
        # or creates, edits or uploads to a release, so a CI build can never land on one.
        for workflow in self.WORKFLOWS.glob('*.yml'):
            with self.subTest(workflow=workflow.name):
                text = workflow.read_text()
                self.assertNotIn('tags:', text)
                self.assertNotRegex(text, r'gh\s+release|repos/[^\s]*/releases|softprops/action-gh-release|actions/create-release')
                self.assertNotIn('contents: write', text)

class Measurements(unittest.TestCase):
    def test_round_each_assigned_mac_job_and_exclude_queued_cancellations(self):
        run=dict(id=1,status='completed',conclusion='success',created_at='2026-01-01T00:00:00Z',updated_at='2026-01-01T00:03:00Z')
        jobs=[dict(runner_name='host',labels=['macos-15'],created_at='2026-01-01T00:00:00Z',started_at='2026-01-01T00:00:30Z',completed_at='2026-01-01T00:01:31Z',conclusion='success'),
              dict(runner_name='host',labels=['macos-15-intel'],created_at='2026-01-01T00:00:00Z',started_at='2026-01-01T00:01:30Z',completed_at='2026-01-01T00:02:00Z',conclusion='cancelled'),
              dict(runner_name='',labels=['macos-15'],conclusion='cancelled')]
        report=metrics.summarize([run],jobs)
        self.assertEqual(report['executed_macos_jobs'],2)
        self.assertEqual(report['macos_minutes_estimated'],3)
        self.assertEqual(report['median_macos_queue_seconds'],60)
        self.assertEqual(report['wall_minutes'],3)


if __name__ == '__main__': unittest.main()
