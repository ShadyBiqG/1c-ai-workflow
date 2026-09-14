'use strict';

const { spawn } = require('node:child_process');
const readline = require('node:readline');

const executable = process.argv[2];
const threadId = process.argv[3];
const child = spawn(executable, ['app-server', '--listen', 'stdio://'], {
  stdio: ['pipe', 'pipe', 'inherit'],
  windowsHide: true,
});
const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
let initialized = false;

function send(value) {
  child.stdin.write(`${JSON.stringify(value)}\n`, 'utf8');
}

rl.on('line', (line) => {
  if (!line.trim()) return;
  process.stdout.write(`${line}\n`);
  const message = JSON.parse(line);
  if (message.id === 1 && !initialized) {
    initialized = true;
    send({ method: 'initialized', params: {} });
    send({ method: 'thread/compact/start', id: 2, params: { threadId } });
  }
  if (message.id === 2 || message.method === 'item/completed') {
    setTimeout(() => child.kill(), 250);
  }
});

send({ method: 'initialize', id: 1, params: { clientInfo: { name: 'diagnostic', version: '1' } } });
setTimeout(() => child.kill(), 10000);
