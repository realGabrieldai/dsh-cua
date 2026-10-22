#!/usr/bin/env node
// Self-test for the MCP server. No TCC permissions required.
//
// Spawns the server exactly the way a client would, then asserts the protocol contract:
// initialize, tools/list (nine tools, object-rooted schemas), one tools/call, an unknown
// method, and a malformed line that must not kill the loop.

import { spawn } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(HERE, 'server.mjs');

const EXPECTED_TOOLS = [
  'click', 'doctor', 'drag', 'get_app_state', 'list_apps',
  'list_windows', 'press_key', 'scroll', 'type_text',
];

let passed = 0;
const failures = [];

function check(condition, label) {
  if (condition) {
    passed += 1;
  } else {
    failures.push(label);
    console.error(`  FAIL ${label}`);
  }
}

const child = spawn(process.execPath, [SERVER], { stdio: ['pipe', 'pipe', 'pipe'] });

let stdoutBuffer = '';
const pending = new Map();
let nextId = 1;
const protocolErrors = [];

child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  stdoutBuffer += chunk;
  let index;
  while ((index = stdoutBuffer.indexOf('\n')) >= 0) {
    const line = stdoutBuffer.slice(0, index).trim();
    stdoutBuffer = stdoutBuffer.slice(index + 1);
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      protocolErrors.push(`non-JSON on stdout: ${line.slice(0, 200)}`);
      continue;
    }
    if (message.id != null && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    } else if (message.error && message.id == null) {
      // A parse error legitimately answers with id:null (JSON-RPC 2.0). Anything else
      // appearing unprompted on stdout is a defect.
      if (message.error.code !== -32700) {
        protocolErrors.push(`unexpected error frame: ${JSON.stringify(message).slice(0, 200)}`);
      }
    } else if (message.id == null && !message.error) {
      protocolErrors.push(`unsolicited frame: ${JSON.stringify(message).slice(0, 200)}`);
    }
  }
});

child.stderr.setEncoding('utf8');
let stderrText = '';
child.stderr.on('data', (c) => { stderrText += c; });

function request(method, params) {
  const id = nextId++;
  const payload = { jsonrpc: '2.0', id, method, ...(params ? { params } : {}) };
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), 30000);
    pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
    child.stdin.write(`${JSON.stringify(payload)}\n`);
  });
}

function notify(method, params) {
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method, ...(params ? { params } : {}) })}\n`);
}

function raw(line) {
  child.stdin.write(`${line}\n`);
}

async function main() {
  // 1. initialize
  const init = await request('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'dsh-cua-selftest', version: '1.0.0' },
  });
  check(init.result?.protocolVersion === '2024-11-05', 'initialize returns the negotiated protocolVersion');
  check(init.result?.serverInfo?.name === 'dsh-cua', 'initialize reports serverInfo.name');
  check(init.result?.capabilities?.tools !== undefined, 'initialize advertises tools capability');
  notify('notifications/initialized');

  // 2. tools/list
  const list = await request('tools/list');
  const tools = list.result?.tools ?? [];
  const names = tools.map((t) => t.name).sort();
  check(
    JSON.stringify(names) === JSON.stringify(EXPECTED_TOOLS),
    `tools/list exposes exactly the contract tool names (got ${JSON.stringify(names)})`,
  );
  for (const tool of tools) {
    check(tool.inputSchema?.type === 'object', `${tool.name}: inputSchema is object-rooted`);
    check(typeof tool.description === 'string' && tool.description.length > 20, `${tool.name}: has a useful description`);
  }

  // 3. ping
  const pong = await request('ping');
  check(pong.result !== undefined, 'ping answers');

  // 4. tools/call — doctor must return a structured envelope even with no permissions.
  const doctor = await request('tools/call', { name: 'doctor', arguments: {} });
  const doctorText = doctor.result?.content?.find((b) => b.type === 'text')?.text ?? '';
  let doctorEnvelope = null;
  try { doctorEnvelope = JSON.parse(doctorText); } catch { /* handled below */ }
  check(doctorEnvelope !== null, 'doctor returns parseable JSON in a text block');
  check(
    doctorEnvelope?.ok === true || doctorEnvelope?.ok === false,
    'doctor envelope carries an explicit ok flag',
  );
  if (doctorEnvelope?.ok === true) {
    check(typeof doctorEnvelope.macos === 'string', 'doctor reports the macOS version');
    check(typeof doctorEnvelope.permissions?.accessibility === 'boolean', 'doctor reports accessibility permission');
  } else {
    // A clean structured error is acceptable; a crash is not.
    check(typeof doctorEnvelope?.error?.code === 'string', 'doctor failure is a structured error, not a crash');
  }

  // 5. tools/call with a bad tool name -> protocol-level invalid params
  const badTool = await request('tools/call', { name: 'not_a_real_tool', arguments: {} });
  check(badTool.error?.code === -32602, 'unknown tool returns -32602');

  // 6. unknown method -> -32601
  const badMethod = await request('nonsense/method');
  check(badMethod.error?.code === -32601, 'unknown method returns -32601');

  // 7. malformed JSON must not kill the loop
  raw('{ this is not json');
  raw('{"jsonrpc":"2.0","id":999,"method":"ping"}');
  const afterGarbage = await request('ping');
  check(afterGarbage.result !== undefined, 'server still answers after a malformed line');

  // 8. no stray output on stdout
  check(protocolErrors.length === 0, `stdout carried only JSON-RPC frames (${protocolErrors.join('; ')})`);

  child.kill();
}

main()
  .catch((error) => {
    failures.push(`harness error: ${error.message}`);
  })
  .finally(() => {
    console.log(`\n${passed} checks passed, ${failures.length} failed`);
    if (failures.length) {
      console.log('failures:');
      for (const f of failures) console.log(`  - ${f}`);
      if (stderrText.trim()) console.log(`server stderr:\n${stderrText.trim()}`);
      process.exit(1);
    }
    process.exit(0);
  });
