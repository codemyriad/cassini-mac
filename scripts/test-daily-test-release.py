#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast policy tests: no signing, network, real state or app execution."""
from datetime import datetime,timedelta,timezone
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent.parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

daily=load('daily','daily-test-release.py')
resources=load('resources','release-resources.py')
installer=load('installer','install-daily-test-release.py')

class DailyPolicy(unittest.TestCase):
    def test_berlin_slots_follow_dst_and_catch_missed_wake(self):
        for instant,slot in [('2026-11-11T07:59:59+00:00','2026-11-10T20:00:00+01:00'),
                             ('2026-11-11T08:00:00+00:00','2026-11-11T09:00:00+01:00'),
                             ('2026-07-11T07:00:00+00:00','2026-07-11T09:00:00+02:00'),
                             ('2026-11-11T12:59:59+00:00','2026-11-11T09:00:00+01:00'),
                             ('2026-11-11T13:00:00+00:00','2026-11-11T14:00:00+01:00'),
                             ('2026-11-11T18:59:59+00:00','2026-11-11T14:00:00+01:00'),
                             ('2026-11-11T19:00:00+00:00','2026-11-11T20:00:00+01:00'),
                             ('2026-07-11T18:00:00+00:00','2026-07-11T20:00:00+02:00')]:
            self.assertEqual(daily.due_slot(datetime.fromisoformat(instant)),slot)

    def test_only_latest_successful_ci_for_exact_main_is_admitted(self):
        good=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        self.assertTrue(daily.eligible_ci([good],'a'*40))
        for field,value in [('head_sha','b'*40),('head_branch','feature'),('status','in_progress'),('conclusion','failure')]:
            self.assertFalse(daily.eligible_ci([{**good,field:value},good],'a'*40))
        self.assertFalse(daily.eligible_ci([],'a'*40))

    def test_pr_and_fork_runs_cannot_authorize_or_block_main(self):
        good=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        untrusted=[{**good,'event':event} for event in ['pull_request','pull_request_target','workflow_run']]
        untrusted += [{**good,'head_repository':repo} for repo in [None,{}, {'full_name':'fork/cassini-mac'}]]
        for run in untrusted:
            self.assertFalse(daily.eligible_ci([run],'a'*40))
            self.assertTrue(daily.eligible_ci([{**run,'status':'action_required'},good],'a'*40))
            self.assertFalse(daily.eligible_ci([run,{**good,'conclusion':'failure'},good],'a'*40))

    def test_schedule_and_manual_runs_cannot_authorize_or_block_push_main(self):
        push=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        for event in ['schedule','workflow_dispatch']:
            non_push={**push,'event':event}
            self.assertFalse(daily.eligible_ci([non_push],'a'*40))
            self.assertEqual(daily.ci_state([non_push],'a'*40),'missing')
            for outcome in [dict(status='in_progress',conclusion=None),dict(conclusion='failure'),dict(conclusion='cancelled')]:
                self.assertTrue(daily.eligible_ci([{**non_push,**outcome},push],'a'*40))
                self.assertEqual(daily.ci_state([{**non_push,**outcome},push],'a'*40),'green')
            self.assertFalse(daily.eligible_ci([non_push,{**push,'conclusion':'failure'}],'a'*40))

    def test_main_ci_searches_past_an_entire_page_of_pr_runs(self):
        good=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        pages=[{'workflow_runs':[{**good,'event':'pull_request'}]*100},{'workflow_runs':[good]}]
        with patch.object(daily,'gh',return_value=pages) as api:
            self.assertTrue(daily.main_is_green('a'*40))
            self.assertIn('--paginate',api.call_args.args[0]);self.assertIn('--slurp',api.call_args.args[0])
            self.assertIn('event=push',api.call_args.args[0][-1])
        with patch.object(daily,'gh',return_value=pages[:1]):
            self.assertFalse(daily.main_is_green('a'*40))

    def test_ci_state_distinguishes_green_pending_red_and_missing(self):
        good=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        self.assertEqual(daily.ci_state([good],'a'*40),'green')
        self.assertEqual(daily.ci_state([],'a'*40),'missing')
        for status in ['queued','in_progress','waiting','requested']:
            self.assertEqual(daily.ci_state([{**good,'status':status,'conclusion':None},good],'a'*40),'pending')
        for conclusion in ['failure','cancelled','timed_out','startup_failure','action_required','skipped']:
            self.assertEqual(daily.ci_state([{**good,'conclusion':conclusion},good],'a'*40),'red')
        self.assertEqual(daily.ci_state([{**good,'head_sha':'b'*40},good],'a'*40),'red')
        self.assertEqual(daily.ci_state([{**good,'head_branch':'feature'},good],'a'*40),'red')

    def test_release_notes_render_untrusted_titles_as_one_literal_span(self):
        title='Fix StateFlow<Settings> & [link](https://invalid.example) @someone **bold** `one` ```three```\n> heading\x1b\u202e 😀'
        literal='```` Fix StateFlow<Settings> & [link](https://invalid.example) @someone **bold** `one` ```three``` > heading 😀 ````'
        self.assertEqual(daily.release_title(title),literal)
        pr=dict(merged_at='now',base={'ref':'main'},merge_commit_sha='a'*40,number=7,title=title)
        with patch.object(daily,'command',return_value='a'*40+'\n'),patch.object(daily,'gh',return_value=[pr,pr]):
            body=daily.developer_notes(None,'a'*40)
        self.assertEqual(body,'Source: `'+('a'*40)+'`\n\n- '+literal+' ([#7](https://github.com/'+daily.REPO+'/pull/7))\n')
        self.assertEqual(daily.release_title(' \n\u202e\x1b'),'` Untitled pull request `')

    def test_direct_commit_subjects_are_folded_developer_changes_only(self):
        sha='a'*40;subject='CI D95 #123 Internal.swift'
        def git(args,**kwargs):return sha+'\n' if 'log' in args else subject+'\n'
        with patch.object(daily,'command',side_effect=git),patch.object(daily,'gh',return_value=[]):
            developer=daily.developer_notes(None,sha)
        notes=daily.ReleaseNotes('The Library opens normally.',developer)
        self.assertIn(subject,notes.github().split('<details>',1)[1])
        self.assertNotIn(subject,notes.user);self.assertNotIn(subject,notes.html())
        self.assertIn('/commit/'+sha,developer)

    def test_number_reserves_failed_builds_and_existing_immutable_beta_tags(self):
        releases=[{'tag_name':'v0.1.0-beta.9'},{'tag_name':'v1.0.0-beta.100'}]
        self.assertEqual(daily.next_build('0.1.0',1,releases,{}),10)
        self.assertEqual(daily.next_build('0.1.0',1,releases,{'build':12}),13)

    def test_nightly_version_moves_past_an_already_published_stable(self):
        stable=dict(tag_name='v0.1.1',prerelease=False,draft=False)
        self.assertEqual(daily.nightly_version('0.1.0',[stable]),'0.1.2')
        self.assertEqual(daily.nightly_version('0.1.1',[stable]),'0.1.2')
        self.assertEqual(daily.nightly_version('0.2.0',[stable]),'0.2.0')
        self.assertEqual(daily.nightly_version('0.1.0',[{**stable,'draft':True}]),'0.1.0')
        self.assertEqual(daily.nightly_version('1.0',[{**stable,'tag_name':'v1.0'}]),'1.0.1')

    def test_unpublished_or_production_release_cannot_skip_changed_main(self):
        release=dict(tag_name='v0.1.0-beta.3',prerelease=True,draft=False,name='nightly',published_at='2026-11-11',target_commitish='a'*40)
        self.assertEqual(daily.source_commit(daily.latest_nightly([release])),'a'*40)
        for changed in [dict(draft=True),dict(prerelease=False),dict(name='Production'),dict(name=None),dict(tag_name='v0.1.0')]:
            self.assertIsNone(daily.latest_nightly([{**release,**changed}]))
        with self.assertRaises(ValueError):daily.source_commit({**release,'target_commitish':'main'})

    def test_storage_and_memory_admission_preserves_reserve(self):
        resources.admit(15,25*1024**3,'System-wide memory free percentage: 40%')
        for space,pressure in [(24*1024**3,'System-wide memory free percentage: 40%'),(30*1024**3,'System-wide memory free percentage: 9%'),(30*1024**3,'unknown')]:
            with self.assertRaises(ValueError):resources.admit(15,space,pressure)

    def test_release_lock_wait_covers_the_shared_ios_archive_slot(self):
        release=load('release_lock_policy','release.py')
        with patch.object(release,'run',return_value=b'Swapouts: 7.\n'):
            environment=release.heavy_environment()
        self.assertGreaterEqual(int(environment['CASSINI_LOCK_MINUTES']),60)
        self.assertEqual(environment['CASSINI_RELEASE_SWAPOUTS'],'7')
        self.assertEqual(environment.get('CASSINI_PYTHON'),release.sys.executable)

    def test_production_tag_is_rejected_before_any_publish_command(self):
        with patch.object(daily,'command') as tool:
            with self.assertRaises(ValueError):daily.publish('v0.1.0','0.1.0',2,'a'*40,Path('/absent'),None)
            tool.assert_not_called()

    def test_atomic_counter_keeps_private_complete_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'state.json';daily.atomic(path,{'build':3})
            self.assertEqual(json.loads(path.read_text()),{'build':3})
            self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertFalse(path.with_suffix('.tmp').exists())

class DailyExecution(unittest.TestCase):
    def context(self,directory,green=True,unchanged=False):
        from contextlib import ExitStack
        stack=ExitStack();self.addCleanup(stack.close)
        base=Path(directory);source=base/'source';(source/'scripts').mkdir(parents=True)
        script=source/'scripts/daily-test-release.py';script.write_text('trusted pipeline')
        (source/'scripts/user_release_notes.py').write_text('trusted renderer')
        (source/'project.yml').write_text('MARKETING_VERSION: "0.1.0"\nCURRENT_PROJECT_VERSION: "1"\n')
        for name,value in [('BASE',base),('SOURCE',source),('INBOX',base/'inbox'),('__file__',str(script))]:stack.enter_context(patch.object(daily,name,value))
        stack.enter_context(patch.object(daily.sys,'platform','darwin'))
        stack.enter_context(patch.object(daily.socket,'gethostname',return_value='drmeyers'))
        stack.enter_context(patch.dict(daily.os.environ,{'CASSINI_HEAVY_LOCK_HELD':''}))
        stack.enter_context(patch.object(daily.shutil,'disk_usage',return_value=type('Disk',(),{'free':30*1024**3})()))
        sha='a'*40
        previous=dict(tag_name='v0.1.0-beta.2',prerelease=True,draft=False,name='nightly',published_at='2026-11-10',target_commitish=sha)
        def api(args):
            if 'request-mac' in args[-1]:return {'workflow_runs':[]}
            if '/actions/workflows/ci.yml' in args[-1]:return [{'workflow_runs':[dict(head_sha=sha,head_branch='main',status='completed',conclusion='success' if green else 'failure',event='push',head_repository={'full_name':daily.REPO})]}]
            if '/releases?' in args[-1]:return [[previous]] if unchanged else [[]]
            raise AssertionError('Unexpected API')
        stack.enter_context(patch.object(daily,'gh',side_effect=api))
        def tool(args,**kwargs):
            if 'get-url' in args:return daily.ORIGIN+'\n'
            if 'rev-parse' in args:return sha+'\n'
            if args==['vm_stat']:return 'Swapouts: 0.\n'
            if 'ls-remote' in args:return sha+' refs/heads/main\n'
            return ''
        calls=stack.enter_context(patch.object(daily,'command',side_effect=tool))
        build=stack.enter_context(patch.object(daily,'signed_build',return_value=1))
        return base,calls,build

    def test_renderer_update_reexecutes_before_using_cached_notes_or_signing(self):
        class Replaced(BaseException):pass
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory)
            original=calls.side_effect
            def changed(args,**kwargs):
                if 'checkout' in args:(base/'source/scripts/user_release_notes.py').write_text('new renderer')
                return original(args,**kwargs)
            calls.side_effect=changed
            with patch.object(daily.os,'execv',side_effect=Replaced) as replace:
                with self.assertRaises(Replaced):daily.tick(datetime.fromisoformat('2026-11-11T08:00:00+00:00'))
            replace.assert_called_once();build.assert_not_called()
            self.assertNotIn('slot',json.loads((base/'state.json').read_text()))

    def test_pipeline_update_preserves_consumed_request_slot_and_pending_wait_across_exec(self):
        class Replaced(BaseException):pass
        instant=datetime.fromisoformat('2026-11-11T08:00:00+00:00')
        due=daily.due_slot(instant)
        # 1. Scheduled wake after an already-consumed manual request: self-exec must keep request=43252940679
        #    so the re-executed process does not re-arm yesterday's manual dispatch.
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory)
            prior_slot='2026-11-10T20:00:00+01:00'
            daily.atomic(base/'state.json',dict(slot=prior_slot,request=43252940679,build=2))
            original_calls=calls.side_effect
            updated=[False]
            def changed(args,**kwargs):
                if 'checkout' in args and not updated[0]:
                    updated[0]=True
                    (base/'source/scripts/daily-test-release.py').write_text('new pipeline')
                return original_calls(args,**kwargs)
            calls.side_effect=changed
            original_gh=daily.gh
            def api(args):
                if 'request-mac' in args[-1]:
                    return {'workflow_runs':[dict(id=43252940679,conclusion='success',head_branch='main',event='workflow_dispatch')]}
                return original_gh(args)
            with patch.object(daily,'gh',side_effect=api),patch.object(daily.os,'execv',side_effect=Replaced):
                with self.assertRaises(Replaced):daily.tick(instant)
            saved=json.loads((base/'state.json').read_text())
            self.assertEqual(saved['slot'],prior_slot)
            self.assertEqual(saved['request'],43252940679)
            # Re-executed tick enters the due scheduled slot without treating 43252940679 as a new manual request.
            with patch.object(daily,'gh',side_effect=api),patch.object(daily,'main_ci_state',return_value='pending'):
                daily.tick(instant)
            saved=json.loads((base/'state.json').read_text())
            self.assertEqual(saved['request'],43252940679)
            self.assertEqual(saved['pending_ci']['request'],0)
        # 2. New manual request during an already-completed slot + mid-wait pipeline update: both the completed
        #    slot and active pending_ci wait budget survive self-exec, and the new manual request still runs.
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory)
            pending=dict(slot=due,request=50000000000,head='a'*40,started_at='2026-11-11T07:50:00+00:00',
                         head_started_at='2026-11-11T07:50:00+00:00',candidates=[])
            daily.atomic(base/'state.json',dict(slot=due,request=43252940679,pending_ci=pending,build=2))
            original_calls=calls.side_effect
            updated=[False]
            def changed(args,**kwargs):
                if 'checkout' in args and not updated[0]:
                    updated[0]=True
                    (base/'source/scripts/daily-test-release.py').write_text('newer pipeline')
                return original_calls(args,**kwargs)
            calls.side_effect=changed
            original_gh=daily.gh
            def api(args):
                if 'request-mac' in args[-1]:
                    return {'workflow_runs':[dict(id=50000000000,conclusion='success',head_branch='main',event='workflow_dispatch')]}
                return original_gh(args)
            with patch.object(daily,'gh',side_effect=api),patch.object(daily.os,'execv',side_effect=Replaced):
                with self.assertRaises(Replaced):daily.tick(instant)
            saved=json.loads((base/'state.json').read_text())
            self.assertEqual(saved['slot'],due)
            self.assertEqual(saved['request'],43252940679)
            self.assertEqual(saved['pending_ci']['started_at'],'2026-11-11T07:50:00+00:00')
            with patch.object(daily,'gh',side_effect=api),self.assertRaises(SystemExit):
                daily.tick(instant)
            build.assert_called_once()
            self.assertEqual(json.loads((base/'state.json').read_text())['request'],50000000000)

    def test_pending_ci_does_not_consume_slot_or_manual_request_and_next_pulse_admits_green(self):
        for request_id in [None,42]:
            with self.subTest(request=request_id),tempfile.TemporaryDirectory() as directory:
                base,calls,build=self.context(directory)
                original=daily.gh
                def api(args):
                    if 'request-mac' in args[-1]:return {'workflow_runs':([] if request_id is None else [dict(id=request_id,conclusion='success',head_branch='main',event='workflow_dispatch')])}
                    return original(args)
                instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
                with patch.object(daily,'gh',side_effect=api),patch.object(daily,'main_ci_state',side_effect=['pending','pending','green']):
                    daily.tick(instant);daily.tick(instant)
                    state=json.loads((base/'state.json').read_text()) if (base/'state.json').exists() else {}
                    self.assertNotEqual(state.get('slot'),daily.due_slot(instant))
                    if request_id:self.assertNotEqual(state.get('request'),request_id)
                    build.assert_not_called()
                    self.assertEqual((base/'inbox').read_text().count('latest main CI is not green'),1)
                    self.assertIn('waiting:',(base/'inbox').read_text())
                    with self.assertRaises(SystemExit):daily.tick(instant)
                build.assert_called_once()
                state=json.loads((base/'state.json').read_text())
                self.assertEqual(state['slot'],daily.due_slot(instant));self.assertEqual(state['request'],request_id or 0)
                self.assertNotIn('pending_ci',state)

    def test_red_ci_immediately_consumes_slot_and_manual_request_without_building(self):
        for request_id in [None,42]:
            with self.subTest(request=request_id),tempfile.TemporaryDirectory() as directory:
                base,calls,build=self.context(directory,green=False)
                original=daily.gh
                def api(args):
                    if 'request-mac' in args[-1]:return {'workflow_runs':([] if request_id is None else [dict(id=request_id,conclusion='success',head_branch='main',event='workflow_dispatch')])}
                    return original(args)
                instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
                with patch.object(daily,'gh',side_effect=api):
                    daily.tick(instant);count=calls.call_count;daily.tick(instant+timedelta(minutes=1))
                build.assert_not_called();self.assertEqual(calls.call_count,count)
                state=json.loads((base/'state.json').read_text())
                self.assertEqual(state['slot'],daily.due_slot(instant));self.assertEqual(state['request'],request_id or 0)
                self.assertEqual(state['phase'],'skipped');self.assertNotIn('pending_ci',state)
                self.assertEqual((base/'inbox').read_text(),'[Mac] daily test release skipped: latest main CI is not green\n')
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            with patch.object(daily,'main_ci_state',side_effect=['pending','red']):
                daily.tick(instant);daily.tick(instant+timedelta(minutes=5))
            build.assert_not_called()
            state=json.loads((base/'state.json').read_text())
            self.assertEqual(state['slot'],daily.due_slot(instant));self.assertNotIn('pending_ci',state)
            self.assertIn('skipped: latest main CI is not green',(base/'inbox').read_text())

    def test_in_progress_ci_waits_up_to_45_minutes_then_consumes_slot_as_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory)
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            with patch.object(daily,'main_ci_state',return_value='pending'):
                for minute in [0,20,44]:
                    daily.tick(instant+timedelta(minutes=minute))
                    state=json.loads((base/'state.json').read_text())
                    self.assertNotEqual(state.get('slot'),daily.due_slot(instant))
                    self.assertIn('pending_ci',state)
                daily.tick(instant+timedelta(minutes=45))
                count=calls.call_count
                daily.tick(instant+timedelta(minutes=46))
            build.assert_not_called();self.assertEqual(calls.call_count,count)
            state=json.loads((base/'state.json').read_text())
            self.assertEqual(state['slot'],daily.due_slot(instant));self.assertEqual(state['phase'],'skipped')
            self.assertNotIn('pending_ci',state)
            lines=(base/'inbox').read_text().splitlines()
            self.assertEqual(lines,['[Mac] daily test release waiting: latest main CI is not green',
                                    '[Mac] daily test release skipped: main CI did not finish green within 45m'])

    def test_expired_wait_rejects_late_green_head(self):
        for request_id in [None,42]:
            for late_minutes in [45,120]:
                with self.subTest(request=request_id,late_minutes=late_minutes),tempfile.TemporaryDirectory() as directory:
                    base,calls,build=self.context(directory)
                    original=daily.gh
                    def api(args):
                        if 'request-mac' in args[-1]:return {'workflow_runs':([] if request_id is None else [dict(id=request_id,conclusion='success',head_branch='main',event='workflow_dispatch')])}
                        return original(args)
                    instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00') # 14:00 Berlin
                    with patch.object(daily,'gh',side_effect=api),patch.object(daily,'main_ci_state',side_effect=['pending','pending','green','green']):
                        daily.tick(instant) # 14:00 Berlin: pending
                        daily.tick(instant+timedelta(minutes=44)) # 14:44 Berlin: pending
                        try:daily.tick(instant+timedelta(minutes=late_minutes)) # 14:45 or 16:00 Berlin: green, expired
                        except SystemExit:pass
                        count=calls.call_count
                        daily.tick(instant+timedelta(minutes=late_minutes+1))
                    build.assert_not_called();self.assertEqual(calls.call_count,count)
                    state=json.loads((base/'state.json').read_text())
                    self.assertEqual(state['slot'],daily.due_slot(instant))
                    self.assertEqual(state['request'],request_id or 0)
                    self.assertEqual(state['phase'],'skipped')
                    self.assertNotIn('pending_ci',state)
                    self.assertEqual((base/'inbox').read_text().splitlines(),
                                     ['[Mac] daily test release waiting: latest main CI is not green',
                                      '[Mac] daily test release skipped: main CI did not finish green within 45m'])

    def test_expired_wait_rejects_late_green_ancestor(self):
        for request_id in [None,42]:
            for late_minutes in [45,120]:
                with self.subTest(request=request_id,late_minutes=late_minutes),tempfile.TemporaryDirectory() as directory:
                    base,calls,build=self.context(directory);source=base/'source'
                    def git(*args):
                        return subprocess.check_output(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],cwd=source,text=True).strip()
                    git('init','-q','-b','main');heads=[]
                    for index in range(3):
                        (source/'change').write_text(str(index));git('add','.');git('commit','-qm',f'c{index}')
                        heads.append(git('rev-parse','HEAD'))
                    original_calls=calls.side_effect
                    def real_git(args,**kwargs):
                        if args[0]=='git' and any(op in args for op in ('merge-base','diff','checkout')):
                            result=subprocess.run(list(map(str,args)),capture_output=True,text=True)
                            if result.returncode:raise RuntimeError('Command failed: git')
                            return result.stdout
                        return original_calls(args,**kwargs)
                    calls.side_effect=real_git
                    daily.atomic(base/'state.json',{'last_success':heads[0],'build':4})
                    original_gh=daily.gh
                    def api(args):
                        if 'request-mac' in args[-1]:return {'workflow_runs':([] if request_id is None else [dict(id=request_id,conclusion='success',head_branch='main',event='workflow_dispatch')])}
                        return original_gh(args)
                    statuses={heads[0]:'green',heads[1]:'pending',heads[2]:'pending'}
                    instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00') # 14:00 Berlin
                    with patch.object(daily,'gh',side_effect=api),patch.object(daily,'fetch_main',side_effect=[heads[1],heads[2],heads[2]]),patch.object(daily,'main_ci_state',side_effect=lambda sha:statuses[sha]):
                        daily.tick(instant) # 14:00 Berlin: heads[1] pending
                        daily.tick(instant+timedelta(minutes=44)) # 14:44 Berlin: heads[2] pending, heads[1] pending
                        statuses[heads[1]]='green'
                        try:daily.tick(instant+timedelta(minutes=late_minutes)) # 14:45 or 16:00 Berlin: ancestor heads[1] green, expired
                        except SystemExit:pass
                        count=calls.call_count
                        daily.tick(instant+timedelta(minutes=late_minutes+1))
                    build.assert_not_called();self.assertEqual(calls.call_count,count)
                    state=json.loads((base/'state.json').read_text())
                    self.assertEqual(state['slot'],daily.due_slot(instant))
                    self.assertEqual(state['request'],request_id or 0)
                    self.assertEqual(state['phase'],'skipped')
                    self.assertNotIn('pending_ci',state)
                    self.assertEqual((base/'inbox').read_text().splitlines(),
                                     ['[Mac] daily test release waiting: latest main CI is not green',
                                      '[Mac] daily test release waiting: latest main CI is not green',
                                      '[Mac] daily test release skipped: main CI did not finish green within 45m'])

    def test_missing_ci_run_allows_brief_webhook_grace_then_skips(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            with patch.object(daily,'main_ci_state',side_effect=['missing','pending','green']):
                daily.tick(instant);daily.tick(instant+timedelta(minutes=1))
                with self.assertRaises(SystemExit):daily.tick(instant+timedelta(minutes=2))
            build.assert_called_once()
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            with patch.object(daily,'main_ci_state',return_value='missing'):
                for minute in [0,1,2]:daily.tick(instant+timedelta(minutes=minute))
                self.assertNotEqual(json.loads((base/'state.json').read_text()).get('slot'),daily.due_slot(instant))
                daily.tick(instant+timedelta(minutes=3))
            build.assert_not_called()
            self.assertEqual(json.loads((base/'state.json').read_text())['slot'],daily.due_slot(instant))
            self.assertIn('skipped: latest main CI is not green',(base/'inbox').read_text())

    def test_fast_forwarding_main_during_wait_admits_newest_unpublished_green_ancestor_only(self):
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory);source=base/'source'
            def git(*args):
                return subprocess.check_output(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],cwd=source,text=True).strip()
            git('init','-q','-b','main');heads=[]
            for index in range(4):
                (source/'change').write_text(str(index));git('add','.');git('commit','-qm',f'c{index}')
                heads.append(git('rev-parse','HEAD'))
            (source/'scripts/daily-test-release.py').write_text('updated pipeline');git('add','.');git('commit','-qm','pipeline')
            pipeline_head=git('rev-parse','HEAD')
            git('checkout','-qfb','rewrite',heads[0])
            (source/'change').write_text('rewritten');git('add','.');git('commit','-qm','rewritten')
            rewritten=git('rev-parse','HEAD')
            git('checkout','-qf',heads[3])
            original=calls.side_effect
            def real_git(args,**kwargs):
                if args[0]=='git' and any(op in args for op in ('merge-base','diff','checkout')):
                    if 'checkout' in args and args[-1]==pipeline_head:return ''
                    result=subprocess.run(list(map(str,args)),capture_output=True,text=True)
                    if result.returncode:raise RuntimeError('Command failed: git')
                    return result.stdout
                return original(args,**kwargs)
            calls.side_effect=real_git
            daily.atomic(base/'state.json',{'last_success':heads[0],'build':4})
            statuses={heads[0]:'green',heads[1]:'pending',heads[2]:'pending',heads[3]:'pending',pipeline_head:'pending',rewritten:'green'}
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            with patch.object(daily,'fetch_main',side_effect=[rewritten,heads[0],heads[1],pipeline_head,heads[2],heads[3]]),patch.object(daily,'main_ci_state',side_effect=lambda sha:statuses[sha]),patch.object(daily,'notes',return_value=daily.ReleaseNotes('A clearer Library.','dev')):
                statuses[rewritten]='pending';statuses[heads[0]]='pending'
                daily.tick(instant) # rewritten pending
                statuses[rewritten]='green'
                daily.tick(instant+timedelta(minutes=1)) # heads[0] pending; rewritten green but non-ancestor -> ignored
                self.assertEqual(build.call_count,0)
                statuses[heads[0]]='green'
                daily.tick(instant+timedelta(minutes=2)) # heads[1] pending; heads[0] green but already published -> keep waiting
                self.assertEqual(build.call_count,0)
                self.assertNotIn('main unchanged',(base/'inbox').read_text() if (base/'inbox').exists() else '')
                statuses[heads[1]]='green'
                daily.tick(instant+timedelta(minutes=3)) # pipeline_head pending; heads[1] green but pipeline script differs -> do not downgrade
                self.assertEqual(build.call_count,0)
                statuses[heads[1]]='pending'
                daily.tick(instant+timedelta(minutes=4)) # heads[2] pending; heads[1] pending
                statuses[heads[1]]='green';statuses[heads[2]]='green'
                with self.assertRaises(SystemExit):daily.tick(instant+timedelta(minutes=5)) # heads[3] pending; admits newest green ancestor heads[2]
            build.assert_called_once()
            self.assertEqual(json.loads((base/'state.json').read_text())['head'],heads[2])
            self.assertEqual(git('rev-parse','HEAD'),heads[2])

    def test_green_unchanged_head_consumes_slot_once_without_building(self):
        with tempfile.TemporaryDirectory() as directory:
            base,calls,build=self.context(directory,unchanged=True)
            instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
            daily.tick(instant);count=calls.call_count;daily.tick(instant)
            build.assert_not_called();self.assertEqual(calls.call_count,count)

    def test_pre_admission_failure_notifies_again_for_a_new_manual_request(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            request=[None]
            def api(args):
                return {'workflow_runs':([] if request[0] is None else [dict(id=request[0],conclusion='success',head_branch='main',event='workflow_dispatch')])}
            with patch.object(daily,'gh',side_effect=api),patch.object(daily,'fetch_main',side_effect=ValueError('fixture unavailable')):
                for value in [None,None,42,42,43]:
                    request[0]=value
                    with self.assertRaises(SystemExit):daily.tick(datetime.fromisoformat('2026-11-11T13:00:00+00:00'))
            self.assertEqual((base/'inbox').read_text().count('failed:'),3)
            build.assert_not_called()

    def test_pending_notification_identity_includes_head_slot_and_manual_request(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            with patch.object(daily,'main_ci_state',return_value='pending'),patch.object(daily,'fetch_main',side_effect=['a'*40,'b'*40,'b'*40,'b'*40]):
                for hour in [13,13,13,19]:daily.tick(datetime.fromisoformat('2026-11-11T%02d:00:00+00:00'%hour))
            self.assertEqual((base/'inbox').read_text().count('waiting:'),3)
            build.assert_not_called()

    def test_local_success_prevents_rebuild_when_remote_release_listing_is_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            daily.atomic(base/'state.json',{'last_success':'a'*40,'build':9})
            daily.tick(datetime.fromisoformat('2026-11-11T08:00:00+00:00'))
            build.assert_not_called()
            self.assertIn('main unchanged',(base/'inbox').read_text())

    def test_local_and_remote_success_choose_the_newer_real_git_ancestor(self):
        class NotesReached(BaseException):pass
        for local_index,remote_index in [(0,1),(1,0)]:
            with self.subTest(local=local_index,remote=remote_index),tempfile.TemporaryDirectory() as directory:
                base,calls,build=self.context(directory);source=base/'source'
                def git(*args):
                    return subprocess.check_output(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],cwd=source,text=True).strip()
                git('init','-q','-b','main');heads=[]
                for index in range(3):
                    (source/'change').write_text(str(index));git('add','.');git('commit','-qm','fixture')
                    heads.append(git('rev-parse','HEAD'))
                original=calls.side_effect
                def command(args,**kwargs):
                    if args[0]=='git' and 'merge-base' in args:
                        return subprocess.check_output(list(map(str,args)),text=True).strip()
                    return original(args,**kwargs)
                calls.side_effect=command
                daily.atomic(base/'state.json',{'last_success':heads[local_index],'build':9})
                remote={'target_commitish':heads[remote_index]}
                with patch.object(daily,'fetch_main',return_value=heads[2]),patch.object(daily,'main_ci_state',return_value='green'),patch.object(daily,'latest_nightly',return_value=remote),patch.object(daily,'notes',side_effect=NotesReached) as notes:
                    reached=False
                    try:daily.tick(datetime.fromisoformat('2026-11-11T08:00:00+00:00'))
                    except NotesReached:reached=True
                    except SystemExit:pass
                self.assertTrue(reached,'A newer remote publication must not wedge the next release')
                self.assertEqual(notes.call_args.args,(heads[1],heads[2]))
                build.assert_not_called()

    def test_failed_build_is_not_retried_within_slot_but_next_slot_reports_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            first=datetime.fromisoformat('2026-11-11T08:00:00+00:00')
            with self.assertRaises(SystemExit):daily.tick(first)
            daily.tick(first);self.assertEqual(build.call_count,1)
            with self.assertRaises(SystemExit):daily.tick(datetime.fromisoformat('2026-11-11T13:00:00+00:00'))
            self.assertEqual(build.call_count,2)
            self.assertEqual(list(base.glob('build-*')),[])
            self.assertEqual(len(list((base/'failures').glob('build-*'))),2)
            self.assertEqual(len((base/'inbox').read_text().splitlines()),2)
            self.assertTrue(all('--test-release' in call.args[0] for call in build.call_args_list))

    def test_post_publish_cleanup_failure_does_not_rebuild_the_same_head(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory);build.return_value=0
            with patch.object(daily,'notes',return_value=daily.ReleaseNotes('A clearer Library.','developer notes')),patch.object(daily,'publish') as publish,patch.object(daily.shutil,'copy2',side_effect=OSError):
                with self.assertRaises(SystemExit):daily.tick(datetime.fromisoformat('2026-11-11T08:00:00+00:00'))
                daily.tick(datetime.fromisoformat('2026-11-11T13:00:00+00:00'))
            self.assertEqual(build.call_count,1);publish.assert_called_once()
            self.assertEqual(json.loads((base/'state.json').read_text())['last_success'],'a'*40)
            self.assertIn('published output cleanup',(base/'inbox').read_text())
            self.assertIn('main unchanged',(base/'inbox').read_text())

    def test_incomplete_assets_never_publish_and_complete_upload_is_always_prerelease(self):
        import hashlib
        for complete,user_text,state in [(False,'A clearer Library.','uploaded'),(True,'A clearer Library.','uploaded'),(True,'A'*500,'uploaded'),(True,'A clearer Library.','starter'),(True,'A clearer Library.',None)]:
            with tempfile.TemporaryDirectory() as directory:
                output=Path(directory);name='Cassini-talk-0.1.0-test.2.dmg';data=b'notarized fixture'
                (output/name).write_bytes(data);digest=hashlib.sha256(data).hexdigest()
                (output/'test-release.json').write_text(json.dumps(dict(channel='nightly',commit='a'*40,version='0.1.0',build=2,notarized=True,updatesEnabled=False,dmg=name,bytes=len(data),sha256=digest)))
                (output/'SHA256SUMS').write_text(digest+'  '+name+'\n')
                user=daily.ReleaseNotes(user_text,'CI D95 #123 Internal.swift developer PR title')
                (output/'user-release-notes.txt').write_text(user.user)
                (output/'user-release-notes.html').write_text(user.html())
                assets=[dict(name=p.name,size=p.stat().st_size,state=state) for p in output.iterdir()]
                if not complete:assets=assets[:1]
                view=['gh','release','view','v0.1.0-beta.2','-R',daily.REPO,'--json','isDraft,isPrerelease,assets']
                def command(args,**kwargs):
                    return json.dumps(dict(isDraft=True,isPrerelease=True,assets=assets)) if args==view else ''
                publishable=complete and state=='uploaded'
                with patch.object(daily,'command',side_effect=command) as tool,patch.object(daily,'gh',side_effect=AssertionError('Drafts must not use the published-tag REST endpoint')):
                    if publishable:daily.publish('v0.1.0-beta.2','0.1.0',2,'a'*40,output,user)
                    else:
                        with self.assertRaises(ValueError):daily.publish('v0.1.0-beta.2','0.1.0',2,'a'*40,output,user)
                    edits=[c.args[0] for c in tool.call_args_list if c.args[0][1:3]==['release','edit']]
                    self.assertEqual(len(edits),int(publishable))
                    self.assertEqual(sum(c.args[0]==view for c in tool.call_args_list),1)
                    if edits:self.assertIn('--prerelease',edits[0]);self.assertIn('--latest=false',edits[0])
                    self.assertFalse(any('--clobber' in c.args[0] for c in tool.call_args_list))
                    self.assertEqual((output/'user-release-notes.txt').read_text(),user.user)
                    self.assertLessEqual(len((output/'user-release-notes.txt').read_text().encode('utf-16-le'))//2,500)
                    for token in ['CI','D95','#123','Internal.swift','developer PR title']:
                        self.assertNotIn(token,(output/'user-release-notes.html').read_text())
                    self.assertIn(user.developer,(output/'nightly-notes.md').read_text().split('<details>',1)[1])
                    upload=next(c.args[0] for c in tool.call_args_list if c.args[0][1:3]==['release','upload'])
                    self.assertIn(output/'user-release-notes.txt',upload);self.assertIn(output/'user-release-notes.html',upload)


class InstalledRuntime(unittest.TestCase):
    def test_default_recovers_stable_opt_entrypoint_from_framework_cellar_binary(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            prefix=Path(directory).resolve()
            runtime=prefix/'Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/bin/python3.13'
            runtime.parent.mkdir(parents=True);runtime.write_text('fixture');runtime.chmod(0o700)
            stable=prefix/'opt/python@3.13/bin/python3.13';stable.parent.mkdir(parents=True)
            stable.symlink_to(runtime)
            with patch.object(installer.sys,'executable',str(runtime)),patch.object(installer.shutil,'which',return_value=None),patch.object(installer.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout='')):
                selected=installer.installed_python()
            self.assertEqual(selected,stable)
            self.assertNotIn('Cellar',str(selected))

    def test_default_uses_the_running_installed_interpreter(self):
        selected=installer.installed_python()
        actual=subprocess.check_output([str(selected),'-c','import os,sys; print(os.path.realpath(sys.executable))'],text=True).strip()
        self.assertEqual(actual,str(Path(installer.sys.executable).resolve()))

    def test_installer_pins_selected_runtime_without_a_homebrew_version_assumption(self):
        from types import SimpleNamespace
        for version in ['3.9','3.14']:
            with self.subTest(version=version),tempfile.TemporaryDirectory() as directory:
                home=Path(directory).resolve();python=home/('runtime '+version)/('python'+version)
                python.parent.mkdir();python.write_text('fixture');python.chmod(0o700)
                libexec=python.parent.parent/'libexec/bin';libexec.mkdir(parents=True)
                base=home/'.local/share/cassini-mac-test-releases';source=base/'source'
                (source/'scripts').mkdir(parents=True);(source/'scripts/daily-test-release.py').write_text('fixture')
                (base/'owned-checkout').write_text('cassini-mac-test-releases')
                def run(args,**kwargs):
                    return SimpleNamespace(returncode=1 if args[:2]==['launchctl','print'] else 0)
                with patch.object(installer.sys,'platform','darwin'),patch.object(installer.socket,'gethostname',return_value='drmeyers'),patch.object(installer.Path,'home',return_value=home),patch.object(installer.subprocess,'run',side_effect=run),patch.object(installer.subprocess,'check_output',return_value=daily.ORIGIN):
                    installer.install(python)
                import plistlib
                config=plistlib.loads((home/'Library/LaunchAgents/io.codemyriad.cassini.daily-test-release.plist').read_bytes())
                self.assertEqual(config['ProgramArguments'],[str(python.resolve()),str(source/'scripts/daily-test-release.py')])
                self.assertEqual(config['EnvironmentVariables']['PATH'].split(':')[0],str(python.parent))
                self.assertIn(str(libexec),config['EnvironmentVariables']['PATH'].split(':'))
                self.assertNotIn('python@3.12',str(config))

    def test_stable_interpreter_symlink_is_not_pinned_to_its_current_target(self):
        with tempfile.TemporaryDirectory() as directory:
            link=Path(directory)/'python-link';link.symlink_to(Path(installer.sys.executable).resolve())
            self.assertEqual(installer.installed_python(link),link)

    def test_missing_or_unsupported_interpreter_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            missing=Path(directory)/'python'
            with self.assertRaises(ValueError):installer.installed_python(missing)
            missing.write_text('fixture');missing.chmod(0o700)
            with patch.object(installer.subprocess,'run',return_value=type('Probe',(),{'returncode':1})()):
                with self.assertRaises(ValueError):installer.installed_python(missing)

class FailedJobPruning(unittest.TestCase):
    def test_failed_outputs_are_removed_with_bounded_private_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(daily,'BASE',Path(directory)):
            base=Path(directory);outside=base/'untouched';outside.write_text('private outside data')
            for number in range(1,6):
                job=base/('build-'+str(number)+'-fixture');(job/'DerivedData').mkdir(parents=True)
                (job/'DerivedData/large-product').write_text('owned output')
                (job/'release').mkdir();(job/'release/build.log').write_bytes(b'x'*(1024**2)+b'TAIL')
                (job/'release-driver.log').write_text('driver failure')
                (job/'release/app-notary.json').symlink_to(outside)
                daily.atomic(job/'job.json',dict(schema='cassini-mac-test-job@1',phase='failed',build=number,head='a'*40))
            active=base/'build-active';active.mkdir();daily.atomic(active/'job.json',dict(schema='cassini-mac-test-job@1',phase='building',build=6,head='a'*40))
            unmarked=base/'build-unmarked';unmarked.mkdir();(unmarked/'product').write_text('not owned')
            (base/'build-link').symlink_to(unmarked,target_is_directory=True)
            invalid=base/'build-invalid';invalid.mkdir();(invalid/'job.json').write_text('[]')
            daily.prune_failed_builds()
            self.assertTrue(invalid.is_dir())
            self.assertTrue(active.is_dir());self.assertTrue((unmarked/'product').is_file())
            self.assertTrue((base/'build-link').is_symlink());self.assertEqual(outside.read_text(),'private outside data')
            archives=sorted((base/'failures').glob('build-*'))
            self.assertEqual([p.name for p in archives],['build-3-fixture','build-4-fixture','build-5-fixture'])
            for archive in archives:
                self.assertFalse((base/archive.name).exists())
                self.assertEqual((archive/'release-driver.log.tail').read_text(),'driver failure')
                tail=archive/'release-build.log.tail';self.assertEqual(tail.stat().st_size,1024**2)
                self.assertTrue(tail.read_bytes().endswith(b'TAIL'));self.assertEqual(tail.stat().st_mode&0o777,0o600)
                self.assertFalse((archive/'release-app-notary.json.tail').exists())

    def test_unmarked_archive_collision_never_overwrites_or_deletes_data(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(daily,'BASE',Path(directory)):
            base=Path(directory);job=base/'build-1-fixture';job.mkdir()
            daily.atomic(job/'job.json',dict(schema='cassini-mac-test-job@1',phase='failed',build=1,head='a'*40))
            unowned=base/'failures'/job.name;unowned.mkdir(parents=True);(unowned/'sentinel').write_text('keep')
            with self.assertRaises(ValueError):daily.prune_failed_builds()
            self.assertTrue(job.is_dir());self.assertEqual((unowned/'sentinel').read_text(),'keep')

    def test_symlinked_archive_refuses_cleanup_without_deleting_job(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(daily,'BASE',Path(directory)):
            base=Path(directory);job=base/'build-1-fixture';job.mkdir()
            daily.atomic(job/'job.json',dict(schema='cassini-mac-test-job@1',phase='failed',build=1,head='a'*40))
            outside=base/'outside';outside.mkdir();(base/'failures').symlink_to(outside,target_is_directory=True)
            with self.assertRaises(ValueError):daily.prune_failed_builds()
            self.assertTrue(job.is_dir())

class OwnedBuildCleanup(unittest.TestCase):
    def test_timeout_stops_only_its_new_process_group(self):
        import subprocess
        from unittest.mock import Mock
        process=Mock(pid=4123);process.wait.side_effect=[subprocess.TimeoutExpired('fixture',1),0]
        with patch.object(daily.subprocess,'Popen',return_value=process) as spawn,patch.object(daily.os,'killpg') as stop:
            with self.assertRaisesRegex(RuntimeError,'own process group stopped'):
                daily.signed_build(['fixture'],{},None)
            self.assertTrue(spawn.call_args.kwargs['start_new_session'])
            budget=2*3600 + 2*(600+2800+360) + 600 + 3600 + 900
            self.assertGreaterEqual(process.wait.call_args_list[0].kwargs['timeout'],budget)
            stop.assert_called_once_with(4123,daily.signal.SIGTERM)

class TestModeBuilder(unittest.TestCase):
    def test_stable_release_passes_its_interpreter_to_xcode(self):
        from types import SimpleNamespace
        class Reached(BaseException):pass
        release=load('stable_builder','release.py')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);notes=root/'notes.html';notes.write_text('User changes')
            args=SimpleNamespace(test_release=False,version='1.0',build=2,release_notes=notes,
                base_url=release.BASE_URL,notary_config=root/'unused',output=root/'output')
            with patch.object(release,'ROOT',root),patch.object(release,'notary_credentials',return_value=[]),patch.object(release,'unlock_signing_keychain',return_value=(root/'keychain','identity')),patch.object(release,'verify_update_key',return_value=root/'key'),patch.object(release,'dmg_tools'),patch.object(release,'run',return_value=b'/unused'),patch.object(release.subprocess,'run',side_effect=Reached) as compile_app:
                with self.assertRaises(Reached):release.release(args)
            self.assertEqual(compile_app.call_args.kwargs['env']['CASSINI_PYTHON'],release.sys.executable)

    def test_signed_test_mode_never_reads_update_seed_or_generates_public_feed(self):
        from contextlib import ExitStack
        from types import SimpleNamespace
        import plistlib,shutil,subprocess
        release=load('test_builder','release.py')
        with tempfile.TemporaryDirectory() as directory,ExitStack() as stack:
            root=Path(directory);repo=root/'repo';repo.mkdir();derived=root/'derived';output=root/'output'
            args=SimpleNamespace(test_release=True,version='0.1.0',build=2,release_notes=None,derived_data=derived,
                base_url=release.BASE_URL,notary_config=root/'unused',output=output)
            stack.enter_context(patch.object(release,'ROOT',repo))
            stack.enter_context(patch.object(release,'notary_credentials',return_value=[]))
            stack.enter_context(patch.object(release,'unlock_signing_keychain',return_value=(root/'keychain','public-identity')))
            stack.enter_context(patch.object(release,'dmg_tools',return_value=Path('/unused/python')))
            stack.enter_context(patch.object(release,'heavy_environment',return_value={'CASSINI_PYTHON':release.sys.executable}))
            no_seed=stack.enter_context(patch.object(release,'verify_update_key'))
            no_feed=stack.enter_context(patch.object(release,'write_signed_appcast'))
            no_site=stack.enter_context(patch.object(release,'publication_plan'))
            stack.enter_context(patch.object(release,'submit_and_wait'))
            stack.enter_context(patch.object(release,'notarize'))
            def compile_app(argv,**kwargs):
                self.assertTrue(argv[0].endswith('heavy.sh'))
                self.assertEqual(kwargs['env']['CASSINI_PYTHON'],release.sys.executable)
                settings=dict(arg.split('=',1) for arg in argv if '=' in arg)
                self.assertEqual(settings['CASSINI_UPDATES_ENABLED'],'NO')
                self.assertEqual(settings['CASSINI_UPDATE_FEED'],'')
                app=derived/'Build/Products/Release/Cassini.app/Contents';app.mkdir(parents=True)
                (app/'Info.plist').write_bytes(plistlib.dumps({'CassiniUpdatesEnabled':settings['CASSINI_UPDATES_ENABLED'],'SUFeedURL':settings['CASSINI_UPDATE_FEED']}))
                return subprocess.CompletedProcess(argv,0)
            stack.enter_context(patch.object(release.subprocess,'run',side_effect=compile_app))
            def tool(argv,**kwargs):
                text=list(map(str,argv))
                self.assertFalse(any('sparkle-ed25519.key' in arg or 'sign_update' in arg for arg in text))
                if len(text)>1 and Path(text[1]).name in ['fetch-sparkle.py','verify.py','check-signing-identifiers.py','check-developer-id.py']:
                    self.assertEqual(text[0],release.sys.executable)
                if text[0]=='ditto' and '-c' not in text:shutil.copytree(text[1],text[2])
                if text[0].endswith('heavy.sh'):
                    self.assertGreaterEqual(kwargs['timeout'],60*60+600)
                    self.assertEqual(kwargs['env']['CASSINI_PYTHON'],release.sys.executable)
                    Path(text[-1]).write_bytes(b'test-dmg')
                if text[0]=='git':return ('a'*40+'\n').encode()
                return b'/unused/sparkle'
            stack.enter_context(patch.object(release,'run',side_effect=tool))
            release.release(args)
            no_seed.assert_not_called();no_feed.assert_not_called();no_site.assert_not_called()
            report=json.loads((output/'test-release.json').read_text())
            self.assertEqual(report['channel'],'nightly');self.assertIs(report['updatesEnabled'],False)
            self.assertTrue(report['notarized']);self.assertEqual(report['build'],2)
            self.assertFalse((output/'appcast.xml').exists());self.assertFalse((output/'publication.json').exists())

class BuildPhaseRuntime(unittest.TestCase):
    def test_shell_build_phases_work_with_a_versioned_runtime_and_broken_bare_python(self):
        import os,shlex,sys
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo=root/'source';scripts=repo/'scripts';scripts.mkdir(parents=True)
            log=root/'selected.log';selected=root/'runtime 3.14/python3.14';selected.parent.mkdir()
            selected.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> '+shlex.quote(str(log))+'\nexec '+shlex.quote(sys.executable)+' "$@"\n');selected.chmod(0o700)
            broken=root/'broken';broken.mkdir();(broken/'python3').write_text('#!/bin/sh\nexit 97\n');(broken/'python3').chmod(0o700)
            files=['libopus.0.dylib','LICENSE','pins.json','whistle.cact','NOTICE','silero_vad.onnx','Silero-LICENSE','ONNXRuntime-LICENSE','ONNXRuntime-ThirdPartyNotices.txt','libneedle3.dylib','libonnxruntime.1.23.2.dylib','UPSTREAM.json','Sherpa-LICENSE','model-manifest.json','libsherpa-onnx-c-api.dylib','libonnxruntime.dylib']
            fixture='from pathlib import Path\nimport sys\np=Path(sys.argv[-1]);p.mkdir(parents=True,exist_ok=True)\nfor name in '+repr(files)+': (p/name).write_text("fixture")\n'
            for name in ['ci-products.py','fetch-opus.py','fetch-whistle.py','fetch-vad.py','fetch-parakeet-runtime.py']:(scripts/name).write_text(fixture)
            products=root/'products';products.mkdir()
            for name in ['cassini-whistle-worker','cassini-parakeet-worker']:(products/name).write_text('worker')
            env=dict(os.environ,PATH=str(broken)+':/usr/bin:/bin',CASSINI_PYTHON=str(selected),SRCROOT=str(repo),DERIVED_FILE_DIR=str(root/'derived'),TARGET_BUILD_DIR=str(products),BUILT_PRODUCTS_DIR=str(products),UNLOCALIZED_RESOURCES_FOLDER_PATH='App/Resources',FRAMEWORKS_FOLDER_PATH='App/Frameworks',EXECUTABLE_FOLDER_PATH='App',CONFIGURATION='Release',CODE_SIGNING_ALLOWED='NO')
            for assets in ['', 'fixture-assets']:
                env['CASSINI_CI_ASSETS']=assets
                for name in ['opus','whistle','parakeet']:
                    result=subprocess.run(['/bin/bash',str(ROOT/'scripts'/('bundle-'+name+'.sh'))],env=env,capture_output=True,text=True)
                    self.assertEqual(result.returncode,0,result.stderr)
                for name in ['Opus','Whistle','Parakeet']:
                    manifest=json.loads((products/'App/Resources'/name/'bundle-sha256.json').read_text())
                    self.assertTrue(manifest)
            # Execute both project-authored Python phases with the same hostile PATH.
            for name in ['bundle-companion-page.py','bundle-browser-companion.py']:
                (scripts/name).write_text('from pathlib import Path\nimport sys\nPath(sys.argv[1]).write_text("selected runtime")\n')
            commands=[line.strip()[len('script: '):].strip("'") for line in (ROOT/'project.yml').read_text().splitlines() if 'script:' in line and any(name in line for name in ['bundle-companion-page.py','bundle-browser-companion.py'])]
            self.assertEqual(len(commands),2)
            for command in commands:
                result=subprocess.run(['/bin/bash','-c',command],env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((products/'App/Resources/Cassini.html').read_text(),'selected runtime')
            self.assertEqual((products/'App/Resources/BrowserCompanion').read_text(),'selected runtime')
            self.assertGreaterEqual(len(log.read_text().splitlines()),15)

    def test_companion_verifier_uses_its_running_interpreter(self):
        companion=load('bundle_companion','bundle-browser-companion.py')
        class Reached(BaseException):pass
        with patch.object(companion.subprocess,'run',side_effect=Reached) as verify:
            with self.assertRaises(Reached):companion.reviewed_files()
        self.assertEqual(verify.call_args.args[0][0],companion.sys.executable)


external=load('external','external-derived-build.py')


class ExternalDerivedData(unittest.TestCase):
    """DerivedData on an external volume: the helper that runs in the logged-in session, and the scheduler's use of it."""
    def volumes(self,mounted=True):
        directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
        volumes=Path(directory.name).resolve()/'Volumes';(volumes/'Disk').mkdir(parents=True)
        for item in [patch.object(external,'VOLUMES',volumes),
                     patch.object(external.os.path,'ismount',side_effect=lambda path:mounted and Path(path)==volumes/'Disk')]:
            item.start();self.addCleanup(item.stop)
        return volumes

    def child(self,record,code=0):
        # A real child process that writes where its DerivedData is, and whether the folder exists, then exits.
        script=('import os,sys; d=sys.argv[sys.argv.index("--derived-data")+1]; '
                'open(sys.argv[1],"w").write(d+"\\n"+str(os.path.isdir(d))); sys.exit(int(sys.argv[2]))')
        return [sys.executable,'-c',script,str(record),str(code)]

    def test_a_build_gets_a_private_folder_that_is_gone_afterwards_whatever_the_outcome(self):
        for code in [0,3]:
            with self.subTest(code=code):
                volumes=self.volumes();root=volumes/'Disk/cassini-mac-test-releases';record=volumes/'record'
                self.assertEqual(external.build(str(root),self.child(record,code),free=lambda _:25*1024**3),code)
                derived,existed=record.read_text().split('\n')
                self.assertEqual(existed,'True')
                self.assertEqual(Path(derived).parent,root)
                self.assertEqual(list(root.iterdir()),[])
                self.assertEqual(root.stat().st_mode&0o777,0o700)

    def test_too_little_space_an_unmounted_volume_or_a_path_outside_the_volumes_starts_no_build(self):
        volumes=self.volumes();record=volumes/'record'
        with self.assertRaises(ValueError):
            external.build(str(volumes/'Disk/builds'),self.child(record),free=lambda _:25*1024**3-1)
        self.assertEqual(list((volumes/'Disk/builds').iterdir()),[])
        for root in ['relative/builds',str(volumes),str(volumes/'Disk'),str(volumes/'Disk/../Other/builds'),'/tmp/builds']:
            with self.subTest(root=root),self.assertRaises(ValueError):external.build(root,self.child(record))
        link=volumes/'Disk/link';(volumes/'elsewhere').mkdir();link.symlink_to(volumes/'elsewhere')
        with self.assertRaises(ValueError):external.build(str(link/'builds'),self.child(record),free=lambda _:30*1024**3)
        volumes=self.volumes(mounted=False)
        with self.assertRaises(ValueError):external.build(str(volumes/'Disk/builds'),self.child(record))
        self.assertFalse((volumes/'Disk/builds').exists(),'nothing is written under a missing volume\'s mount point')
        self.assertFalse(record.exists())

    def test_a_build_past_its_limit_is_stopped_with_its_group_and_its_folder_removed(self):
        volumes=self.volumes();root=volumes/'Disk/builds';record=volumes/'record'
        # The child reports its folder, then waits for a signal that only the helper's stop sends. A limit of
        # zero has passed as soon as the helper looks, so no test time is spent waiting.
        script=('import signal,sys; open(sys.argv[1],"w").write(sys.argv[sys.argv.index("--derived-data")+1]); '
                'signal.pause()')
        self.assertEqual(external.build(str(root),[sys.executable,'-c',script,str(record)],timeout=0,free=lambda _:30*1024**3),124)
        self.assertEqual(list(root.iterdir()),[])

    def ended(self,pid):
        # Gone, or ended and waiting to be collected by launchd: either way it runs no more.
        state=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip()
        return state=='' or state.startswith('Z')

    def test_a_descendant_that_ignores_the_stop_is_gone_before_the_folder_is_removed(self):
        volumes=self.volumes();root=volumes/'Disk/builds'
        ready=volumes/'ready';os.mkfifo(ready)
        # The build starts a descendant that ignores SIGTERM and then says it is ready through a FIFO; the build
        # itself exits on SIGTERM. The helper is let go only once the descendant is ready, with its limit at zero.
        descendant=('import os,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                    'f=open(sys.argv[1],"w"); f.write(str(os.getpid())+" "+sys.argv[2]); f.close(); '
                    '[signal.pause() for _ in iter(int,1)]')
        leader=('import signal,subprocess,sys; d=sys.argv[sys.argv.index("--derived-data")+1]; '
                'subprocess.Popen([sys.executable,"-c",sys.argv[2],sys.argv[1],d]); signal.pause()')
        seen={}
        def started(process):
            with open(ready) as stream:pid,derived=stream.read().split(' ',1)
            seen.update(pid=int(pid),derived=Path(derived),existed=Path(derived).is_dir(),group=os.getpgid(int(pid)),leader=process.pid)
        code=external.build(str(root),[sys.executable,'-c',leader,str(ready),descendant],timeout=0,grace=0,
                            free=lambda _:30*1024**3,started=started)
        self.assertEqual(code,124)
        self.assertTrue(seen['existed']);self.assertEqual(seen['group'],seen['leader'],'the descendant is in the build\'s own group')
        self.assertTrue(self.ended(seen['pid']))
        self.assertFalse(seen['derived'].exists())
        self.assertEqual(list(root.iterdir()),[])

    def test_a_descendant_left_by_a_build_that_exited_is_stopped_too(self):
        volumes=self.volumes();root=volumes/'Disk/builds'
        ready=volumes/'ready';os.mkfifo(ready)
        descendant=('import os,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                    'f=open(sys.argv[1],"w"); f.write(str(os.getpid())); f.close(); [signal.pause() for _ in iter(int,1)]')
        # The build waits until its descendant is ready (it reads the FIFO), then exits with 0 and leaves it.
        leader=('import subprocess,sys; subprocess.Popen([sys.executable,"-c",sys.argv[2],sys.argv[1]]); '
                'open(sys.argv[3],"w").write(open(sys.argv[1]).read())')
        record=volumes/'pid'
        self.assertEqual(external.build(str(root),[sys.executable,'-c',leader,str(ready),descendant,str(record)],grace=0,free=lambda _:30*1024**3),0)
        self.assertTrue(self.ended(int(record.read_text())))
        self.assertEqual(list(root.iterdir()),[])

    def test_each_build_phase_checks_the_disk_its_files_go_to(self):
        release=load('release_storage','release.py')
        gib=1024**3;pressure='System-wide memory free percentage: 40%'
        with tempfile.TemporaryDirectory() as directory:
            internal=Path(directory)/'job/release';external_derived=Path(directory)/'volume/derived-x'
            internal.mkdir(parents=True);(Path(directory)/'volume').mkdir()
            # One disk: the single 25 GiB check, as before.
            with patch.object(release,'same_disk',return_value=True):
                reserves,command=resources.storage([*map(str,release.build_reserves(internal.parent/'DerivedData',internal)),'xcodebuild','build'])
            self.assertEqual((reserves,command),([(15,internal.parent/'DerivedData')],['xcodebuild','build']))
            # Two disks: 25 GiB where DerivedData goes, 13 GiB where the products go. The command is the one
            # release.py passes to release-resources.py, parsed and admitted by that script's own functions.
            with patch.object(release,'same_disk',return_value=False):
                arguments=[*map(str,release.build_reserves(external_derived,internal)),'xcodebuild','build']
            reserves,command=resources.storage(arguments)
            self.assertEqual(reserves,[(15,external_derived),(3,internal)])
            def disks(external_free,internal_free):
                # The folder for DerivedData does not exist yet: its parent's disk is the one measured.
                return lambda path:{Path(directory)/'volume':external_free,internal:internal_free}[path]
            resources.admit_all(reserves,pressure,disks(25*gib,13*gib))
            for external_free,internal_free in [(25*gib-1,40*gib),(40*gib,13*gib-1)]:
                with self.subTest(external=external_free,internal=internal_free),self.assertRaises(ValueError):
                    resources.admit_all(reserves,pressure,disks(external_free,internal_free))
            # The internal disk at 14 GiB, far below the old 25: admitted when DerivedData is elsewhere.
            resources.admit_all(reserves,pressure,disks(60*gib,14*gib))
            with self.assertRaises(ValueError):resources.admit_all([(15,internal)],pressure,disks(60*gib,14*gib))
        self.assertEqual(resources.storage(['3','hdiutil','create']),([(3,ROOT)],['hdiutil','create']))
        for bad in [['--reserve','3'],['--reserve','3','/tmp'],['15']]:
            with self.subTest(bad=bad),self.assertRaises(ValueError):resources.storage(bad)
        source=(ROOT/'scripts/release.py').read_text()
        self.assertEqual(source.count("release-resources.py', *build_reserves(derived,output)"),1)
        self.assertEqual(source.count("release-resources.py','--reserve','3',output,"),1,'the disk-image phase checks the products\' disk')
        self.assertTrue(release.same_disk(ROOT,ROOT/'does/not/exist/yet'))

    def test_the_scheduler_needs_both_settings_and_checks_them(self):
        with tempfile.TemporaryDirectory() as directory:
            runner=Path(directory)/'guirun';runner.write_text('#!/bin/sh\n');runner.chmod(0o700)
            plain=Path(directory)/'not-a-program';plain.write_text('')
            root='/Volumes/Disk/cassini-mac-test-releases'
            def configured(**values):
                keys=dict(root='CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT',runner='CASSINI_MAC_TEST_RELEASE_AQUA')
                environment={keys[name]:value for name,value in values.items()}
                with patch.dict(daily.os.environ,environment):
                    for key in keys.values():
                        if key not in environment:daily.os.environ.pop(key,None)
                    return daily.external_build()
            self.assertIsNone(configured())
            self.assertEqual(configured(root=root,runner=str(runner)),(str(runner),root))
            for values in [dict(root=root),dict(runner=str(runner)),dict(root='/tmp/builds',runner=str(runner)),
                           dict(root='/Volumes/Disk',runner=str(runner)),dict(root='/Volumes/Disk/../x/y',runner=str(runner)),
                           dict(root=root,runner=str(plain)),dict(root=root,runner='guirun'),dict(root=root,runner=str(Path(directory)/'absent'))]:
                with self.subTest(values=values),self.assertRaises(ValueError):configured(**values)

    def test_a_configured_scheduler_builds_through_the_runner_and_keeps_only_a_small_internal_reserve(self):
        execution=DailyExecution();self.addCleanup(execution.doCleanups)
        instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=execution.context(directory)
            runner=Path(directory)/'guirun';runner.write_text('#!/bin/sh\n');runner.chmod(0o700)
            root='/Volumes/Disk/cassini-mac-test-releases'
            environment=dict(CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT=root,CASSINI_MAC_TEST_RELEASE_AQUA=str(runner))
            small=type('Disk',(),{'free':14*1024**3})()
            # 14 GiB on the internal disk: not enough for a build that keeps DerivedData there, enough for one that does not.
            with patch.object(daily.shutil,'disk_usage',return_value=small):
                with patch.dict(daily.os.environ,environment),self.assertRaises(SystemExit):daily.tick(instant)
            build.assert_called_once()
            command=build.call_args.args[0]
            helper=str(daily.SOURCE/'scripts/external-derived-build.py')
            self.assertEqual(command[:4],[str(runner),daily.sys.executable,helper,root])
            self.assertEqual(command[4:6],[daily.sys.executable,str(daily.SOURCE/'scripts/release.py')])
            self.assertNotIn('--derived-data',command,'the helper names the folder it makes')
            self.assertIn('--output',command)
            self.assertTrue(Path(command[command.index('--output')+1]).is_relative_to(base),'products stay beside the job')
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=execution.context(directory)
            with patch.object(daily.shutil,'disk_usage',return_value=type('Disk',(),{'free':13*1024**3-1})()), \
                 patch.dict(daily.os.environ,dict(CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT='/Volumes/Disk/builds',CASSINI_MAC_TEST_RELEASE_AQUA=str(Path(sys.executable)))), \
                 self.assertRaises(SystemExit):daily.tick(instant)
            build.assert_not_called()
            self.assertIn('disk reserve',(base/'inbox').read_text())
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=execution.context(directory)
            with patch.dict(daily.os.environ,dict(CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT='/Volumes/Disk/builds')),self.assertRaises(SystemExit):
                daily.os.environ.pop('CASSINI_MAC_TEST_RELEASE_AQUA',None);daily.tick(instant)
            build.assert_not_called()
            self.assertNotIn('build',json.loads((base/'state.json').read_text()),'no build number is used')

    def test_external_preflight_failures_report_disk_reserve_without_burning_a_build_number(self):
        volumes=self.volumes();root=volumes/'Disk/cassini-mac-test-releases'
        self.assertEqual(external.preflight(str(root),free=lambda _:25*1024**3),root)
        self.assertEqual(list(root.iterdir()),[])
        self.assertEqual(root.stat().st_mode&0o777,0o700)
        with self.assertRaises(ValueError):
            external.preflight(str(root),free=lambda _:25*1024**3-1)
        with patch.object(external.tempfile,'mkdtemp',side_effect=PermissionError(1,'Operation not permitted',str(root))):
            with self.assertRaises(PermissionError):
                external.preflight(str(root),free=lambda _:30*1024**3)
        # CLI --preflight and build mode convert PermissionError (macOS TCC removable-volume denial) to exit 2 without traceback.
        import contextlib,io,runpy,shutil
        tcc_root='/Volumes/DrMeyers2/cassini-mac-test-releases'
        for cli_argv in [['external-derived-build.py','--preflight',tcc_root],
                         ['external-derived-build.py',tcc_root,'true']]:
            err=io.StringIO()
            with patch.object(sys,'argv',cli_argv), \
                 patch.object(external.os.path,'ismount',return_value=True), \
                 patch.object(shutil,'disk_usage',return_value=type('Disk',(),{'free':30*1024**3})()), \
                 patch('pathlib.Path.mkdir',side_effect=PermissionError(1,'Operation not permitted',tcc_root)), \
                 contextlib.redirect_stderr(err), \
                 self.assertRaises(SystemExit) as exited:
                runpy.run_path(str(ROOT/'scripts/external-derived-build.py'),run_name='__main__')
            self.assertEqual(exited.exception.code,2)
            self.assertIn('Operation not permitted',err.getvalue())
            self.assertNotIn('Traceback',err.getvalue())
        real_cli=subprocess.run([sys.executable,str(ROOT/'scripts/external-derived-build.py'),'--preflight','/tmp/not-in-volumes'],
                                capture_output=True,text=True)
        self.assertEqual(real_cli.returncode,2)
        self.assertNotIn('Traceback',real_cli.stderr)
        self.assertIn('External build root must be a folder inside /Volumes/<volume>',real_cli.stderr)
        # Scheduler integration: when Aqua runner / external-derived-build.py --preflight fails (TCC EPERM or runner 69),
        # tick() fails in 'disk reserve' BEFORE next_build() reserves a build number or creates a build-* job.
        execution=DailyExecution();self.addCleanup(execution.doCleanups)
        instant=datetime.fromisoformat('2026-11-11T13:00:00+00:00')
        import shlex
        for code,stderr,expected in [
            (2,"[Errno 1] Operation not permitted: '/Volumes/DrMeyers2/cassini-mac-test-releases/preflight-x'",'Operation not permitted'),
            (69,'GUI tmux session is unavailable','GUI tmux session is unavailable'),
        ]:
            with self.subTest(code=code),tempfile.TemporaryDirectory() as directory:
                base,_,build=execution.context(directory)
                daily.atomic(base/'state.json',dict(build=2))
                runner=Path(directory)/'guirun'
                runner.write_text(f'#!/bin/sh\nprintf "%s\\n" {shlex.quote(stderr)} >&2\nexit {code}\n')
                runner.chmod(0o700)
                environment=dict(CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT='/Volumes/DrMeyers2/cassini-mac-test-releases',
                                 CASSINI_MAC_TEST_RELEASE_AQUA=str(runner))
                with patch.dict(daily.os.environ,environment),self.assertRaises(SystemExit):
                    daily.tick(instant)
                build.assert_not_called()
                saved=json.loads((base/'state.json').read_text())
                self.assertEqual(saved['build'],2,'failed preflight must not burn build 3')
                self.assertEqual(list(base.glob('build-*')),[])
                self.assertFalse((base/'failures').exists())
                inbox=(base/'inbox').read_text()
                self.assertIn('daily test release failed: disk reserve: External build volume preflight failed:',inbox)
                self.assertIn(expected,inbox)
                self.assertNotIn('signing/notarization',inbox)

    def test_an_unconfigured_scheduler_builds_as_before(self):
        execution=DailyExecution();self.addCleanup(execution.doCleanups)
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=execution.context(directory)
            with patch.dict(daily.os.environ,{}),self.assertRaises(SystemExit):
                for key in ['CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT','CASSINI_MAC_TEST_RELEASE_AQUA']:daily.os.environ.pop(key,None)
                daily.tick(datetime.fromisoformat('2026-11-11T13:00:00+00:00'))
            command=build.call_args.args[0]
            self.assertEqual(command[:2],[daily.sys.executable,str(daily.SOURCE/'scripts/release.py')])
            derived=Path(command[command.index('--derived-data')+1])
            self.assertTrue(derived.is_relative_to(base))

    def test_the_installer_writes_both_settings_or_neither(self):
        from types import SimpleNamespace
        import plistlib
        for configured in [False,True]:
            with self.subTest(configured=configured),tempfile.TemporaryDirectory() as directory:
                home=Path(directory).resolve();python=home/'runtime/python3'
                python.parent.mkdir();python.write_text('fixture');python.chmod(0o700)
                base=home/'.local/share/cassini-mac-test-releases';source=base/'source'
                (source/'scripts').mkdir(parents=True);(source/'scripts/daily-test-release.py').write_text('fixture')
                (base/'owned-checkout').write_text('cassini-mac-test-releases')
                def run(args,**kwargs):
                    return SimpleNamespace(returncode=1 if args[:2]==['launchctl','print'] else 0)
                with patch.object(installer.sys,'platform','darwin'),patch.object(installer.socket,'gethostname',return_value='drmeyers'), \
                     patch.object(installer.Path,'home',return_value=home),patch.object(installer.subprocess,'run',side_effect=run), \
                     patch.object(installer.subprocess,'check_output',return_value=daily.ORIGIN),patch.object(installer,'installed_python',return_value=python):
                    if configured:
                        with self.assertRaises(SystemExit):installer.install(python,Path('/Volumes/Disk/builds'),None)
                        installer.install(python,Path('/Volumes/Disk/builds'),Path('/Users/someone/bin/guirun'))
                    else:installer.install(python)
                environment=plistlib.loads((home/'Library/LaunchAgents/io.codemyriad.cassini.daily-test-release.plist').read_bytes())['EnvironmentVariables']
                self.assertEqual(environment.get('CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT'),'/Volumes/Disk/builds' if configured else None)
                self.assertEqual(environment.get('CASSINI_MAC_TEST_RELEASE_AQUA'),'/Users/someone/bin/guirun' if configured else None)

if __name__=='__main__':unittest.main()
