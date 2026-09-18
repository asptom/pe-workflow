import { cpSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const webRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const staticDir = join(webRoot, '..', 'services', 'cmd', 'webapp', 'static');
const browserDir = join(staticDir, 'browser');

if (existsSync(browserDir)) {
  for (const entry of readdirSync(browserDir)) {
    cpSync(join(browserDir, entry), join(staticDir, entry), { recursive: true });
  }
  rmSync(browserDir, { recursive: true, force: true });
  console.log(`Flattened ${browserDir} into ${staticDir}`);
}