import { cp, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
export async function saveFailure(name, error, session, details = {}) {
  const directory = path.join(path.dirname(fileURLToPath(import.meta.url)), 'artifacts', name);
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, 'failure.json'), JSON.stringify({ error: error.stack, ...details }, null, 2));
  if (session) await cp(session, path.join(directory, 'session'), { recursive: true }).catch(() => {});
  console.error(`Failure artifacts: ${directory}`);
}
