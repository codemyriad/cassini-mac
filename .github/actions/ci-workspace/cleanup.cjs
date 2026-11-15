const fs = require('node:fs/promises');
const path = require('node:path');
async function cleanup() {
  if (process.env.RUNNER_ENVIRONMENT !== 'self-hosted') return;
  const workspace = process.env.GITHUB_WORKSPACE;
  if (!workspace || !path.isAbsolute(workspace) || workspace === '/') {
    throw new Error('Refusing cleanup without an absolute job workspace');
  }
  // checkout cleans interrupted prior jobs at startup. This post action also
  // removes this job's DerivedData, restored bundles and downloaded products on
  // success/failure/cancellation, after uploads and cache saves have completed.
  for (const name of ['build', '.build']) {
    const target = path.join(workspace, name);
    console.log('Removing job products: ' + target);
    await fs.rm(target, {recursive: true, force: true, maxRetries: 3});
  }
}
cleanup().catch(error => { console.error(error); process.exitCode = 1; });
