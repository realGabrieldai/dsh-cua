#!/usr/bin/env node
// dsh-cua MCP stdio server.
//
// Exposes the dsh-cua CLI (CONTRACT.md §1) as MCP tools with the same names Codex's
// built-in CUA uses, so any MCP client — DSH, Claude Code, anything else — gets the
// same surface without needing Codex installed.
//
// Stdlib only. No dependencies. One JSON object per line on stdout; logs go to stderr.

import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const SERVER_NAME = 'dsh-cua';
const SERVER_VERSION = '1.0.0';
const PROTOCOL_VERSION = '2024-11-05';
const DEFAULT_TIMEOUT_MS = 30000;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..');

function log(...args) {
  process.stderr.write(`[dsh-cua-mcp] ${args.join(' ')}\n`);
}

/** Resolve the CLI binary: explicit override, then the release build next to this repo. */
function resolveBinary() {
  if (process.env.DSH_CUA_BIN) return process.env.DSH_CUA_BIN;
  const local = path.join(REPO_ROOT, '.build', 'release', 'dsh-cua');
  if (existsSync(local)) return local;
  const debug = path.join(REPO_ROOT, '.build', 'debug', 'dsh-cua');
  if (existsSync(debug)) return debug;
  return 'dsh-cua'; // fall back to PATH
}

/** Runs the CLI and returns { code, stdout, stderr }. Never rejects on a non-zero exit. */
function runCli(args, timeoutMs = DEFAULT_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    execFile(
      resolveBinary(),
      args,
      { timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024, encoding: 'utf8' },
      (error, stdout, stderr) => {
        if (error && error.code === 'ENOENT') {
          reject(new Error(`dsh-cua binary not found (looked for '${resolveBinary()}'); build it or set DSH_CUA_BIN`));
          return;
        }
        if (error && error.killed) {
          reject(new Error(`dsh-cua timed out after ${timeoutMs}ms`));
          return;
        }
        resolve({ code: error?.code ?? 0, stdout: stdout ?? '', stderr: stderr ?? '' });
      },
    );
  });
}

const APP = {
  type: 'string',
  description: 'Target app: bundle id (com.apple.Safari), pid:501, or app name (Safari).',
};

const TOOLS = [
  {
    name: 'doctor',
    description:
      'Report macOS version, the binary path, and whether Accessibility and Screen Recording are granted. '
      + 'Call this first: it never fails hard, and it tells you which permissions are missing.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    build: () => ['doctor', '--json'],
  },
  {
    name: 'list_apps',
    description:
      'List running applications, frontmost first, with pid and window count. '
      + 'Use this to discover the target for every other tool. Never activates anything.',
    inputSchema: {
      type: 'object',
      properties: {
        all: { type: 'boolean', description: 'Include background/UI-less agents.' },
      },
      additionalProperties: false,
    },
    build: (a) => ['list-apps', '--json', ...(a.all ? ['--all'] : [])],
  },
  {
    name: 'list_windows',
    description:
      'List on-screen windows (CGWindowID, bounds, title) optionally filtered to one app. '
      + 'Window titles require Screen Recording permission; the rest does not.',
    inputSchema: {
      type: 'object',
      properties: { app: APP },
      additionalProperties: false,
    },
    build: (a) => ['list-windows', '--json', ...(a.app ? ['--app', a.app] : [])],
  },
  {
    name: 'get_app_state',
    description:
      'Dump the accessibility tree of an app (roles, titles, values, frames, actions, stable element refs) '
      + 'and optionally screenshot ONE window. Prefer this over screenshots: it is cheaper and exact. '
      + 'Element refs (e1, e2, ...) are valid until the next get_app_state for the same app. '
      + 'Without `screenshot` this makes no screen capture at all.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        screenshot: { type: 'string', description: 'Absolute path to write a PNG of the app window.' },
        window: { type: 'number', description: 'CGWindowID to capture instead of the focused window.' },
        max_depth: { type: 'number', description: 'Accessibility tree depth limit (default 12).' },
        max_nodes: { type: 'number', description: 'Accessibility tree node limit (default 1500).' },
      },
      required: ['app'],
      additionalProperties: false,
    },
    build: (a) => [
      'get-app-state', '--json', '--app', String(a.app),
      ...(a.screenshot ? ['--screenshot', String(a.screenshot)] : []),
      ...(a.window != null ? ['--window', String(a.window)] : []),
      ...(a.max_depth != null ? ['--max-depth', String(a.max_depth)] : []),
      ...(a.max_nodes != null ? ['--max-nodes', String(a.max_nodes)] : []),
    ],
  },
  {
    name: 'click',
    description:
      'Click in an app. Pass `element` (a ref from get_app_state) when you can — it resolves the element '
      + 'again and presses it through the accessibility API, which cannot miss. Coordinates are global '
      + 'display points and are hit-tested back to an element first. The user\'s cursor never moves.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        element: { type: 'string', description: 'Element ref from the last get_app_state.' },
        x: { type: 'number', description: 'Global x (top-left origin).' },
        y: { type: 'number', description: 'Global y (top-left origin).' },
        button: { type: 'string', enum: ['left', 'right', 'middle'] },
        count: { type: 'number', description: 'Click count (default 1).' },
      },
      required: ['app'],
      additionalProperties: false,
    },
    build: (a) => {
      if (!a.element && (a.x == null || a.y == null)) {
        throw new Error('click needs either `element` or both `x` and `y`');
      }
      return [
        'click', '--json', '--app', String(a.app),
        ...(a.element ? ['--element', String(a.element)] : []),
        ...(a.x != null ? ['--x', String(a.x)] : []),
        ...(a.y != null ? ['--y', String(a.y)] : []),
        ...(a.button ? ['--button', String(a.button)] : []),
        ...(a.count != null ? ['--count', String(a.count)] : []),
      ];
    },
  },
  {
    name: 'type_text',
    description:
      'Type text into an app. With `element` and a settable value the text is written straight into the '
      + 'field through the accessibility API (no focus change, no keystrokes). Otherwise unicode key '
      + 'events are posted to the app process. Secure text fields are refused.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        text: { type: 'string' },
        element: { type: 'string', description: 'Element ref; preferred.' },
        submit: { type: 'boolean', description: 'Press Return afterwards.' },
      },
      required: ['app', 'text'],
      additionalProperties: false,
    },
    build: (a) => [
      'type-text', '--json', '--app', String(a.app), '--text', String(a.text),
      ...(a.element ? ['--element', String(a.element)] : []),
      ...(a.submit ? ['--submit'] : []),
    ],
  },
  {
    name: 'press_key',
    description: 'Press one key, optionally with modifiers, delivered to the app process.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        key: {
          type: 'string',
          description: 'return, enter, tab, space, escape, delete, up/down/left/right, home, end, pageup, pagedown, f1..f20, or a single character.',
        },
        modifiers: {
          type: 'array',
          items: { type: 'string', enum: ['cmd', 'shift', 'opt', 'ctrl'] },
        },
      },
      required: ['app', 'key'],
      additionalProperties: false,
    },
    build: (a) => [
      'press-key', '--json', '--app', String(a.app), '--key', String(a.key),
      ...(Array.isArray(a.modifiers) && a.modifiers.length ? ['--modifiers', a.modifiers.join(',')] : []),
    ],
  },
  {
    name: 'scroll',
    description: 'Post scroll wheel events to an app. Positive dy scrolls down.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        dx: { type: 'number' },
        dy: { type: 'number' },
        x: { type: 'number' },
        y: { type: 'number' },
      },
      required: ['app'],
      additionalProperties: false,
    },
    build: (a) => [
      'scroll', '--json', '--app', String(a.app),
      '--dx', String(a.dx ?? 0), '--dy', String(a.dy ?? 0),
      ...(a.x != null ? ['--x', String(a.x)] : []),
      ...(a.y != null ? ['--y', String(a.y)] : []),
    ],
  },
  {
    name: 'drag',
    description: 'Drag between two global display points in an app.',
    inputSchema: {
      type: 'object',
      properties: {
        app: APP,
        from: { type: 'string', description: '"x,y"' },
        to: { type: 'string', description: '"x,y"' },
        button: { type: 'string', enum: ['left', 'right', 'middle'] },
      },
      required: ['app', 'from', 'to'],
      additionalProperties: false,
    },
    build: (a) => [
      'drag', '--json', '--app', String(a.app),
      '--from', String(a.from), '--to', String(a.to),
      ...(a.button ? ['--button', String(a.button)] : []),
    ],
  },
];

const TOOLS_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]));

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendResult(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function sendError(id, code, message, data) {
  send({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });
}

/** Turns a CLI run into MCP content blocks. */
function toContent(toolName, args, run) {
  const text = (run.stdout || '').trim();
  let envelope = null;
  try {
    envelope = JSON.parse(text);
  } catch {
    envelope = null;
  }

  const blocks = [];

  if (envelope && envelope.ok === false) {
    const code = envelope.error?.code ?? 'UNKNOWN';
    const message = envelope.error?.message ?? 'unknown error';
    blocks.push({ type: 'text', text: `dsh-cua error [${code}]: ${message}\n${text}` });
    return { content: blocks, isError: true };
  }

  if (!envelope) {
    // Not JSON: surface stderr so the model can see what actually went wrong.
    const detail = (run.stderr || '').trim();
    blocks.push({
      type: 'text',
      text: `dsh-cua produced no JSON envelope (exit ${run.code}).\nstdout: ${text}\nstderr: ${detail}`,
    });
    return { content: blocks, isError: true };
  }

  // Screenshots: hand the model pixels as well as the tree.
  let payloadText = text;
  if (toolName === 'get_app_state' && typeof args.screenshot === 'string' && envelope.screenshot?.path) {
    try {
      const bytes = readFileSync(envelope.screenshot.path);
      blocks.push({ type: 'image', data: bytes.toString('base64'), mimeType: 'image/png' });
      // Keep the JSON small: the tree is already in the text block.
      payloadText = JSON.stringify({ ...envelope, tree: '[see image]' });
    } catch (error) {
      blocks.push({ type: 'text', text: `screenshot was written but could not be read back: ${error.message}` });
    }
  }

  blocks.push({ type: 'text', text: payloadText });
  return { content: blocks, isError: false };
}

async function handleToolCall(id, params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  const tool = TOOLS_BY_NAME.get(name);

  if (!tool) {
    sendError(id, -32602, `unknown tool '${name}'`, { available: [...TOOLS_BY_NAME.keys()] });
    return;
  }

  let argv;
  try {
    argv = tool.build(args);
  } catch (error) {
    // Bad arguments are a tool-level error, not a protocol error.
    sendResult(id, { content: [{ type: 'text', text: `invalid arguments: ${error.message}` }], isError: true });
    return;
  }

  const timeoutMs = Number(process.env.DSH_CUA_TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS);
  let run;
  try {
    run = await runCli(argv, timeoutMs);
  } catch (error) {
    sendResult(id, { content: [{ type: 'text', text: `dsh-cua failed to run: ${error.message}` }], isError: true });
    return;
  }

  sendResult(id, toContent(name, args, run));
}

async function handle(message) {
  const { id, method, params } = message;

  // Notifications (no id) must never be answered.
  if (id === undefined || id === null) {
    if (method === 'notifications/initialized') log('client initialized');
    return;
  }

  switch (method) {
    case 'initialize':
      sendResult(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      return;
    case 'ping':
      sendResult(id, {});
      return;
    case 'tools/list':
      sendResult(id, {
        tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
      });
      return;
    case 'tools/call':
      await handleToolCall(id, params);
      return;
    default:
      sendError(id, -32601, `method not found: ${method}`);
  }
}

function main() {
  let buffer = '';
  process.stdin.setEncoding('utf8');

  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        // A malformed line must not kill the loop.
        log(`dropping malformed JSON line: ${error.message}`);
        send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
        continue;
      }
      // handle() is async; never let a rejection escape and take down the process.
      handle(message).catch((error) => {
        log(`handler error: ${error?.stack ?? error}`);
        if (message?.id != null) {
          sendError(message.id, -32603, `internal error: ${error?.message ?? error}`);
        }
      });
    }
  });

  process.stdin.on('end', () => process.exit(0));
  log(`ready (binary: ${resolveBinary()})`);
}

main();
