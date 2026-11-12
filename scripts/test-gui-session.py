#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import unittest
import gui_session as module
class Admission(unittest.TestCase):
    def env(self,**values):return dict(GITHUB_ACTIONS='true',RUNNER_ENVIRONMENT='self-hosted',CASSINI_CI_GUI='1',**values)
    def test_hosted_fallback_keeps_original_contract(self):
        self.assertEqual(module.admission(dict(GITHUB_ACTIONS='true',RUNNER_ENVIRONMENT='github-hosted'),501,501,True),'hosted')
    def test_exact_dedicated_console_session_is_admitted(self):
        self.assertEqual(module.admission(self.env(),503,503,True),'gui')
    def test_background_other_user_root_and_absent_session_are_rejected(self):
        for uid,console,aqua in [(503,0,True),(501,501,True),(0,0,True),(503,503,False)]:
            with self.subTest(uid=uid,console=console,aqua=aqua),self.assertRaises(ValueError):module.admission(self.env(),uid,console,aqua)
    def test_marker_alone_cannot_admit_local_or_headless_jobs(self):
        for key,value in [('GITHUB_ACTIONS','false'),('RUNNER_ENVIRONMENT',''),('CASSINI_CI_GUI','')]:
            env=self.env();env[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):module.admission(env,503,503,True)
if __name__=='__main__':unittest.main()
