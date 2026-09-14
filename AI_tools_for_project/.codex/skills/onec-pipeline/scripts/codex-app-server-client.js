'use strict';

const fs = require('node:fs');
const readline = require('node:readline');
const { spawn } = require('node:child_process');

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw new Error(`Missing ${name}`);
  return process.argv[index + 1];
}

const configPath = argument('--config');
const receiptPath = argument('--receipt');
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const child = spawn(config.executable, config.prefixArguments || [], {
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});

let nextId = 1;
let stderr = '';
let closed = false;
const pending = new Map();
const notifications = [];
const waiters = [];

child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => { stderr += chunk; });

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`, 'utf8');
}

function request(method, params) {
  const id = nextId++;
  send({ method, id, params });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}`));
    }, config.timeoutMs);
    pending.set(id, { resolve, reject, timer });
  });
}

function matches(message, predicate) {
  try { return predicate(message); } catch { return false; }
}

function waitForNotification(predicate, label) {
  const existingIndex = notifications.findIndex((message) => matches(message, predicate));
  if (existingIndex >= 0) return Promise.resolve(notifications.splice(existingIndex, 1)[0]);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const index = waiters.findIndex((item) => item.resolve === resolve);
      if (index >= 0) waiters.splice(index, 1);
      reject(new Error(`timeout waiting for ${label}`));
    }, config.timeoutMs);
    waiters.push({ predicate, resolve, reject, timer });
  });
}

function accept(message) {
  if (Object.prototype.hasOwnProperty.call(message, 'id')) {
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    clearTimeout(item.timer);
    if (message.error) item.reject(new Error(message.error.message || 'RPC error'));
    else item.resolve(message.result);
    return;
  }

  const waiterIndex = waiters.findIndex((item) => matches(message, item.predicate));
  if (waiterIndex >= 0) {
    const item = waiters.splice(waiterIndex, 1)[0];
    clearTimeout(item.timer);
    item.resolve(message);
  } else {
    notifications.push(message);
  }
}

const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  try { accept(JSON.parse(line)); }
  catch (error) { fail(new Error(`invalid JSONL from app-server: ${error.message}`)); }
});

function rejectAll(error) {
  for (const item of pending.values()) {
    clearTimeout(item.timer);
    item.reject(error);
  }
  pending.clear();
  for (const item of waiters.splice(0)) {
    clearTimeout(item.timer);
    item.reject(error);
  }
}

function fail(error) {
  if (closed) return;
  closed = true;
  rejectAll(error);
  if (!child.killed) child.kill();
}

child.on('error', fail);
child.on('exit', (code) => {
  if (!closed && code !== 0) fail(new Error(`app-server exited ${code}: ${stderr.trim()}`));
});

async function shutdown() {
  if (closed) return;
  closed = true;
  child.stdin.end();
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    new Promise((resolve) => setTimeout(resolve, 1000)),
  ]);
  if (child.exitCode === null && !child.killed) child.kill();
}

async function run() {
  await request('initialize', {
    clientInfo: { name: 'onec_agentic_pipeline', title: '1C Agentic Pipeline', version: '1.0.0' },
  });
  send({ method: 'initialized', params: {} });
  const resumed = await request('thread/resume', { threadId: config.threadId });
  if (!resumed.thread || resumed.thread.id !== config.threadId) {
    throw new Error(`thread ID mismatch: ${config.threadId}`);
  }

  if (config.action === 'compact') {
    await request('thread/compact/start', { threadId: config.threadId });
    const completed = await waitForNotification(
      (message) => message.method === 'item/completed'
        && message.params.threadId === config.threadId
        && message.params.item.type === 'contextCompaction',
      'contextCompaction item/completed',
    );
    return {
      protocol_version: 1,
      thread_id: config.threadId,
      status: 'succeeded',
      item_id: completed.params.item.id,
      item_type: completed.params.item.type,
      completed_at: new Date().toISOString(),
    };
  }

  if (config.action === 'turn') {
    const started = await request('turn/start', {
      threadId: config.threadId,
      input: [{ type: 'text', text: config.text }],
    });
    const completed = await waitForNotification(
      (message) => message.method === 'turn/completed'
        && message.params.threadId === config.threadId
        && message.params.turn.id === started.turn.id,
      'turn/completed',
    );
    return {
      protocol_version: 1,
      thread_id: config.threadId,
      turn_id: started.turn.id,
      status: completed.params.turn.status,
      accepted_text: started.turn.acceptedText || config.text,
      completed_at: new Date().toISOString(),
    };
  }

  throw new Error(`unsupported action: ${config.action}`);
}

(async () => {
  try {
    const receipt = await run();
    fs.writeFileSync(receiptPath, JSON.stringify(receipt, null, 2), 'utf8');
    await shutdown();
  } catch (error) {
    console.error(error.message);
    if (stderr.trim()) console.error(stderr.trim());
    fail(error);
    process.exitCode = 1;
  }
})();
