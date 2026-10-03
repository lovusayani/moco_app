// Vercel "Install Command" for the moco-web project.
//
// Vercel's build image has Node but no Flutter, so this downloads the pinned
// Flutter SDK release into $FLUTTER_HOME (default ~/flutter-sdk) and
// precaches the web engine. build_web.mjs then uses that SDK.
//
// Pinned on purpose: an unpinned "latest stable" would let a Flutter release
// change the production bundle without any commit in this repo. Bump
// FLUTTER_VERSION together with the version used locally and in CI.
//
// Linux only (Vercel's build image). Locally, use your own `flutter`.

import { execSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const FLUTTER_VERSION = process.env.FLUTTER_VERSION || '3.47.3';
const FLUTTER_HOME = process.env.FLUTTER_HOME || join(homedir(), 'flutter-sdk');
const flutterBin = join(FLUTTER_HOME, 'flutter', 'bin', 'flutter');

const run = (cmd) => execSync(cmd, { stdio: 'inherit', env: { ...process.env, CI: 'true' } });
const has = (cmd) => {
  try {
    execSync(`command -v ${cmd}`, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
};

if (process.platform !== 'linux') {
  console.error('install_flutter.mjs is for the Vercel (Linux) build image. Locally, install Flutter yourself.');
  process.exit(1);
}

// The Flutter tool extracts its engine artifacts with `unzip`, which the
// Amazon Linux build image does not always ship.
if (!has('unzip')) run('dnf install -y unzip');
if (!has('xz')) run('dnf install -y xz');

if (existsSync(flutterBin)) {
  console.log(`Flutter SDK already present at ${FLUTTER_HOME}`);
} else {
  mkdirSync(FLUTTER_HOME, { recursive: true });
  const url = `https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz`;
  console.log(`Downloading Flutter ${FLUTTER_VERSION} from ${url}`);
  run(`curl -fsSL "${url}" | tar -xJ -C "${FLUTTER_HOME}"`);
}

// The SDK tarball is a git checkout owned by another uid; without this, git
// (and therefore `flutter --version`) refuses to read it when run as root.
run(`git config --global --add safe.directory "${join(FLUTTER_HOME, 'flutter')}"`);
run(`"${flutterBin}" config --no-analytics --enable-web`);
run(`"${flutterBin}" precache --web --no-android --no-ios`);
run(`"${flutterBin}" --version`);
