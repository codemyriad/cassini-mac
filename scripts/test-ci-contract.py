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
from types import SimpleNamespace
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

    def test_spectrogram_analysis_admission_and_fixture_changes_run_native_boards(self):
        for path in ['Sources/CassiniSpectrogram/Spectrum.swift', 'Sources/CassiniRecording/RecordingSink.swift',
                     'Sources/CassiniBrowserControl/OwnedBrowserCapture.swift',
                     'Sources/CassiniBrowserControl/StagedNativeWriter.swift',
                     'Sources/CassiniBrowserControl/CaptureInputLifecycle.swift',
                     'Tests/CassiniRecordingTests/SpectrogramFixtureClock.swift',
                     'Tests/CassiniRecordingTests/SpectrogramFixtureClockTests.swift']:
            with self.subTest(path=path):
                self.assertTrue(changes.select('pull_request','base',PATHS,[path])['boards'])

    def test_workflow_jobs_have_no_duplicate_top_level_keys(self):
        for workflow in (ROOT/'.github/workflows').glob('*.yml'):
            jobs=workflow.read_text().split('\njobs:\n',1)[-1]
            for match in re.finditer(r'^  ([\w-]+):\n(.*?)(?=^  \S|^\S|\Z)',jobs,re.M|re.S):
                keys=re.findall(r'^    ([\w-]+):',match.group(2),re.M)
                with self.subTest(workflow=workflow.name,job=match.group(1)):
                    self.assertEqual(len(keys),len(set(keys)),f'Duplicate job keys: {keys}')

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
        for name in ['.github/actions/ci-products/action.yml', 'scripts/ci-select-xcode.sh', 'scripts/ci-test-xcode.py', 'Sources/CassiniKit/Reader.swift', 'Tests/CassiniPlaybackTests/Seek.swift']:
            self.assertTrue(all(changes.select('pull_request', 'base', PATHS, [name]).values()))


class NativeSpectrogramScheduling(unittest.TestCase):
    """The measured 15 min boards + 9 min native probe must not share a 25 min job."""
    def test_native_measurements_have_their_own_bounded_hosted_job(self):
        body = (ROOT/'.github/workflows/ux-boards.yml').read_text()
        jobs = dict(re.findall(r'^  (\w+):\n(.*?)(?=^  \S|^\S|\Z)',body.split('\njobs:\n',1)[1],re.M|re.S))
        boards, native = jobs['boards'], jobs['spectrogram']
        self.assertIn('timeout-minutes: 25',boards)
        self.assertNotIn('test-spectrogram-app.py',boards)
        self.assertNotIn("release: 'true'",boards)
        self.assertNotIn('needs: [boards]',native)
        for requirement in ['runs-on: macos-15','needs: [build, release]',
                            'inputs.products_ready','!cancelled()',
                            "debug: 'true'","release: 'true'",'github-hosted',
                            'hosted-display.py','timeout-minutes: 15','timeout-minutes: 12',
                            'if: always()','name: ux-spectrogram']:
            self.assertIn(requirement,native)
        # Keep every production proof exactly once, including the motion XCTest
        # driver supplied by Debug products and the same-build optimized objects.
        for script in ['CheckBudget.swift','test-spectrogram-harness.py',
                       'CheckSampleClock.swift','build-spectrogram-probe.py','test-spectrogram-app.py']:
            self.assertEqual(body.count(script),1)
            self.assertIn(script,native)


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
        # The ARM kit job deliberately partitions its existing full-suite run;
        # its model filter and exact complement are checked below. No other job
        # may duplicate the downloader, and the Intel export filter stays unique.
        others = self.CI.replace(job, '')
        model_others = others.replace(ci_job('kit'), '')
        for workflow in (ROOT/'.github/workflows').glob('*.yml'):
            text = others if workflow.name == 'ci.yml' else workflow.read_text()
            model_text = model_others if workflow.name == 'ci.yml' else text
            with self.subTest(workflow=workflow.name):
                self.assertNotIn('--filter ModelDownloaderTests', model_text)
                self.assertNotIn("--filter 'ExportGoldenTests|", text)

    def test_arm64_full_suite_has_one_model_partition_and_its_exact_complement(self):
        kit = ci_job('kit')
        self.assertIn('runs-on: macos-15\n', kit)
        start = kit.index('    - name: Test\n')
        end = kit.index('\n    - ', start + 1)
        step = kit[start:end]
        self.assertNotRegex(step, r'(?m)^\s+if:', 'Both partitions must always run')
        commands = re.findall(
            r'^\s+python3 scripts/run-swift-tests.py --output (\S+) -- (.+)$',
            step, re.M)
        self.assertEqual(commands, [
            ('build/unit-tests/models', "swift test --skip-build --filter 'ModelDownloaderTests|ModelSupersessionTests'"),
            ('build/unit-tests/remaining', "swift test --skip-build --skip 'ModelDownloaderTests|ModelSupersessionTests'"),
        ])
        model_filter = 'ModelDownloaderTests|ModelSupersessionTests'
        self.assertEqual(kit.count("--filter '" + model_filter + "'"), 1)
        self.assertEqual(kit.count("--skip '" + model_filter + "'"), 1)
        for suite in ['ModelDownloaderTests', 'ModelSupersessionTests']:
            self.assertRegex(suite, model_filter)
        for suite in ['ModelManifestTests', 'D52WorstCaseRecordTests']:
            self.assertNotRegex(suite, model_filter)
        # Separate logs/stacks stay inside the single recursively uploaded artifact.
        self.assertIn('path: build/unit-tests\n', kit)

    def test_kit_runs_the_arm64_export_checks(self):
        kit = ci_job('kit')
        self.assertIn("assets: 'true'", kit)
        test = kit[kit.index('- name: Test\n'):kit.index('python3 scripts/run-swift-tests.py')]
        self.assertIn('-- swift test --skip-build',kit)
        self.assertIn('name: unit-tests-and-stacks',kit)
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


class RentedRunnerRouting(unittest.TestCase):
    def evaluate(self, expression, event, head, label, runner):
        expression=expression.strip().removeprefix('${{').removesuffix('}}').strip()
        expression=expression.replace('&&',' and ').replace('||',' or ')
        github=SimpleNamespace(event_name=event,repository='codemyriad/cassini-mac',
            event=SimpleNamespace(pull_request=SimpleNamespace(head=SimpleNamespace(repo=SimpleNamespace(full_name=head)))))
        return eval(expression,{'__builtins__':{}},{'github':github,'vars':SimpleNamespace(CM_MAC_RUNNER=label),
                    'matrix':SimpleNamespace(runner=runner)})

    def test_actual_expressions_route_only_trusted_arm_jobs_with_a_configured_runner(self):
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        worker=(ROOT/'.github/workflows/ux-whistle.yml').read_text().split('  worker:',1)[1].split('  bundle:',1)[0]
        for job in [producer,worker]:
            route=re.search(r'^    runs-on: (.+)$',job,re.M).group(1)
            for runner in ['macos-15','macos-15-intel']:
                for event,head,label,enabled in [('pull_request','codemyriad/cassini-mac','cm-mac-m4',True),
                    ('pull_request','fork/repo','cm-mac-m4',False),('pull_request','codemyriad/cassini-mac','',False),
                    ('push','','cm-mac-m4',True),('schedule','','cm-mac-m4',True),('workflow_dispatch','','',False)]:
                    with self.subTest(runner=runner,event=event,head=head,label=label):
                        expected='cm-mac-m4' if enabled and runner=='macos-15' else runner
                        self.assertEqual(self.evaluate(route,event,head,label,runner),expected)
        rows=re.findall(r'- runner: (\S+)\n\s+arch: (\S+)',producer)
        self.assertEqual(rows,[('macos-15','arm64'),('macos-15-intel','x86_64')])

    def test_constrained_jobs_and_all_original_artifact_names_remain_hosted(self):
        self.assertIn('runs-on: macos-15\n',ci_job('kit'))
        self.assertIn('runs-on: macos-15-intel',ci_job('package_tests'))
        for name in ['ux-shot.yml','ux-boards.yml','ux-parakeet.yml','ux-browser-setup.yml','ci-build-release.yml']:
            self.assertNotIn('CM_MAC_RUNNER',(ROOT/'.github/workflows'/name).read_text(),name)
        body=(ROOT/'.github/workflows/ux-whistle.yml').read_text().split('  bundle:',1)[1]
        self.assertIn('runs-on: macos-15',body)
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        action=(ROOT/'.github/actions/ci-products/action.yml').read_text()
        self.assertIn('name: ci-swiftpm-${{ matrix.arch }}\n',producer)
        self.assertIn('name: ci-swiftpm-${{ steps.arch.outputs.name }}\n',action)
        for name in ['ci-assets','ci-runtime','ci-parakeet','ci-debug']:
            self.assertIn('name: '+name+'\n',producer)
            self.assertIn('name: '+name+'\n',action)
        self.assertIn('name: ci-release\n',action)
        self.assertNotIn('-headless',producer+action)

    def test_producers_and_restorers_select_the_same_xcode_and_fingerprint_caches(self):
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        action=(ROOT/'.github/actions/ci-products/action.yml').read_text()
        for body in [producer,action]:
            self.assertIn('bash scripts/ci-select-xcode.sh',body)
            self.assertNotIn('sudo xcode-select',body)
        keys=[line for line in producer.splitlines() if any(marker in line for marker in
            ['key: swiftpm-','restore-keys: swiftpm-','key: pinned-fetches-','restore-keys: pinned-fetches-'])]
        self.assertEqual(len(keys),4)
        for line in keys:self.assertIn('steps.xcode.outputs.fingerprint',line)
        self.assertIn('scripts/ci-test-xcode.py',ci_job('changes'))


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

    def test_release_consumers_wait_for_the_release_build(self):
        ci = (self.WORKFLOWS/'ci.yml').read_text()
        jobs = dict(re.findall(r'^  (\w+):\n(.*?)(?=^  \S|^\S|\Z)', ci.split('\njobs:\n',1)[1], re.M | re.S))
        self.assertIn('needs: [build]', jobs['build_release'])
        self.assertIn('uses: ./.github/workflows/ci-build-release.yml', jobs['build_release'])
        waiting = {name for name, body in jobs.items() if 'build_release' in body and name != 'build_release'}
        self.assertEqual(waiting, {'parakeet','boards'})
        self.assertIn("needs.build_release.result == 'success'", jobs['boards'])
        self.assertIn("needs.build_release.result == 'success'", jobs['parakeet'])
        for workflow in self.WORKFLOWS.glob('*.yml'):
            with self.subTest(workflow=workflow.name):
                restores = "release: 'true'" in workflow.read_text()
                self.assertEqual(restores, workflow.name in {'ux-parakeet.yml','ux-boards.yml'})
                self.assertEqual('package-release.py' in workflow.read_text(), workflow.name == 'ci-build-release.yml')
        for name in ['ux-parakeet.yml','ux-boards.yml']:
            standalone = (self.WORKFLOWS/name).read_text()
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
