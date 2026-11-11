#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI regression checks: fail-open selection and tamper-resistant product transport."""
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import shutil
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
            for script in re.findall(r'(?:python3|node(?: --test)?)\s+(scripts/[\w.-]+\.(?:py|mjs))',body):
                with self.subTest(area=area,script=script):
                    self.assertTrue(changes.select('pull_request','base',PATHS,[script])[area])
        # Imported helpers must also select the real browser consumer on their
        # own, without relying on a workflow edit to select every area.
        self.assertTrue(changes.select('pull_request','base',PATHS,['scripts/wait-for-change.mjs'])['browser_setup'])
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
        self.assertRegex(job, r"(?m)^    runs-on: .+ \|\| 'macos-15-intel' \}\}$")
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

    def test_full_suite_partitions_keep_models_native_and_real_bookmark_coverage(self):
        kit = ci_job('kit')
        self.assertIn('vars.CM_MAC_RUNNER', kit)
        start = kit.index('    - name: Test\n')
        end = kit.index('\n    - ', start + 1)
        step = kit[start:end]
        self.assertNotRegex(step, r'(?m)^\s+if:', 'Both partitions must always run')
        commands = re.findall(
            r'^\s+python3 scripts/run-swift-tests.py --output (\S+) -- (.+)$',
            step, re.M)
        self.assertEqual(commands, [
            ('build/unit-tests/models', "swift test --skip-build --filter 'ModelDownloaderTests|ModelSupersessionTests'"),
            ('build/unit-tests/remaining', "swift test --skip-build --skip 'ModelDownloaderTests|ModelSupersessionTests|recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication'"),
        ])
        model_filter = 'ModelDownloaderTests|ModelSupersessionTests'
        self.assertEqual(kit.count("--filter '" + model_filter + "'"), 1)
        bookmark = 'recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication'
        native_skip = model_filter + '|' + bookmark
        self.assertEqual(kit.count("--skip '" + native_skip + "'"), 1)
        sink = ci_job('native_sink')
        self.assertIn('runs-on: macos-15\n', sink)
        self.assertIn("swiftpm: 'true'", sink)
        self.assertIn(' -- swift test --skip-build --filter ' + bookmark + '\n', sink)
        self.assertIn('name: scoped-bookmark-${{ github.sha }}', sink)
        self.assertEqual(self.CI.count('--filter ' + bookmark + '\n'), 1)
        self.assertIn("--filter 'Library|SearchTests' --skip " + bookmark, kit)
        for suite in ['ModelDownloaderTests', 'ModelSupersessionTests', bookmark,
                      'ModelManifestTests', 'D52WorstCaseRecordTests']:
            # Exactly one full-suite partition admits each example, including the real OS test.
            admitted = [bool(re.search(model_filter, suite)), not bool(re.search(native_skip, suite)),
                        suite == bookmark]
            self.assertEqual(sum(admitted), 1, suite)
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
        payload=SimpleNamespace(pull_request=SimpleNamespace(head=SimpleNamespace(repo=SimpleNamespace(full_name=head)))) if event=='pull_request' else SimpleNamespace()
        github=SimpleNamespace(event_name=event,repository='codemyriad/cassini-mac',event=payload)
        return eval(expression,{'__builtins__':{}},{'github':github,'vars':SimpleNamespace(CM_MAC_RUNNER=label,CM_MAC_GUI_RUNNER=label),
                    'matrix':SimpleNamespace(runner=runner)})

    def worker(self):
        return (ROOT/'.github/workflows/ux-whistle.yml').read_text().split('  worker:',1)[1].split('  bundle:',1)[0]

    def test_actual_expressions_route_only_trusted_jobs_with_a_configured_runner(self):
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        # Evaluate every actual rented-runner expression, including reusable workflows.
        routes=[]
        for path in sorted((ROOT/'.github/workflows').glob('*.yml')):
            for route in re.findall(r'^    runs-on: (.+)$',path.read_text(),re.M):
                if 'vars.CM_MAC' in route:
                    routes.append((path.name,route))
        self.assertEqual(len(routes),8)
        events=['push','schedule','workflow_dispatch','pull_request',
                'pull_request_target','workflow_run','issue_comment','workflow_call',
                'release','repository_dispatch','deployment_status','check_run','unknown']
        for name,route in routes:
            for runner in ['macos-15','macos-15-intel']:
                fallback_match=re.search(r"\|\| (matrix\.runner|'([^']+)') \}\}$",route)
                self.assertIsNotNone(fallback_match,route)
                fallback=runner if fallback_match.group(1)=='matrix.runner' else fallback_match.group(2)
                self.assertIn(fallback,['macos-15','macos-15-intel'])
                for event in events:
                    for head in ['codemyriad/cassini-mac','fork/repo','']:
                        for label in ['cm-mac-m4','']:
                            trusted=event in ['push','schedule','workflow_dispatch'] or (event=='pull_request' and head=='codemyriad/cassini-mac')
                            expected=label if trusted and label else fallback
                            with self.subTest(workflow=name,route=route,runner=runner,event=event,head=head,label=label):
                                self.assertEqual(self.evaluate(route,event,head,label,runner),expected)
        for job in [producer,self.worker()]:
            rows=re.findall(r'- runner: (\S+)\n\s+arch: (\S+)',job)
            self.assertEqual(rows,[('macos-15','arm64'),('macos-15-intel','x86_64')])

    def test_screenshot_derived_data_is_job_owned_and_cleaned_around_artifacts(self):
        shot=(ROOT/'.github/workflows/ux-shot.yml').read_text()
        self.assertEqual(shot.count('-derivedDataPath "$RUNNER_TEMP/cassini-window-screenshots-derived-data"'),2)
        self.assertEqual(shot.count('run: rm -rf -- "$RUNNER_TEMP/cassini-window-screenshots-derived-data"'),2)
        self.assertLess(shot.index('- name: Clean interrupted screenshot DerivedData'),shot.index('- uses: actions/checkout'))
        cleanup=shot.index('- name: Clean screenshot DerivedData after artifact upload')
        self.assertGreater(cleanup,shot.rindex('- uses: actions/upload-artifact'))
        self.assertIn('if: always()',shot[cleanup:])

    def test_intel_products_are_named_cross_built_and_run_as_x86_64_wherever_the_job_lands(self):
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        action=(ROOT/'.github/actions/ci-products/action.yml').read_text()
        # The producer names its row's architecture for the compiler and for the packed identity.
        self.assertIn('      CASSINI_CI_ARCH: ${{ matrix.arch }}\n',producer)
        self.assertIn('run: swift build --build-tests --arch ${{ matrix.arch }}\n',producer)
        self.assertEqual(producer.count('swift build'),1)
        # Restoring picks the same name and proves the machine executes it before any download.
        self.assertIn('run: bash scripts/ci-product-arch.sh\n',action)
        self.assertNotIn('uname',action)
        self.assertLess(action.index('scripts/ci-product-arch.sh'),action.index('actions/download-artifact'))
        # Every routed consumer of x86_64 products runs each of its own steps as x86_64.
        package=ci_job('package_tests')
        self.assertIn('      CASSINI_CI_ARCH: x86_64\n',package)
        self.assertIn('    defaults:\n      run:\n        shell: arch -x86_64 /bin/bash --noprofile --norc -eo pipefail {0}\n',package)
        worker=self.worker()
        self.assertIn('      CASSINI_CI_ARCH: ${{ matrix.arch }}\n',worker)
        self.assertIn('    defaults:\n      run:\n        shell: arch -${{ matrix.arch }} /bin/bash --noprofile --norc -eo pipefail {0}\n',worker)
        for job in [package,worker]:
            self.assertNotRegex(job,r'(?m)^\s+shell: (?!arch -)','no step may leave the product architecture')
            self.assertNotIn('swift build',job)
        # Hosted runners install Python 3.12. A rented Mac cannot (the installer needs /Users/runner):
        # its Intel Whistle row uses the selected Xcode's universal Python, and the worker job checks
        # the interpreter has the products' architecture before it compiles its constructor fixture.
        self.assertRegex(step_condition(package,'- uses: actions/setup-python'),r"&& runner\.environment == 'github-hosted' \}\}$")
        self.assertEqual("runner.environment == 'github-hosted'",step_condition(worker,'- uses: actions/setup-python'))
        marker="- name: Use the selected Xcode's universal Python for the Intel row on a rented Mac"
        self.assertEqual("runner.environment != 'github-hosted' && matrix.arch == 'x86_64'",step_condition(worker,marker))
        rented=worker[worker.index(marker):];rented=rented[:rented.index('\n    - ',1)]
        self.assertIn('ln -sf "$(xcrun -f python3)" "$RUNNER_TEMP/python/python3"\n',rented)
        self.assertIn('echo "$RUNNER_TEMP/python" >> "$GITHUB_PATH"',rented)
        check='''    - run: test "$(python3 -c 'import platform; print(platform.machine())')" = "$CASSINI_CI_ARCH"\n'''
        self.assertLess(worker.index(marker),worker.index(check))
        self.assertLess(worker.index(check),worker.index('scripts/test-whistle-worker.py'))
        # The artifact names of the Intel reports are unchanged.
        self.assertIn('name: whistle-${{ matrix.runner }}\n',worker)
        for name in ['name: downloader-macos-15-intel\n','name: exports-macos-15-intel\n']:self.assertIn(name,package)

    def test_unqualified_gui_jobs_and_artifact_names_remain_hosted(self):
        self.assertIn('runs-on: macos-15\n',ci_job('native_sink'))
        # App, XPC and GUI jobs need a login session; both their architectures stay hosted.
        for name in ['ux-parakeet.yml','ux-browser-setup.yml']:
            body=(ROOT/'.github/workflows'/name).read_text().split('\n  parakeet:\n' if name == 'ux-parakeet.yml' else '  setup:',1)[1]
            self.assertIn('runner: [macos-15, macos-15-intel]\n',body)
            self.assertIn('runs-on: ${{ matrix.runner }}\n',body)
            self.assertNotIn('CASSINI_CI_ARCH',body)
            # Their hosted Intel row compiles SwiftPM itself after a rented Mac built the products.
            job=body[body.index('runner: [macos-15, macos-15-intel]'):]
            self.assertEqual(re.search(r'(?m)^    timeout-minutes: (\d+)$',job).group(1),'25',name)
        for name in ['ux-shot.yml']:
            gui=(ROOT/'.github/workflows'/name).read_text()
            self.assertIn('vars.CM_MAC_GUI_RUNNER',gui,name) # Event matrix above evaluates the actual selector.
            self.assertIn('python3 scripts/gui_session.py',gui,name)
            self.assertNotIn('cancel-in-progress: true',gui,name)
            self.assertNotIn('concurrency:',gui,name) # One runner queues all GUI jobs without dropping pending work.
            self.assertNotIn('CM_MAC_RUNNER',gui,name)

        boards=(ROOT/'.github/workflows/ux-boards.yml').read_text()
        self.assertNotIn('CM_MAC_GUI_RUNNER',boards)
        self.assertIn('runs-on: macos-15',boards)
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

    def test_split_jobs_preserve_each_native_and_app_proof_once(self):
        parakeet=(ROOT/'.github/workflows/ux-parakeet.yml').read_text()
        runtime,app=parakeet.split('  runtime:',1)[1].split('\n  parakeet:\n',1)
        self.assertIn('needs: [build]\n',runtime)
        self.assertNotIn("release: 'true'",runtime)
        for marker in ["--filter 'Parakeet|ProgressTests'",'scripts/test-parakeet-worker.py']:
            self.assertEqual(parakeet.count(marker),1)
            self.assertIn(marker,runtime)
        for marker in ['scripts/test-model-network-app.py','scripts/test-parakeet-app.py']:
            self.assertEqual(parakeet.count(marker),1)
            self.assertIn(marker,app)
        self.assertIn('name: parakeet-runtime-${{ matrix.runner }}',runtime)
        self.assertIn('name: parakeet-${{ matrix.runner }}',app)
        self.assertIn("if: runner.environment == 'github-hosted'",runtime)
        self.assertIn('test "$(python3 -c',runtime)
        self.assertIn('ln -sf "$(xcrun -f python3)"',runtime)
        browser=(ROOT/'.github/workflows/ux-browser-setup.yml').read_text()
        control,setup=browser.split('  control:',1)[1].split('  setup:',1)
        for marker in ["--filter 'CassiniBrowserControlTests|CassiniBrowserSetupTests|CassiniSpectrogramTests'",
                       'conformance/check-call-lifecycle.py','conformance/control/run.py']:
            self.assertEqual(browser.count(marker),1)
            self.assertIn(marker,control)
        self.assertIn('scripts/test-browser-connect.py',setup)
        self.assertIn('python3 -m venv "$RUNNER_TEMP/control-python"',control)
        kit,sink=ci_job('kit'),ci_job('native_sink')
        self.assertNotIn('scripts/run-native-ci.py',kit)
        self.assertEqual(sink.count('scripts/run-native-ci.py --mode sink-only'),1)
        self.assertIn('name: native-recording-${{ github.sha }}',sink)
        self.assertIn('python3 -m venv "$RUNNER_TEMP/conformance-python"',kit)
        self.assertEqual("runner.environment == 'github-hosted'",step_condition(kit,'- uses: actions/setup-python'))
        for job in [runtime,control]:
            self.assertIn('CASSINI_CI_ARCH: ${{ matrix.arch }}',job)
            self.assertIn('shell: arch -${{ matrix.arch }} /bin/bash --noprofile --norc -eo pipefail {0}',job)
            self.assertEqual(re.findall(r'- runner: (\S+)\n\s+arch: (\S+)',job),
                             [('macos-15','arm64'),('macos-15-intel','x86_64')])

    def test_producers_and_restorers_select_the_same_xcode_and_fingerprint_caches(self):
        producer=(ROOT/'.github/workflows/ci-build.yml').read_text()
        action=(ROOT/'.github/actions/ci-products/action.yml').read_text()
        for body in [producer,action]:
            self.assertIn('bash scripts/ci-select-xcode.sh',body)
            self.assertNotIn('sudo xcode-select',body)
        keys=[line for line in producer.splitlines() if any(marker in line for marker in
            ['key: swiftpm-','restore-keys: swiftpm-','key: pinned-fetches-','restore-keys: pinned-fetches-'])]
        self.assertEqual(len(keys),3)
        for line in keys:self.assertIn('steps.xcode.outputs.fingerprint',line)
        for line in keys:
            if 'swiftpm-' in line:self.assertIn('steps.xcode.outputs.workspace',line)
            else:self.assertNotIn('steps.xcode.outputs.workspace',line)
        self.assertIn('scripts/ci-test-xcode.py',ci_job('changes'))


class CompiledCacheCoherence(unittest.TestCase):
    def test_changed_inputs_cannot_restore_partial_compiled_objects(self):
        body=(ROOT/'.github/workflows/ci-build.yml').read_text()
        cache=body.split('path: .build\n',1)[1].split('      - name:',1)[0]
        self.assertNotIn('restore-keys:',cache,"Cross-input restoration can retain an incompatible native client")
        key=re.search(r'(?m)^\s+key: (.+)$',cache).group(1)
        self.assertIn('steps.swiftpm_key.outputs.hash',key)
        self.assertIn('matrix.arch',key)
        self.assertIn('steps.xcode.outputs.fingerprint',key)
        self.assertIn('steps.xcode.outputs.workspace',key)
        self.assertNotIn('key: swiftpm-${{ matrix.arch }}',cache,"Invalidate already-saved incoherent objects")
        inputs=body.split('- id: swiftpm_key',1)[1].split('- uses:',1)[0]
        for pattern in ('Package.swift','Package.resolved','Sources/**','Tests/**'):
            self.assertIn(pattern,inputs)


class ProductArchitecture(unittest.TestCase):
    """scripts/ci-product-arch.sh with private fake `uname`, `arch` and `sudo` commands."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.bin=self.root/'bin';self.bin.mkdir()
        self.state=self.root/'translation'
        self.tool('uname','printf "%s\\n" "$FAKE_MACHINE"')
        # A machine runs its own architecture; Apple Silicon also runs x86_64 once translation exists.
        self.tool('arch','[[ "$2 $3" = "/usr/bin/uname -m" ]]\nwant="${1#-}"\n'
                  'if [[ "$want" = "$FAKE_MACHINE" || ( "$FAKE_MACHINE" = arm64 && "$want" = x86_64 && -e "$FAKE_STATE" ) ]]; then printf "%s\\n" "$want"\n'
                  'else echo "arch: Bad CPU type in executable" >&2; exit 1; fi')
        self.tool('sudo','[[ "$*" = "-n softwareupdate --install-rosetta --agree-to-license" ]]\necho called >> "$FAKE_SUDO_LOG"\n'
                  '[[ "$FAKE_SUDO" = works ]] || exit 1\n: > "$FAKE_STATE"')

    def tool(self,name,body):
        path=self.bin/name;path.write_text('#!/bin/bash\nset -eu\n'+body+'\n');path.chmod(0o755)

    def run_script(self,machine,requested=None,translation=False,sudo='fails'):
        if translation:self.state.write_text('')
        elif self.state.exists():self.state.unlink()
        output=self.root/'outputs';output.write_text('');log=self.root/'sudo.log';log.write_text('')
        env=self.environment(machine,requested,sudo,output,log)
        result=subprocess.run(['/bin/bash',str(ROOT/'scripts/ci-product-arch.sh')],env=env,capture_output=True,text=True)
        self.assertFalse((self.root/'install.lock').exists(),'the install lock is always released')
        return result,output.read_text(),log.read_text().count('called')

    def environment(self,machine,requested,sudo,output,log):
        env=dict(PATH=str(self.bin)+':/usr/bin:/bin',GITHUB_OUTPUT=str(output),FAKE_MACHINE=machine,FAKE_STATE=str(self.state),
                 FAKE_SUDO=sudo,FAKE_SUDO_LOG=str(log),CI_ROSETTA_LOCK=str(self.root/'install.lock'),FAKE_RELEASE=str(self.root/'release'))
        if requested is not None:env['CASSINI_CI_ARCH']=requested
        return env

    def test_two_runners_of_one_mac_install_once_and_both_continue(self):
        # softwareupdate refuses a second concurrent install. The fake installer does the same and
        # only finishes once the test has seen the second runner waiting for the first.
        self.tool('sudo','[[ "$*" = "-n softwareupdate --install-rosetta --agree-to-license" ]]\necho called >> "$FAKE_SUDO_LOG"\n'
                  'mkdir "$FAKE_STATE.installing" || exit 1\nIFS= read -r release < "$FAKE_RELEASE"\n: > "$FAKE_STATE"\nrmdir "$FAKE_STATE.installing"')
        os.mkfifo(self.root/'release')
        outputs=[self.root/'first.out',self.root/'second.out'];log=self.root/'sudo.log';log.write_text('')
        for output in outputs:output.write_text('')
        start=lambda output:subprocess.Popen(['/bin/bash',str(ROOT/'scripts/ci-product-arch.sh')],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                             env=self.environment('arm64','x86_64','works',output,log))
        first=start(outputs[0])
        self.addCleanup(lambda:[process.kill() for process in (first,) if process.poll() is None])
        self.assertEqual(first.stdout.readline(),'Rosetta 2 is missing on this runner; installing it\n')
        second=start(outputs[1])
        self.addCleanup(lambda:[process.kill() for process in (second,) if process.poll() is None])
        self.assertEqual(second.stderr.readline(),'Another runner is installing Rosetta 2; waiting for it\n')
        self.assertIsNone(second.poll(),'the second runner must not fail while the first installs')
        (self.root/'release').write_text('continue\n')
        for process,output in zip([first,second],outputs):
            self.assertEqual(process.wait(timeout=60),0,process.stderr.read())
            self.assertEqual(output.read_text(),'name=x86_64\n')
            process.stdout.close();process.stderr.close()
        self.assertEqual(log.read_text().count('called'),1)
        self.assertFalse((self.root/'install.lock').exists())

    def test_an_abandoned_install_lock_fails_clearly_without_a_second_installer(self):
        (self.root/'install.lock').mkdir()
        output=self.root/'outputs';output.write_text('');log=self.root/'sudo.log';log.write_text('')
        env=dict(self.environment('arm64','x86_64','works',output,log),CI_ROSETTA_WAIT='0')
        result=subprocess.run(['/bin/bash',str(ROOT/'scripts/ci-product-arch.sh')],env=env,capture_output=True,text=True)
        self.assertEqual((result.returncode,output.read_text(),log.read_text()),(1,'',''))
        self.assertIn('cannot execute x86_64 products',result.stderr)
        self.assertTrue((self.root/'install.lock').is_dir(),'another runner owns it')

    def test_a_job_without_a_named_architecture_uses_the_machines_own(self):
        for machine in ['arm64','x86_64']:
            with self.subTest(machine=machine):
                result,output,installs=self.run_script(machine)
                self.assertEqual((result.returncode,output,installs),(0,'name='+machine+'\n',0),result.stderr)

    def test_hosted_intel_and_translating_apple_silicon_both_name_x86_64(self):
        for machine,translation in [('x86_64',False),('arm64',True)]:
            with self.subTest(machine=machine):
                result,output,installs=self.run_script(machine,'x86_64',translation)
                self.assertEqual((result.returncode,output,installs),(0,'name=x86_64\n',0),result.stderr)
        result,output,installs=self.run_script('arm64','arm64')
        self.assertEqual((result.returncode,output,installs),(0,'name=arm64\n',0),result.stderr)

    def test_missing_translation_is_installed_once_or_fails_before_any_product_is_named(self):
        result,output,installs=self.run_script('arm64','x86_64',sudo='works')
        self.assertEqual((result.returncode,output,installs),(0,'name=x86_64\n',1),result.stderr)
        result,output,installs=self.run_script('arm64','x86_64',sudo='fails')
        self.assertEqual((result.returncode,output,installs),(1,'',1))
        self.assertIn('cannot execute x86_64 products',result.stderr)

    def test_products_this_machine_can_never_run_or_unknown_names_fail(self):
        result,output,installs=self.run_script('x86_64','arm64',sudo='works')
        self.assertEqual((result.returncode,output,installs),(1,'',0))
        self.assertIn('cannot execute arm64 products',result.stderr)
        for name in ['universal','x86_64 ','i386']:
            with self.subTest(name=name):
                result,output,installs=self.run_script('arm64',name,translation=True)
                self.assertEqual((result.returncode,output,installs),(1,'',0))
                self.assertIn('Unsupported CASSINI_CI_ARCH',result.stderr)


class Transport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.patch = patch.object(products, 'ROOT', self.root); self.patch.start()
        self.identity = dict(kind='swiftpm', commit='a'*40, arch='arm64', xcode='Xcode 16.4', pins={},workspace=str(self.root))
        self.identity_patch = patch.object(products, 'identity', return_value=self.identity); self.identity_patch.start()
        arch = patch.dict(os.environ, CASSINI_CI_ARCH='arm64'); arch.start(); self.addCleanup(arch.stop)
        folder = self.root/'.build/arm64/debug'; folder.mkdir(parents=True)
        self.macho = self.thin(0x0100000c)
        self.executable = folder/'worker'; self.executable.write_bytes(self.macho); self.executable.chmod(0o755)
        self.tests = folder/'CassiniKitPackageTests.xctest/Contents/MacOS/CassiniKitPackageTests'
        self.tests.parent.mkdir(parents=True); self.tests.write_bytes(self.macho)
        (self.root/'.build/debug').symlink_to('arm64/debug')
        self.output = self.root/'upload'

    def tearDown(self):
        self.identity_patch.stop(); self.patch.stop(); self.temp.cleanup()

    @staticmethod
    def thin(cpu, magic=b'\xcf\xfa\xed\xfe'):
        """A minimal Mach-O header: enough for the architecture check, never executed."""
        return magic + cpu.to_bytes(4, 'little') + b'\0'*24

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
        self.assertEqual((self.root/'.build/debug/worker').read_bytes(), self.macho)

    def test_relocated_swiftpm_is_not_extracted_and_builds_in_the_consumer(self):
        products.pack('swiftpm', self.output)
        self.executable.unlink()
        consumer = {**self.identity, 'workspace': '/private/other-runner/checkout'}
        with patch.object(products, 'identity', return_value=consumer):
            with self.assertRaises(products.WorkspaceMismatch):
                products.unpack('swiftpm', self.output)
            self.assertFalse(self.executable.exists())
            with patch.object(products.subprocess, 'run') as build:
                products.restore('swiftpm', self.output)
                build.assert_called_once_with(['swift','build','--build-tests','--arch','arm64'],cwd=self.root,check=True)
            # A rented Mac compiles the job's architecture, not its own, and checks the result.
            intel,arm=self.thin(0x01000007),self.macho
            with patch.dict(os.environ,CASSINI_CI_ARCH='x86_64'),patch.object(products,'identity',return_value={**consumer,'arch':'x86_64'}):
                (self.output/'swiftpm.json').write_text(json.dumps({**json.loads((self.output/'swiftpm.json').read_text()),'arch':'x86_64'}))
                self.executable.write_bytes(intel);self.tests.write_bytes(intel)
                with patch.object(products.subprocess, 'run') as build:
                    products.restore('swiftpm', self.output)
                    build.assert_called_once_with(['swift','build','--build-tests','--arch','x86_64'],cwd=self.root,check=True)
                for worker,tests,message in [(arm,intel,'worker is arm64, not x86_64'),(intel,arm,'CassiniKitPackageTests is arm64, not x86_64')]:
                    self.executable.write_bytes(worker);self.tests.write_bytes(tests)
                    with patch.object(products.subprocess, 'run'):
                        with self.assertRaisesRegex(ValueError,message): products.restore('swiftpm', self.output)
                # A build that leaves no test bundle where consumers load it is not accepted either.
                self.executable.write_bytes(intel);self.tests.unlink()
                with patch.object(products.subprocess, 'run'):
                    with self.assertRaisesRegex(ValueError,'No x86_64 test bundle'): products.restore('swiftpm', self.output)
            self.tests.write_bytes(arm);self.executable.unlink()
            self.assertFalse(self.executable.exists(), 'Foreign objects never reach the consumer')

    def test_compatible_workspace_restores_without_compiling(self):
        products.pack('swiftpm', self.output)
        self.executable.unlink()
        with patch.object(products.subprocess, 'run') as build:
            products.restore('swiftpm', self.output)
            build.assert_not_called()
        self.assertEqual(self.executable.read_bytes(),self.macho)

    def test_relocated_product_does_not_hide_tampering_or_build_failure(self):
        products.pack('swiftpm', self.output)
        consumer = {**self.identity, 'workspace': '/private/other-runner/checkout'}
        with patch.object(products, 'identity', return_value=consumer):
            with patch.object(products.subprocess, 'run', side_effect=subprocess.CalledProcessError(1,'swift')):
                with self.assertRaises(subprocess.CalledProcessError): products.restore('swiftpm', self.output)
            with (self.output/'swiftpm.tar.gz').open('ab') as stream: stream.write(b'tampered')
            with patch.object(products.subprocess, 'run') as build:
                with self.assertRaises(products.TransferError): products.restore('swiftpm', self.output)
                build.assert_not_called()
        products.pack('swiftpm', self.output)
        for key in ['commit','arch','xcode','pins','workspace']:
            metadata=json.loads((self.output/'swiftpm.json').read_text())
            del metadata[key]
            (self.output/'swiftpm.json').write_text(json.dumps(metadata))
            with patch.object(products.subprocess,'run') as build:
                with self.assertRaises(ValueError): products.restore('swiftpm',self.output)
                build.assert_not_called()
            products.pack('swiftpm',self.output)

    def test_swiftpm_identity_uses_the_named_architecture_not_the_interpreters(self):
        with patch.dict(os.environ,CASSINI_CI_ARCH='x86_64'):self.assertEqual(products.product_arch(),'x86_64')
        with patch.dict(os.environ,CASSINI_CI_ARCH='arm64'):self.assertEqual(products.product_arch(),'arm64')
        with patch.dict(os.environ,CASSINI_CI_ARCH=''):self.assertEqual(products.product_arch(),os.uname().machine)
        with patch.dict(os.environ,CASSINI_CI_ARCH='universal'):
            with self.assertRaisesRegex(ValueError,'Unsupported product architecture'):products.product_arch()

    def test_packing_rejects_products_of_another_architecture(self):
        intel,arm,fat=self.thin(0x01000007),self.macho,b'\xca\xfe\xba\xbe'+b'\0\0\0\x02'+b'\0'*24
        other=[self.thin(7),self.thin(0x01000007,b'\xce\xfa\xed\xfe'),self.thin(0x01000007,b'\xfe\xed\xfa\xce'),self.thin(0x01000007,b'\xfe\xed\xfa\xcf')]
        cases=[(arm,arm,'arm64',True),(intel,intel,'x86_64',True),(b'#!/bin/sh\n# a script',intel,'x86_64',True),
               (intel,intel,'arm64',False),(arm,arm,'x86_64',False),(intel,arm,'x86_64',False),(arm,intel,'arm64',False),
               (fat,intel,'x86_64',False),(intel,fat,'x86_64',False)]
        cases+=[(unknown,intel,'x86_64',False) for unknown in other]+[(intel,unknown,'x86_64',False) for unknown in other]
        # Nothing inspected is not a pass: a missing or non-Mach-O test bundle is refused.
        cases+=[(intel,None,'x86_64',False),(intel,b'not a Mach-O file','x86_64',False)]
        for worker,test,named,accepted in cases:
            with self.subTest(named=named,worker=worker[:8],test=test and test[:8]):
                self.executable.write_bytes(worker)
                if test is None: self.tests.unlink()
                else: self.tests.write_bytes(test)
                shutil.rmtree(self.output,ignore_errors=True)
                with patch.dict(os.environ,CASSINI_CI_ARCH=named),patch.object(products,'identity',side_effect=lambda kind:{**self.identity,'arch':products.product_arch()}):
                    if accepted:
                        products.pack('swiftpm',self.output)
                        self.assertEqual(json.loads((self.output/'swiftpm.json').read_text())['arch'],named)
                    else:
                        with self.assertRaisesRegex(ValueError,'(Product .* is .*, not |No )'+named):products.pack('swiftpm',self.output)
                        self.assertFalse((self.output/'swiftpm.tar.gz').exists())
        shutil.rmtree(self.root/'.build/arm64/debug')
        with self.assertRaisesRegex(ValueError,'No SwiftPM products'):products.pack('swiftpm',self.output)

    def test_restored_products_are_checked_after_extraction(self):
        products.pack('swiftpm', self.output)
        self.executable.unlink();self.tests.unlink()
        with patch.object(products,'check_swiftpm_arch',wraps=products.check_swiftpm_arch) as check:
            products.unpack('swiftpm', self.output)
            check.assert_called_once_with('arm64')
        self.assertEqual(self.tests.read_bytes(),self.macho)

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


class ReleaseArchitecture(unittest.TestCase):
    """Transport rejects incomplete slices even when metadata and archive digest agree.

    The lipo boundary is stubbed so these fast cases also run on the Linux changes job;
    the real lipo is separately exercised against the actual CI Release artifact.
    """
    BOTH = b'\xca\xfe\xba\xbe' + b'two slices'
    ARM_FAT = b'\xca\xfe\xba\xbe' + b'one arm slice'
    ARM = Transport.thin(0x0100000c)
    INTEL = Transport.thin(0x01000007)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()
        self.folder=self.root/'build/Build/Products/Release'
        self.output=self.root/'upload'
        self.paths=[self.folder/'Cassini.app/Contents/MacOS/Cassini',
                    *[self.folder/(name+'.o') for name in products.RELEASE_SDK_OBJECTS],
                    self.folder/'Cassini.app/Contents/Frameworks/Engine.framework/Versions/A/Engine',
                    self.folder/'Cassini.app/Contents/Resources/libengine.dylib',
                    self.folder/'libstatic.a']
        self.identity={'kind':'release','commit':'a'*40,'arch':'universal','xcode':'Xcode 16.4','pins':{}}
        for target,attribute,value in [(products,'ROOT',self.root),(products,'identity',None)]:
            replacement=patch.object(target,attribute,side_effect=lambda kind: dict(self.identity)) if attribute=='identity' else patch.object(target,attribute,value)
            replacement.start();self.addCleanup(replacement.stop)
        lipo=patch.object(products.subprocess,'check_output',side_effect=self.slices)
        self.lipo=lipo.start();self.addCleanup(lipo.stop)
        self.reset_products()

    def reset_products(self):
        for path in self.paths:
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(self.BOTH)
        script=self.folder/'Cassini.app/Contents/Resources/script'
        script.write_text('#!/bin/sh\nexit 0\n');script.chmod(0o755)
        alias=self.folder/'engine-link'
        if not alias.exists():alias.symlink_to('Cassini.app/Contents/Resources/libengine.dylib')

    def slices(self,command,text):
        self.assertEqual(command[:3],['xcrun','lipo','-archs']);self.assertTrue(text)
        data=Path(command[3]).read_bytes()
        return {self.BOTH:'x86_64 arm64\n',self.ARM:'arm64\n',self.INTEL:'x86_64\n',self.ARM_FAT:'arm64\n'}[data]

    def test_pack_and_restore_inspect_app_framework_library_and_every_consumed_object(self):
        products.pack('release',self.output)
        self.assertEqual({Path(call.args[0][3]) for call in self.lipo.call_args_list},set(self.paths))
        self.assertEqual(json.loads((self.output/'release.json').read_text())['arch'],'universal')
        self.lipo.reset_mock();shutil.rmtree(self.folder)
        products.unpack('release',self.output)
        self.assertEqual({Path(call.args[0][3]) for call in self.lipo.call_args_list},set(self.paths))
        self.assertTrue((self.folder/'engine-link').is_symlink())

    def test_pack_rejects_each_missing_slice_in_every_binary_role_including_fat_header(self):
        for path in self.paths:
            for data in [self.ARM,self.INTEL,self.ARM_FAT]:
                with self.subTest(path=path.relative_to(self.folder),data=data):
                    path.write_bytes(data)
                    with self.assertRaisesRegex(ValueError,'missing required slices'):
                        products.pack('release',self.output)
                    path.write_bytes(self.BOTH)

    def test_restore_rejects_incomplete_slices_even_with_a_matching_digest(self):
        products.pack('release',self.output)
        archive=self.output/'release.tar.gz';original=archive.read_bytes()
        for path in self.paths:
            for data in [self.ARM,self.INTEL,self.ARM_FAT]:
                with self.subTest(path=path.relative_to(self.folder),data=data):
                    with tarfile.open(fileobj=io.BytesIO(original)) as source,tarfile.open(archive,'w:gz') as target:
                        for item in source.getmembers():
                            if item.isfile():
                                contents=data if item.name==str(path.relative_to(self.root)) else source.extractfile(item).read()
                                item.size=len(contents);target.addfile(item,io.BytesIO(contents))
                            else:target.addfile(item)
                    metadata={**self.identity,'sha256':products.digest(archive)}
                    (self.output/'release.json').write_text(json.dumps(metadata))
                    shutil.rmtree(self.folder,ignore_errors=True)
                    with self.assertRaisesRegex(ValueError,'missing required slices') as caught:
                        products.restore('release',self.output)
                    self.assertNotIsInstance(caught.exception,products.TransferError)

    def test_missing_required_executable_or_sdk_object_does_not_pass_empty_inspection(self):
        for path in self.paths[:6]:
            with self.subTest(path=path.name):
                path.unlink()
                with self.assertRaisesRegex(ValueError,'Missing Release binary'):
                    products.pack('release',self.output)
                path.write_bytes(self.BOTH)
        self.paths[0].write_text('not a native executable')
        with self.assertRaisesRegex(ValueError,'was not inspected'):
            products.pack('release',self.output)

    def test_lipo_failure_is_not_an_incomplete_download_retry(self):
        products.pack('release',self.output)
        self.lipo.side_effect=subprocess.CalledProcessError(1,['xcrun','lipo'])
        with self.assertRaises(subprocess.CalledProcessError):products.pack('release',self.output)
        with self.assertRaises(subprocess.CalledProcessError):products.restore('release',self.output)


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
        self.assertIn('command -v xcodegen >/dev/null 2>&1 || brew install xcodegen', release)
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
