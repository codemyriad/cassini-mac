# SPDX-License-Identifier: GPL-3.0-or-later
"""Build-only signature-cache regression; generated programs and tests never run."""
from pathlib import Path
import json,plistlib,subprocess,tempfile,sys
with tempfile.TemporaryDirectory(prefix='cassini-d27-tool-build-') as temporary:
 root=Path(temporary);(root/'main.c').write_text('int main(void) { return 0; }\n')
 (root/'Tests.swift').write_text('import XCTest\nfinal class Placeholder: XCTestCase { func testPlaceholder() {} }\n')
 (root/'Host.entitlements').write_bytes(plistlib.dumps({}))
 spec={'name':'IdentityFixture','options':{'deploymentTarget':{'macOS':'15.0'}},'settings':{'base':{'CODE_SIGN_IDENTITY':'-','CODE_SIGN_STYLE':'Manual','CODE_SIGN_INJECT_BASE_ENTITLEMENTS':False}},'targets':{'Host':{'type':'tool','platform':'macOS','sources':['main.c'],'settings':{'base':{'PRODUCT_NAME':'identity-host','PRODUCT_BUNDLE_IDENTIFIER':'io.codemyriad.cassini.identity-fixture','CODE_SIGN_ENTITLEMENTS':'Host.entitlements','OTHER_CODE_SIGN_FLAGS':'$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)'}}},'Checks':{'type':'bundle.unit-test','platform':'macOS','sources':['Tests.swift'],'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'io.codemyriad.cassini.identity-fixture.tests','GENERATE_INFOPLIST_FILE':True}}}},'schemes':{'IdentityFixture':{'build':{'targets':{'Host':'all','Checks':['test']}},'test':{'config':'Debug','targets':['Checks']}}}}
 spec['targets']['Stager']={'type':'tool','platform':'macOS','sources':['main.c'],
 'dependencies':[{'target':'Host','link':False,'embed':False}],
 'settings':{'base':{'PRODUCT_NAME':'identity-stager','PRODUCT_BUNDLE_IDENTIFIER':'io.codemyriad.cassini.identity-stager'}},
 'postBuildScripts':[{'name':'Copy signed host','script':'cp "$BUILT_PRODUCTS_DIR/identity-host" "$BUILT_PRODUCTS_DIR/staged-identity-host"',
 'inputFiles':['$(BUILT_PRODUCTS_DIR)/identity-host'],'outputFiles':['$(BUILT_PRODUCTS_DIR)/staged-identity-host'],
 'basedOnDependencyAnalysis':False}]}
 spec['schemes']['IdentityFixture']['build']['targets']={'Stager':'all','Checks':['test']}
 (root/'project.yml').write_text(json.dumps(spec));subprocess.run(['xcodegen','generate','--spec',str(root/'project.yml')],check=True,cwd=root,stdout=subprocess.PIPE)
 base=['xcodebuild','-project',str(root/'IdentityFixture.xcodeproj'),'-scheme','IdentityFixture','-configuration','Debug','-destination','platform=macOS','-derivedDataPath',str(root/'derived')]
 executable=root/'derived/Build/Products/Debug/identity-host'
 def profile(file=None):
  r=subprocess.run(['codesign','-d','--entitlements',':-',str(file or executable)],capture_output=True,check=True)
  return plistlib.loads(r.stdout) if r.stdout.strip() else {}
 for action in ['build-for-testing','build']:
  result=subprocess.run(base+[action],capture_output=True,text=True,timeout=120)
  Path('/tmp/cassini-native-host-staging-'+action+'.log').write_text(result.stdout+result.stderr)
  if result.returncode:print((result.stdout+result.stderr)[-12000:])
  assert result.returncode==0,(action,result.returncode)
  p=profile();print(action,json.dumps(p,sort_keys=True))
  staged=profile(executable.with_name('staged-identity-host'));print(action,'staged',json.dumps(staged,sort_keys=True))
  if action=='build-for-testing':assert 'com.apple.security.temporary-exception.files.absolute-path.read-only' in p
  else:
   assert 'com.apple.security.temporary-exception.files.absolute-path.read-only' not in p
   assert 'com.apple.security.temporary-exception.mach-lookup.global-name' not in p
   assert set(p)<={'com.apple.application-identifier'}
   assert 'com.apple.security.temporary-exception.files.absolute-path.read-only' not in staged, 'Copied host retains old test signature'
 print('PASS normal incremental CLI build removes test entitlements; fixture programs/tests never executed')
