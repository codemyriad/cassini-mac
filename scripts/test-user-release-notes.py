#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast release-note fixtures and real temporary Git history; no publishing."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from user_release_notes import Fragment, ReleaseNotes, FALLBACK, parse_fragment, render, units

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('daily_notes',ROOT/'scripts/daily-test-release.py')
daily=importlib.util.module_from_spec(spec);spec.loader.exec_module(daily)

class UserNotes(unittest.TestCase):
    def test_fixtures_keep_developer_material_only_in_folded_section(self):
        fixtures=[parse_fragment(p.name,p.read_text()) for p in (ROOT/'Tests/ReleaseNotesFixtures').glob('*.md')]
        user=render(fixtures)
        developer='CI #123 D95 refactor Internal.swift and a developer PR title'
        notes=ReleaseNotes(user,developer)
        self.assertEqual(user,'New\n• You can export several meetings together from the Library.\n\nBetter\n• Speaker turns are easier to follow.\n\nFixed\n• Shared meetings keep the right date.')
        for surface in [user,notes.html(),notes.github().split('<details>',1)[0]]:
            for forbidden in ['#123','D95','CI','Internal.swift','developer PR title']:self.assertNotIn(forbidden,surface)
        self.assertIn(developer,notes.github().split('<summary>Developer changelog</summary>',1)[1])
        self.assertLessEqual(units(user),500)

    def test_developer_tokens_cannot_enter_via_fragment(self):
        for text in ['CI is faster.','Fix #123.','Adopt D95.','Refactor Internal.swift.','Tests are faster.','Change file.json.','A [link](https://invalid.example).','<script>bad</script>','A hidden\u202e change.','A control\x1b sequence.']:
            with self.assertRaises(ValueError):parse_fragment('change.md','kind: fixed\n---\n'+text)

    def test_overflow_prioritises_new_and_never_splits_utf16_characters(self):
        highlights=[Fragment('a.md','new','You can share a meeting. '+('😀'*75)),Fragment('b.md','new','You can listen to a speaker. '+('😀'*75))]
        improvements=[Fragment(str(i)+'.md','better','The Library is easier to use. '+('😀'*60)) for i in range(5)]
        user=render(improvements+highlights)
        self.assertLessEqual(units(user),500)
        self.assertTrue(user.endswith('and smaller fixes.'))
        for highlight in highlights:self.assertIn(highlight.text,user)
        self.assertNotIn('The Library is easier',user)
        user.encode('utf-16-le')

    def test_no_fragments_uses_the_approved_under_the_hood_text(self):
        self.assertEqual(render([]),FALLBACK)
        self.assertLessEqual(units(FALLBACK),500)

    def test_fragment_format_and_typographic_apostrophe(self):
        self.assertEqual(parse_fragment('change.md',"kind: better\n---\nYou can't lose your place.\n").text,'You can’t lose your place.')
        for source in ['kind: internal\n---\nA change.','kind: new\nA change.','kind: fixed\n---\n']:
            with self.assertRaises(ValueError):parse_fragment('change.md',source)
        with self.assertRaises(ValueError):ReleaseNotes('😀'*251,'developer')

    def test_real_pending_fragments_are_valid_and_fit(self):
        self.assertFalse(any(p.is_symlink() for p in (ROOT/'release-notes.d').glob('*.md')))
        fragments=[parse_fragment(p.name,p.read_text()) for p in (ROOT/'release-notes.d').glob('*.md') if p.name!='README.md' and not p.is_symlink()]
        self.assertGreater(len(fragments),0)
        self.assertLessEqual(units(render(fragments)),500)

class PublishedTagLedger(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.repo=Path(self.temp.name);self.git('init','-q','-b','main')
        self.patch=patch.object(daily,'SOURCE',self.repo);self.patch.start();self.addCleanup(self.patch.stop)
        self.devs=patch.object(daily,'developer_notes',return_value='developer title #123');self.devs.start();self.addCleanup(self.devs.stop)
        (self.repo/'release-notes.d').mkdir()
    def git(self,*args):
        return subprocess.check_output(['git','-c','user.name=Example Author','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],cwd=self.repo,text=True).strip()
    def commit(self,name,text):
        (self.repo/'release-notes.d'/name).write_text('kind: new\n---\n'+text+'\n')
        self.git('add','.');self.git('commit','-qm','fixture');return self.git('rev-parse','HEAD')

    def test_next_build_only_shows_fragments_after_the_published_tag(self):
        first=self.commit('old.md','You can record a meeting.')
        self.git('tag','v1.0.0-beta.1',first)
        second=self.commit('new.md','You can share a meeting.')
        notes=daily.notes('v1.0.0-beta.1',second)
        self.assertNotIn('record a meeting',notes.user);self.assertIn('share a meeting',notes.user)
        self.assertNotIn('#123',notes.user);self.assertIn('#123',notes.github())
        self.git('tag','v1.0.0-beta.2',second)
        self.git('commit','--allow-empty','-qm','tooling-only')
        self.assertEqual(daily.notes('v1.0.0-beta.2','HEAD').user,FALLBACK)

    def test_overflow_is_consumed_only_by_the_published_source_tag(self):
        for i in range(5):head=self.commit(str(i)+'.md','You can share a meeting. '+('😀'*100))
        before=daily.notes(None,head).user
        self.assertTrue(before.endswith('and smaller fixes.'))
        self.git('tag','v1.0.0-beta.1',head)
        release=dict(prerelease=True,draft=True,tag_name='v1.0.0-beta.1',name='nightly',published_at='now',target_commitish=head)
        self.assertIsNone(daily.latest_nightly([release]))
        self.git('commit','--allow-empty','-qm','no visible change')
        self.assertEqual(daily.notes(None,'HEAD').user,before)
        published=daily.latest_nightly([{**release,'draft':False}])
        self.assertEqual(daily.notes(daily.source_commit(published),'HEAD').user,FALLBACK)

    def test_newer_stable_fragments_do_not_repeat_after_an_older_beta(self):
        beta=self.commit('one.md','You can record a meeting.')
        stable=self.commit('two.md','You can share a meeting.')
        head=self.commit('three.md','You can listen to a speaker.')
        user=daily.notes(beta,head,published_refs=[stable]).user
        self.assertNotIn('record a meeting',user);self.assertNotIn('share a meeting',user)
        self.assertIn('listen to a speaker',user)

    def test_refresh_fetches_a_new_stable_tag_outside_main(self):
        first=self.commit('old.md','You can record a meeting.')
        self.git('tag','v1.0.0')
        other=tempfile.TemporaryDirectory();self.addCleanup(other.cleanup)
        remote=Path(other.name)/'remote.git';client=Path(other.name)/'client'
        self.git('init','--bare','-q',str(remote))
        self.git('push','-q',str(remote),'main','--tags')
        self.git('clone','-q','--single-branch','--branch','main',str(remote),str(client))
        self.git('switch','-qc','hotfix',first)
        self.commit('fix.md','The Library opens normally.')
        self.git('tag','v1.0.1')
        self.git('push','-q',str(remote),'refs/tags/v1.0.1')
        self.git('switch','-q','main')
        head=self.commit('new.md','You can share a meeting.')
        self.git('push','-q',str(remote),'main')
        with patch.object(daily,'SOURCE',client):
            fetched=daily.fetch_main()
            self.assertEqual(fetched,head)
            tag=subprocess.run(['git','show-ref','--verify','--quiet','refs/tags/v1.0.1'],cwd=client)
            self.assertEqual(tag.returncode,0,'The publication ledger needs the new off-main stable tag')
            release=dict(prerelease=False,draft=False,tag_name='v1.0.1',published_at='now')
            self.assertEqual(daily.stable_notes_base([release],head),first)

    def test_changed_fragment_is_new_and_a_hotfix_tag_does_not_wedge_main(self):
        first=self.commit('old.md','You can record a meeting.');self.git('tag','v1.0.0')
        second=self.commit('old.md','You can share a meeting.')
        self.assertIn('share a meeting',daily.notes(first,second).user)
        self.git('switch','-qc','hotfix',first)
        self.commit('fix.md','The Library opens normally.');self.git('tag','v1.0.1');self.git('switch','-q','main')
        release=dict(prerelease=False,draft=False,tag_name='v1.0.1',published_at='now')
        self.assertEqual(daily.stable_notes_base([release],second),first)

if __name__=='__main__':unittest.main()
