'use strict';

const fs = require('node:fs');
const { spawn, spawnSync } = require('node:child_process');

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw new Error(`Missing ${name}`);
  return process.argv[index + 1];
}

const configPath = argument('--config');
const resultPath = argument('--result');
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const child = spawn(config.executable, config.arguments || [], {
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});

const stdout = [];
const stderr = [];
let timedOut = false;
let finished = false;

child.stdout.on('data', (chunk) => stdout.push(chunk));
child.stderr.on('data', (chunk) => stderr.push(chunk));

function killTree() {
  if (child.exitCode !== null || child.killed) return;
  if (process.platform === 'win32') {
    spawnSync('taskkill.exe', ['/pid', String(child.pid), '/t', '/f'], { windowsHide: true, stdio: 'ignore' });
  } else {
    child.kill('SIGKILL');
  }
}

const timer = setTimeout(() => {
  timedOut = true;
  killTree();
}, config.timeoutMs);

process.on('exit', () => {
  if (!finished) killTree();
});

child.on('error', (error) => {
  clearTimeout(timer);
  console.error(error.message);
  process.exitCode = 1;
});

child.on('close', (code) => {
  clearTimeout(timer);
  finished = true;
  fs.writeFileSync(resultPath, JSON.stringify({
    exit_code: code === null ? -1 : code,
    stdout: Buffer.concat(stdout).toString('utf8'),
    stderr: Buffer.concat(stderr).toString('utf8'),
    timed_out: timedOut,
  }), 'utf8');
});

child.stdin.end(config.input, 'utf8');
