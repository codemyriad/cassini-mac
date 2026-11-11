#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Device-free tests of probe launching and the motion completion relay."""
import ast
import inspect
import importlib.util
import json
import plistlib
import select
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('spectro_harness',Path(__file__).with_name('test-spectrogram-app.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

class HostAdmission(unittest.TestCase):
    def test_rejected_host_cannot_mutate_settings_or_start_measurement(self):
        for entry in [harness.measure,harness.run]:
            with self.subTest(entry=entry.__name__), patch.object(harness,'check',side_effect=ValueError('unqualified')), patch.object(harness.subprocess,'run') as run:
                with self.assertRaisesRegex(ValueError,'unqualified'):
                    entry(Path('/private/probe.app'),Path('/private/output'),Path('/private/checker'))
                run.assert_not_called()


class MotionCompletion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.request = Path(self.temporary.name)/'motion-request.json'
        self.ack = self.request.with_name('motion-ack.json')
        self.request.write_text(json.dumps({'requestID':'first','reduceMotion':True}))

    def emit(self,value):
        return harness.relay_motion_ack('CASSINI_SPECTRO_MOTION_ACK:'+json.dumps(value)+'\n',self.request)

    def test_only_current_completion_creates_an_acknowledgement(self):
        self.assertFalse(self.emit({'requestID':'old'}))
        self.assertFalse(self.ack.exists())
        self.assertTrue(self.emit({'requestID':'first'}))
        self.assertEqual(json.loads(self.ack.read_text()),{'requestID':'first'})
        self.assertFalse(self.ack.with_name('.motion-ack.tmp').exists())

    def test_prior_success_cannot_complete_the_next_os_transition(self):
        self.assertTrue(self.emit({'requestID':'first'}))
        self.request.write_text(json.dumps({'requestID':'second','reduceMotion':False}))
        self.assertFalse(self.emit({'requestID':'first'}))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'first')
        self.assertTrue(self.emit({'requestID':'second'}))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'second')

    def test_normal_logs_and_malformed_markers_do_not_acknowledge(self):
        for line in ['Test Case passed','CASSINI_SPECTRO_MOTION_ACK:no json',
                     'CASSINI_SPECTRO_MOTION_ACK:[]','CASSINI_SPECTRO_MOTION_ACK:{}']:
            self.assertFalse(harness.relay_motion_ack(line,self.request))
        for value in ['',None,1,[],{}]:
            self.assertFalse(self.emit({'requestID':value}))
        self.assertFalse(self.ack.exists())

    def test_log_prefix_does_not_hide_the_real_completion(self):
        self.assertTrue(harness.relay_motion_ack('runner stdout: CASSINI_SPECTRO_MOTION_ACK:{"requestID":"first"}\n',self.request))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'first')

    def test_missing_request_cannot_be_acknowledged(self):
        self.request.unlink()
        self.assertFalse(self.emit({'requestID':'first'}))
        self.assertFalse(self.ack.exists())


class ProbeLaunch(unittest.TestCase):
    def test_measurement_and_allocation_launch_the_bundle_executable(self):
        # Exercise OS process creation with an inert executable, including an
        # executable name different from the bundle. No AppKit or devices run.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root/'Private probe.app'
            executable = app/'Contents/MacOS/actual-probe'
            executable.parent.mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'actual-probe'}))
            executable.write_text('#!'+sys.executable+'\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            executable.chmod(0o700)
            for allocations,profile in [(False,False),(True,False),(False,True)]:
                result = subprocess.run(harness.probe_command(app, 'B', root/'output', allocations,profile),
                                        capture_output=True, text=True, check=True)
                arguments = json.loads(result.stdout)
                self.assertIn('--spectrogram-self-test', arguments)
                self.assertEqual('-SpectrogramAllocations' in arguments, allocations)
                self.assertEqual('-SpectrogramProfileOnly' in arguments, profile)
                self.assertEqual(arguments[arguments.index('-SpectrogramOutput')+1], str((root/'output').resolve()))

class ControlledScheduling(unittest.TestCase):
    def report(self):
        return dict(audioDevicesOpened=False,virtualClockOnly=True,gates={key:True for key in
            ['nativeSteadyLateZero','browserSteadyLateZero','lateBudgetRejectsEarlyRelease','hiddenZeroWork','noDrops','realAnalysis']})

    def invoke(self,report,exit_code=0):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);program=root/'private checker';output=root/'output'
            program.write_text('#!'+sys.executable+'\nimport sys\nprint('+repr(json.dumps(report))+')\nsys.exit('+str(exit_code)+')\n')
            program.chmod(0o700)
            return harness.check_scheduling(program,output)

    def test_actual_successful_process_and_all_named_gates_are_required(self):
        self.assertEqual(self.invoke(self.report()),self.report())

    def test_process_failure_cannot_pass_with_successful_json(self):
        with self.assertRaises(RuntimeError): self.invoke(self.report(),exit_code=1)

    def test_missing_false_and_non_boolean_gates_fail(self):
        for value in [False,1,None]:
            report=self.report();report['gates']['lateBudgetRejectsEarlyRelease']=value
            with self.subTest(value=value),self.assertRaises(RuntimeError):self.invoke(report)
        report=self.report();report['gates'].pop('realAnalysis')
        with self.assertRaises(RuntimeError):self.invoke(report)
        report=self.report();report['gates']={}
        with self.assertRaises(RuntimeError):self.invoke(report)

    def test_non_object_or_device_opening_reports_fail(self):
        with self.assertRaises(RuntimeError):self.invoke([])
        report=self.report();report['audioDevicesOpened']=True
        with self.assertRaises(RuntimeError):self.invoke(report)

class InstrumentationIsolation(unittest.TestCase):
    def test_measurement_waits_for_explicit_post_setup_driver_readiness(self):
        self.assertTrue(harness.motion_driver_ready('CASSINI_SPECTRO_MOTION_READY\n'))
        for line in ["Test Suite 'SpectrogramMotion' started.",
                     "Test Case '-[CassiniWindowScreenshots.SpectrogramMotion testRealSystemSettingsMotionTransitions]' started.",
                     "Test Case '-[CassiniWindowScreenshots.SpectrogramMotion testRealSystemSettingsMotionTransitions]' passed.",
                     'CASSINI_SPECTRO_MOTION_ACK:{"requestID":"first"}',
                     'CASSINI_SPECTRO_MOTION_READY:pending']:
            self.assertFalse(harness.motion_driver_ready(line))

    def test_allocations_and_profiling_cannot_share_one_process(self):
        with self.assertRaises(ValueError):
            harness.probe_command(Path('/private/probe'), 'B', Path('/private/output'), allocations=True,profile=True)

    def test_all_timed_cases_finish_before_motion_automation_starts(self):
        body=ast.parse(inspect.getsource(harness.measure)).body[0].body
        loop=next(i for i,node in enumerate(body) if isinstance(node,ast.For))
        def has_motion(node):
            return any(isinstance(child,ast.Call) and isinstance(child.func,ast.Name) and child.func.id=='record_motion' for child in ast.walk(node))
        self.assertEqual(ast.literal_eval(body[loop].iter),'ABCDE')
        self.assertFalse(any(has_motion(node) for node in body[:loop+1]))
        self.assertTrue(any(has_motion(node) for node in body[loop+1:]))

    def test_motion_is_a_separate_diagnostic_with_current_driver_readiness(self):
        # Real inert processes, with only the external UI driver substituted.
        # No AppKit, System Settings or native graphics probe executes locally.
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);program=root/'inert-probe'
            program.write_text('#!'+sys.executable+"\nimport json,sys,os\nprint(json.dumps({'diagnosticMotionOnly':'-SpectrogramMotionOnly' in sys.argv,'realMotionTransition':True,'audioDevicesOpened':False}))\n")
            program.chmod(0o700)
            native_popen=subprocess.Popen; launched=[]
            def spawn(command,**kwargs):
                if command[0] == 'xcodebuild':
                    child=native_popen([sys.executable,'-c',"print('CASSINI_SPECTRO_MOTION_READY',flush=True)"],**kwargs)
                else:
                    self.assertIn('-SpectrogramMotionOnly',command)
                    child=native_popen(command,**kwargs)
                launched.append(child.pid);return child
            with patch.object(harness.Path,'glob',return_value=iter([root/'private.xctestrun'])),patch.object(harness.subprocess,'Popen',side_effect=spawn):
                self.assertTrue(harness.record_motion(program,root))
            self.assertEqual(len(set(launched)),2)
            self.assertTrue(json.loads((root/'motion.json').read_text())['diagnosticMotionOnly'])
        for options in [dict(allocations=True,motion=True),dict(profile=True,motion=True)]:
            with self.assertRaises(ValueError):
                harness.probe_command(Path('/private/probe'),'B',Path('/private/output'),**options)

    def exercise_profiler(self, probe_exit=0, trace_exit=0, create_trace=True):
        # Real inert processes + Darwin notification; substitute only xctrace.
        # Popen returns BEFORE the recorder installs its handler/posts readiness.
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);program=root/'inert-probe';started=root/'fixture-started'
            program.write_text('#!'+sys.executable+"\nimport json,sys,os,pathlib\nassert os.environ['CASSINI_SPECTRO_PROFILE_GATE']=='1'\nassert sys.stdin.read(1)=='1'\npathlib.Path("+repr(str(started))+").touch()\nprint(json.dumps({'diagnosticProfileOnly':'-SpectrogramProfileOnly' in sys.argv,'audioDevicesOpened':False,'analyzedFrames':12 if os.environ.get('CASSINI_SPECTRO')=='1' else 0})); sys.exit("+str(probe_exit)+")\n")
            program.chmod(0o700)
            native_popen=subprocess.Popen;subscribe=harness.tracing_started
            launched=[];recorders=[]
            def spawn(command,**kwargs):
                if command[:3] != ['xcrun','xctrace','record']:
                    child=native_popen(command,**kwargs);launched.append(child);return child
                self.assertEqual(command[command.index('--attach')+1],str(launched[-1].pid))
                self.assertIn('--no-prompt',command)
                trace=command[command.index('--output')+1]
                name=command[command.index('--notify-tracing-started')+1]
                code="import signal,sys,pathlib,ctypes; assert sys.stdin.read(1)=='r'; signal.signal(signal.SIGINT,lambda *_:(pathlib.Path(sys.argv[1]).mkdir() if sys.argv[4]=='True' else None,sys.exit(int(sys.argv[3])))); n=ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib'); assert n.notify_post(sys.argv[2].encode())==0; signal.pause()"
                child=native_popen([sys.executable,'-c',code,trace,name,str(trace_exit),str(create_trace)],stdin=subprocess.PIPE,text=True)
                recorders.append(child);return child
            from contextlib import contextmanager
            @contextmanager
            def delayed_recorder():
                with subscribe() as (name,wait):
                    def release_and_wait():
                        self.assertIsNone(launched[0].poll())
                        self.assertFalse(started.exists())
                        # Event, not a sleep: allow cold recorder initialization now.
                        recorders[0].stdin.write('r');recorders[0].stdin.close()
                        return wait(timeout=5)
                    yield name,release_and_wait
            with patch.dict(harness.os.environ,{'CASSINI_SPECTRO':'0'}), patch.object(harness.subprocess,'Popen',side_effect=spawn), patch.object(harness,'tracing_started',delayed_recorder):
                self.assertEqual(harness.record_profile(program,root),probe_exit==0 and trace_exit==0 and create_trace)
            self.assertTrue(started.exists());self.assertEqual(len(launched),1)
            report=json.loads((root/'profile.json').read_text())
            self.assertTrue(report['diagnosticProfileOnly'])
            self.assertEqual(report['processExitStatus'],probe_exit)
            self.assertEqual(report['traceExitStatus'],trace_exit)
            launched[0].stdout.close()

    def test_profiler_waits_for_real_recording_event_before_starting_fixture(self):
        self.exercise_profiler()

    def test_failed_probe_cannot_pass_after_recording_started(self):
        self.exercise_profiler(probe_exit=7)

    def test_failed_recorder_cannot_pass_with_successful_probe(self):
        self.exercise_profiler(trace_exit=9)

    def test_missing_trace_cannot_pass_with_successful_exit_statuses(self):
        self.exercise_profiler(create_trace=False)

    def test_missing_recorder_event_fails_without_starting_fixture(self):
        from contextlib import contextmanager
        @contextmanager
        def no_event():
            yield 'missing-event',lambda:False
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);native_popen=subprocess.Popen;children=[]
            def spawn(command,**kwargs):
                code="import sys; sys.stdin.read(1); sys.exit(7)" if command[0]!='xcrun' else "import signal; signal.pause()"
                child=native_popen([sys.executable,'-c',code],**kwargs);children.append(child);return child
            with patch.object(harness,'tracing_started',no_event),patch.object(harness.subprocess,'Popen',side_effect=spawn):
                self.assertFalse(harness.record_profile(root/'inert-probe',root))
            report=json.loads((root/'profile.json').read_text())
            self.assertIn('did not report recording started',report['error'])
            self.assertTrue(all(child.poll() is not None for child in children))
            children[0].stdin.close();children[0].stdout.close()


if __name__ == '__main__':
    unittest.main()
