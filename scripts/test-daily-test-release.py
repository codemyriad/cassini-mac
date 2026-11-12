#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast policy tests: no signing, network, real state or app execution."""
from datetime import datetime,timezone
import importlib.util
import json
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
        untrusted=[{**good,'event':event} for event in ['pull_request','pull_request_target','workflow_run','schedule']]
        untrusted += [{**good,'head_repository':repo} for repo in [None,{}, {'full_name':'fork/cassini-mac'}]]
        for run in untrusted:
            self.assertFalse(daily.eligible_ci([run],'a'*40))
            self.assertTrue(daily.eligible_ci([{**run,'status':'action_required'},good],'a'*40))
            self.assertFalse(daily.eligible_ci([run,{**good,'conclusion':'failure'},good],'a'*40))
        self.assertTrue(daily.eligible_ci([{**good,'event':'workflow_dispatch'}],'a'*40))
        self.assertFalse(daily.eligible_ci([{**good,'event':'workflow_dispatch','status':'in_progress'},good],'a'*40))

    def test_main_ci_searches_past_an_entire_page_of_pr_runs(self):
        good=dict(head_sha='a'*40,head_branch='main',status='completed',conclusion='success',event='push',head_repository={'full_name':daily.REPO})
        pages=[{'workflow_runs':[{**good,'event':'pull_request'}]*100},{'workflow_runs':[good]}]
        with patch.object(daily,'gh',return_value=pages) as api:
            self.assertTrue(daily.main_is_green('a'*40))
            self.assertIn('--paginate',api.call_args.args[0]);self.assertIn('--slurp',api.call_args.args[0])
        with patch.object(daily,'gh',return_value=pages[:1]):
            self.assertFalse(daily.main_is_green('a'*40))

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

    def test_red_main_and_unchanged_head_never_build_or_repeat_a_slot(self):
        for green,unchanged in [(False,False),(True,True)]:
            with tempfile.TemporaryDirectory() as directory:
                base,calls,build=self.context(directory,green,unchanged)
                instant=datetime.fromisoformat('2026-11-11T08:00:00+00:00')
                daily.tick(instant);count=calls.call_count;daily.tick(instant)
                build.assert_not_called();self.assertEqual(calls.call_count,count)
                self.assertIn('skipped:',(base/'inbox').read_text())

    def test_local_success_prevents_rebuild_when_remote_release_listing_is_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            daily.atomic(base/'state.json',{'last_success':'a'*40,'build':9})
            daily.tick(datetime.fromisoformat('2026-11-11T08:00:00+00:00'))
            build.assert_not_called()
            self.assertIn('main unchanged',(base/'inbox').read_text())

    def test_failed_build_is_not_retried_within_slot_but_next_slot_reports_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            base,_,build=self.context(directory)
            first=datetime.fromisoformat('2026-11-11T08:00:00+00:00')
            with self.assertRaises(SystemExit):daily.tick(first)
            daily.tick(first);self.assertEqual(build.call_count,1)
            with self.assertRaises(SystemExit):daily.tick(datetime.fromisoformat('2026-11-11T13:00:00+00:00'))
            self.assertEqual(build.call_count,2)
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
        for complete in [False,True]:
            with tempfile.TemporaryDirectory() as directory:
                output=Path(directory);name='Cassini-talk-0.1.0-test.2.dmg';data=b'notarized fixture'
                (output/name).write_bytes(data);digest=hashlib.sha256(data).hexdigest()
                (output/'test-release.json').write_text(json.dumps(dict(channel='nightly',commit='a'*40,version='0.1.0',build=2,notarized=True,updatesEnabled=False,dmg=name,bytes=len(data),sha256=digest)))
                (output/'SHA256SUMS').write_text(digest+'  '+name+'\n')
                user=daily.ReleaseNotes('A clearer Library.','CI D95 #123 Internal.swift developer PR title')
                (output/'user-release-notes.txt').write_text(user.user+'\n')
                (output/'user-release-notes.html').write_text(user.html())
                assets=[dict(name=p.name,size=p.stat().st_size) for p in output.iterdir()]
                if not complete:assets=assets[:1]
                with patch.object(daily,'command') as tool,patch.object(daily,'gh',return_value=dict(draft=True,prerelease=True,assets=assets)):
                    if complete:daily.publish('v0.1.0-beta.2','0.1.0',2,'a'*40,output,user)
                    else:
                        with self.assertRaises(ValueError):daily.publish('v0.1.0-beta.2','0.1.0',2,'a'*40,output,user)
                    edits=[c.args[0] for c in tool.call_args_list if c.args[0][1:3]==['release','edit']]
                    self.assertEqual(len(edits),int(complete))
                    if edits:self.assertIn('--prerelease',edits[0]);self.assertIn('--latest=false',edits[0])
                    self.assertFalse(any('--clobber' in c.args[0] for c in tool.call_args_list))
                    self.assertEqual((output/'user-release-notes.txt').read_text(),user.user+'\n')
                    for token in ['CI','D95','#123','Internal.swift','developer PR title']:
                        self.assertNotIn(token,(output/'user-release-notes.html').read_text())
                    self.assertIn(user.developer,(output/'nightly-notes.md').read_text().split('<details>',1)[1])
                    upload=next(c.args[0] for c in tool.call_args_list if c.args[0][1:3]==['release','upload'])
                    self.assertIn(output/'user-release-notes.txt',upload);self.assertIn(output/'user-release-notes.html',upload)


class OwnedBuildCleanup(unittest.TestCase):
    def test_timeout_stops_only_its_new_process_group(self):
        import subprocess
        from unittest.mock import Mock
        process=Mock(pid=4123);process.wait.side_effect=[subprocess.TimeoutExpired('fixture',1),0]
        with patch.object(daily.subprocess,'Popen',return_value=process) as spawn,patch.object(daily.os,'killpg') as stop:
            with self.assertRaisesRegex(RuntimeError,'own process group stopped'):
                daily.signed_build(['fixture'],{},None)
            self.assertTrue(spawn.call_args.kwargs['start_new_session'])
            stop.assert_called_once_with(4123,daily.signal.SIGTERM)

class TestModeBuilder(unittest.TestCase):
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
            stack.enter_context(patch.object(release,'heavy_environment',return_value={}))
            no_seed=stack.enter_context(patch.object(release,'verify_update_key'))
            no_feed=stack.enter_context(patch.object(release,'write_signed_appcast'))
            no_site=stack.enter_context(patch.object(release,'publication_plan'))
            stack.enter_context(patch.object(release,'submit_and_wait'))
            stack.enter_context(patch.object(release,'notarize'))
            def compile_app(argv,**kwargs):
                self.assertTrue(argv[0].endswith('heavy.sh'))
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
                if text[0]=='ditto' and '-c' not in text:shutil.copytree(text[1],text[2])
                if text[0].endswith('heavy.sh'):Path(text[-1]).write_bytes(b'test-dmg')
                if text[0]=='git':return ('a'*40+'\n').encode()
                return b'/unused/sparkle'
            stack.enter_context(patch.object(release,'run',side_effect=tool))
            release.release(args)
            no_seed.assert_not_called();no_feed.assert_not_called();no_site.assert_not_called()
            report=json.loads((output/'test-release.json').read_text())
            self.assertEqual(report['channel'],'nightly');self.assertIs(report['updatesEnabled'],False)
            self.assertTrue(report['notarized']);self.assertEqual(report['build'],2)
            self.assertFalse((output/'appcast.xml').exists());self.assertFalse((output/'publication.json').exists())

if __name__=='__main__':unittest.main()
