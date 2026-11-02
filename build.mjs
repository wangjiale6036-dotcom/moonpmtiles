import {existsSync, mkdirSync, copyFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const local = path.resolve(here, '../../.tools/moon/bin', process.platform === 'win32' ? 'moon.exe' : 'moon');
const moon = existsSync(local) ? local : 'moon';
const result = spawnSync(moon, ['build', '--target', 'js', '--release', 'src/bridge'], {
  cwd: here, stdio: 'inherit',
});
if (result.status !== 0) process.exit(result.status ?? 2);
mkdirSync(path.join(here, 'dist'), {recursive: true});
copyFileSync(path.join(here, '_build/js/release/build/bridge/bridge.js'), path.join(here, 'dist/engine.mjs'));
console.log('Built MoonBit JS engine in dist/engine.mjs');
