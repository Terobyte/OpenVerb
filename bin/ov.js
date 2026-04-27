#!/usr/bin/env node
'use strict';

// ov — thin wrapper around scripts/install.sh, published to npm so users can
// install OpenVerb with a single command:
//
//     npm install -g openverb-app
//
// After that, the `ov` command:
//   ov              launch the app (installs first if not yet installed)
//   ov install      (re)run the installer
//   ov update       alias for install — fetches latest source and rebuilds
//   ov uninstall    remove /Applications/OpenVerb.app
//   ov help         show usage

const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const APP = '/Applications/OpenVerb.app';
const SCRIPT = path.join(__dirname, '..', 'scripts', 'install.sh');

function platformOk(silent) {
    if (process.platform !== 'darwin') {
        if (!silent) console.error('OpenVerb is macOS-only (got ' + process.platform + ').');
        return false;
    }
    if (process.arch !== 'arm64') {
        if (!silent) console.error('OpenVerb requires Apple Silicon (got ' + process.arch + ').');
        return false;
    }
    return true;
}

function runInstaller() {
    if (!platformOk(false)) process.exit(1);
    if (!fs.existsSync(SCRIPT)) {
        console.error('install.sh missing from this npm package: ' + SCRIPT);
        process.exit(1);
    }
    const r = spawnSync('bash', [SCRIPT], { stdio: 'inherit' });
    process.exit(r.status === null ? 1 : r.status);
}

function launch() {
    if (!fs.existsSync(APP)) {
        console.log('OpenVerb is not installed yet — running installer first.');
        runInstaller();
        return;
    }
    const r = spawnSync('open', [APP], { stdio: 'inherit' });
    process.exit(r.status === null ? 1 : r.status);
}

function uninstall() {
    if (fs.existsSync(APP)) {
        spawnSync('rm', ['-rf', APP], { stdio: 'inherit' });
        console.log('Removed ' + APP);
    } else {
        console.log(APP + ' not present.');
    }
    console.log('Note: keychain identity "OpenVerb Dev" left in place. Remove via Keychain Access if desired.');
    process.exit(0);
}

function help() {
    console.log([
        'Usage:',
        '  ov                # launch OpenVerb (installs first if needed)',
        '  ov install        # (re)run the installer',
        '  ov update         # alias for install — fetches latest source and rebuilds',
        '  ov uninstall      # remove /Applications/OpenVerb.app',
        '  ov help           # show this message',
    ].join('\n'));
    process.exit(0);
}

const action = process.argv[2];

switch (action) {
    // npm postinstall hook — quietly skips when not global / wrong platform.
    case 'postinstall':
        if (process.env.npm_config_global !== 'true') {
            console.log('OpenVerb is a global CLI tool. Install with: npm install -g openverb-app');
            process.exit(0);
        }
        if (!platformOk(true)) {
            console.log('OpenVerb requires macOS on Apple Silicon — skipping postinstall.');
            process.exit(0);
        }
        runInstaller();
        break;

    case undefined:
    case 'launch':
    case 'open':
        launch();
        break;

    case 'install':
    case 'update':
    case 'upgrade':
        runInstaller();
        break;

    case 'uninstall':
    case 'remove':
        uninstall();
        break;

    case 'help':
    case '--help':
    case '-h':
        help();
        break;

    default:
        console.error('Unknown command: ' + action + '\n');
        help();
}
