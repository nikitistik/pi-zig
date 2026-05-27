import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const tinyPngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';

function run(args, input, options = {}) {
  return execFileSync(bin, args, { encoding: 'utf8', input, ...options });
}

function runFail(args, input, options = {}) {
  try {
    const stdout = execFileSync(bin, args, { encoding: 'utf8', input, ...options });
    throw new Error(`expected command to fail but it succeeded: ${args.join(' ')}\n${stdout}`);
  } catch (error) {
    if (error.status === undefined) throw error;
    return {
      status: error.status,
      stdout: error.stdout ?? '',
      stderr: error.stderr ?? ''
    };
  }
}

function jsonLines(text) {
  return text.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

async function runRpcSequential(args, commands, options = {}) {
  const child = spawn(bin, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ['pipe', 'pipe', 'pipe']
  });
  let stdout = '';
  let stderr = '';
  let pending = '';
  const lines = [];
  const waiters = [];
  function failWaiters(error) {
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
  }
  function resolveWaiters(line) {
    for (let index = 0; index < waiters.length;) {
      const waiter = waiters[index];
      if (waiter.predicate(line)) {
        waiters.splice(index, 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(line);
      } else {
        index += 1;
      }
    }
  }
  function waitForLine(predicate, timeoutMs = options.timeoutMs ?? 10000) {
    const existing = lines.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const error = new Error(`timed out waiting for sequential RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
        const index = waiters.findIndex((waiter) => waiter.reject === reject);
        if (index !== -1) waiters.splice(index, 1);
        reject(error);
      }, timeoutMs);
      waiters.push({ predicate, resolve, reject, timeout });
    });
  }
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    pending += chunk;
    while (pending.includes('\n')) {
      const newline = pending.indexOf('\n');
      const rawLine = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (rawLine.trim().length === 0) continue;
      try {
        const line = JSON.parse(rawLine);
        lines.push(line);
        resolveWaiters(line);
      } catch (error) {
        failWaiters(new Error(`failed to parse sequential RPC JSON line: ${rawLine}\n${error.message}`));
      }
    }
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  const exitPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`sequential RPC run timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, options.exitTimeoutMs ?? 30000);
    child.once('error', (error) => {
      clearTimeout(timeout);
      failWaiters(error);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0) {
        const error = new Error(`sequential RPC run exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
        failWaiters(error);
        reject(error);
        return;
      }
      resolve();
    });
  });
  try {
    for (const command of commands) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
      if (command.id) await waitForLine((line) => line.id === command.id);
    }
    child.stdin.end();
    await exitPromise;
  } catch (error) {
    child.kill('SIGKILL');
    throw error;
  }
  return { stdout, stderr, lines };
}

function envWithoutAnthropicAuth(extra = {}) {
  const cleanAgentDir = path.resolve('zig-out/pi-zig-clean-agent');
  fs.mkdirSync(cleanAgentDir, { recursive: true });
  const env = { ...process.env, PI_CODING_AGENT_DIR: cleanAgentDir, ...extra };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_OAUTH_TOKEN;
  delete env.PI_ZIG_PROVIDER_BASE_URL;
  return env;
}

async function startFakeProviderServer() {
  const child = spawn(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      `
import http from 'node:http';
import fs from 'node:fs';
const requestCounts = new Map();
const tinyPngBase64 = ${JSON.stringify(tinyPngBase64)};
function eventStreamU32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32BE(value);
  return buffer;
}
function eventStreamHeaderString(name, value) {
  const nameBuffer = Buffer.from(name);
  const valueBuffer = Buffer.from(value);
  return Buffer.concat([
    Buffer.from([nameBuffer.length]),
    nameBuffer,
    Buffer.from([7]),
    Buffer.from([valueBuffer.length >> 8, valueBuffer.length & 0xff]),
    valueBuffer
  ]);
}
function bedrockEventFrame(eventType, payload) {
  const headers = Buffer.concat([
    eventStreamHeaderString(':message-type', 'event'),
    eventStreamHeaderString(':event-type', eventType),
    eventStreamHeaderString(':content-type', 'application/json')
  ]);
  const body = Buffer.from(JSON.stringify(payload));
  const total = 12 + headers.length + body.length + 4;
  return Buffer.concat([
    eventStreamU32(total),
    eventStreamU32(headers.length),
    eventStreamU32(0),
    headers,
    body,
    eventStreamU32(0)
  ]);
}
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks).toString('utf8');
    if (req.method === 'POST' && req.url === '/v1/messages') {
      if (req.headers['x-api-key'] !== 'fake-provider-key') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing anthropic auth', headers: req.headers }));
        return;
      }
      const body = JSON.parse(rawBody);
      const contentText = (content) => Array.isArray(content)
        ? content.map((part) => part?.type === 'text' ? (part.text ?? '') : part?.type === 'tool_result' ? (part.content ?? '') : '').join('\\n')
        : String(content ?? '');
      const userText = body.messages?.filter((message) => message.role === 'user').map((message) => contentText(message.content)).join('\\n') ?? '';
      const toolResults = body.messages?.flatMap((message) => Array.isArray(message.content) ? message.content.filter((part) => part?.type === 'tool_result') : []) ?? [];
      const hasBashTool = body.tools?.some((tool) => tool?.name === 'bash' && tool?.input_schema?.type === 'object') ?? false;
      const writeAnthropicEvents = (events) => {
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'close'
        });
        for (const event of events) {
          res.write('event: ' + event.type + '\\n');
          res.write('data: ' + JSON.stringify(event) + '\\n\\n');
        }
        res.end();
      };
      if (userText.includes('native anthropic stream tool events')) {
        if (body.stream !== true || !Array.isArray(body.system) || !hasBashTool) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native anthropic request shape mismatch', body }));
          return;
        }
        if (toolResults.length === 0) {
          writeAnthropicEvents([
            { type: 'message_start', message: { id: 'msg_native_anthropic_stream_1' } },
            { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'call_native_anthropic_stream_1', name: 'bash', input: {} } },
            { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"command":"printf ' } },
            { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: 'native-anthropic-ok"}' } },
            { type: 'content_block_stop', index: 0 },
            { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 1 } },
            { type: 'message_stop' }
          ]);
          return;
        }
        if (toolResults.at(-1)?.tool_use_id !== 'call_native_anthropic_stream_1' || String(toolResults.at(-1)?.content ?? '').trim() !== 'native-anthropic-ok') {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Anthropic tool result mismatch', toolResults }));
          return;
        }
        writeAnthropicEvents([
          { type: 'message_start', message: { id: 'msg_native_anthropic_stream_2' } },
          { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
          { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'native anthropic ' } },
          { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'tool complete: native-anthropic-ok' } },
          { type: 'content_block_stop', index: 0 },
          { type: 'message_stop' }
        ]);
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unknown native anthropic request', body }));
      return;
    }
    const requestUrl = new URL(req.url, 'http://127.0.0.1');
    const isGoogleVertexGenerateContent = req.method === 'POST' &&
      requestUrl.pathname.includes('/publishers/google/models/') &&
      (requestUrl.pathname.endsWith(':streamGenerateContent') || requestUrl.pathname.endsWith(':generateContent'));
    if (isGoogleVertexGenerateContent) {
      if (req.headers['x-goog-api-key'] !== 'fake-vertex-key') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing vertex auth', headers: req.headers }));
        return;
      }
      const body = JSON.parse(rawBody);
      const googlePartText = (part) => part?.text ?? part?.functionResponse?.response?.output ?? part?.functionResponse?.response?.error ?? '';
      const googleContentText = (content) => Array.isArray(content?.parts)
        ? content.parts.map(googlePartText).join('\\n')
        : '';
      const userText = body.contents?.filter((content) => content.role === 'user').map(googleContentText).join('\\n') ?? '';
      const functionResponses = body.contents?.flatMap((content) => Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionResponse) : []) ?? [];
      const hasBashTool = body.tools?.some((tool) => tool?.functionDeclarations?.some((decl) => decl?.name === 'bash' && decl?.parametersJsonSchema?.type === 'object')) ?? false;
      const writeVertexEvents = (events) => {
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'close'
        });
        for (const event of events) {
          res.write('data: ' + JSON.stringify(event) + '\\n\\n');
        }
        res.end();
      };
      if (userText.includes('native vertex stream tool events')) {
        if (
          !requestUrl.pathname.endsWith(':streamGenerateContent') ||
          !decodeURIComponent(requestUrl.pathname).includes('/v1/publishers/google/models/gemini-3-flash-preview:streamGenerateContent') ||
          !body.systemInstruction?.parts?.some((part) => part.text) ||
          !hasBashTool
        ) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native vertex request shape mismatch', body, pathname: requestUrl.pathname }));
          return;
        }
        if (functionResponses.length === 0) {
          writeVertexEvents([
            { candidates: [{ content: { parts: [{ text: 'vertex private thought', thought: true }, { functionCall: { id: 'call_native_vertex_stream_1', name: 'bash', args: { command: 'printf native-vertex-ok' } }, thoughtSignature: 'dmVydGV4LXNpZw==' }] }, finishReason: 'STOP' }] }
          ]);
          return;
        }
        const assistantFunctionCalls = body.contents?.flatMap((content) => Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionCall) : []) ?? [];
        if (!assistantFunctionCalls.some((part) => part.functionCall?.name === 'bash' && part.thoughtSignature === 'dmVydGV4LXNpZw==')) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Vertex thought signature was not replayed', contents: body.contents }));
          return;
        }
        const lastResponse = functionResponses.at(-1)?.functionResponse;
        if (lastResponse?.name !== 'bash' || String(lastResponse?.response?.output ?? '').trim() !== 'native-vertex-ok') {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Vertex tool result mismatch', functionResponses }));
          return;
        }
        writeVertexEvents([
          { candidates: [{ content: { parts: [{ text: 'native vertex ' }] } }] },
          { candidates: [{ content: { parts: [{ text: 'tool complete: native-vertex-ok' }] }, finishReason: 'STOP' }] }
        ]);
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unknown native vertex request', body, pathname: requestUrl.pathname }));
      return;
    }
    const isGoogleGenerateContent = req.method === 'POST' &&
      requestUrl.pathname.includes('/models/') &&
      (requestUrl.pathname.endsWith(':streamGenerateContent') || requestUrl.pathname.endsWith(':generateContent'));
    if (isGoogleGenerateContent) {
      if (req.headers['x-goog-api-key'] !== 'fake-google-key') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing google auth', headers: req.headers }));
        return;
      }
      const body = JSON.parse(rawBody);
      const googlePartText = (part) => part?.text ?? part?.functionResponse?.response?.output ?? part?.functionResponse?.response?.error ?? '';
      const googleContentText = (content) => Array.isArray(content?.parts)
        ? content.parts.map(googlePartText).join('\\n')
        : '';
      const userText = body.contents?.filter((content) => content.role === 'user').map(googleContentText).join('\\n') ?? '';
      const functionResponses = body.contents?.flatMap((content) => Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionResponse) : []) ?? [];
      const hasBashTool = body.tools?.some((tool) => tool?.functionDeclarations?.some((decl) => decl?.name === 'bash' && decl?.parametersJsonSchema?.type === 'object')) ?? false;
      const writeGoogleEvents = (events) => {
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'close'
        });
        for (const event of events) {
          res.write('data: ' + JSON.stringify(event) + '\\n\\n');
        }
        res.end();
      };
      if (userText.includes('native google stream tool events')) {
        if (!requestUrl.pathname.endsWith(':streamGenerateContent') || !body.systemInstruction?.parts?.some((part) => part.text) || !hasBashTool) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native google request shape mismatch', body, pathname: requestUrl.pathname }));
          return;
        }
        if (functionResponses.length === 0) {
          writeGoogleEvents([
            { candidates: [{ content: { parts: [{ text: 'google private thought', thought: true }, { functionCall: { id: 'call_native_google_stream_1', name: 'bash', args: { command: 'printf native-google-ok' } }, thoughtSignature: 'Z29vZ2xlLXNpZw==' }] }, finishReason: 'STOP' }] }
          ]);
          return;
        }
        const assistantFunctionCalls = body.contents?.flatMap((content) => Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionCall) : []) ?? [];
        if (!assistantFunctionCalls.some((part) => part.functionCall?.name === 'bash' && part.thoughtSignature === 'Z29vZ2xlLXNpZw==')) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Google thought signature was not replayed', contents: body.contents }));
          return;
        }
        const lastResponse = functionResponses.at(-1)?.functionResponse;
        if (lastResponse?.name !== 'bash' || String(lastResponse?.response?.output ?? '').trim() !== 'native-google-ok') {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Google tool result mismatch', functionResponses }));
          return;
        }
        writeGoogleEvents([
          { candidates: [{ content: { parts: [{ text: 'native google ' }] } }] },
          { candidates: [{ content: { parts: [{ text: 'tool complete: native-google-ok' }] }, finishReason: 'STOP' }] }
        ]);
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unknown native google request', body }));
      return;
    }
    const isBedrockConverseStream = req.method === 'POST' &&
      requestUrl.pathname.includes('/model/') &&
      requestUrl.pathname.endsWith('/converse-stream');
    if (isBedrockConverseStream) {
      if (req.headers.authorization !== 'Bearer fake-bedrock-token') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bedrock auth', headers: req.headers }));
        return;
      }
      const body = JSON.parse(rawBody);
      const decodedPath = decodeURIComponent(requestUrl.pathname);
      const bedrockBlockText = (block) => {
        if (block?.text) return block.text;
        if (block?.toolResult?.content) return block.toolResult.content.map((item) => item?.text ?? '').join('\\n');
        return '';
      };
      const bedrockMessageText = (message) => Array.isArray(message?.content)
        ? message.content.map(bedrockBlockText).join('\\n')
        : '';
      const userText = body.messages?.filter((message) => message.role === 'user').map(bedrockMessageText).join('\\n') ?? '';
      const toolResults = body.messages?.flatMap((message) => Array.isArray(message.content) ? message.content.filter((block) => block?.toolResult) : []) ?? [];
      const hasBashTool = body.toolConfig?.tools?.some((tool) => tool?.toolSpec?.name === 'bash' && tool?.toolSpec?.inputSchema?.json?.type === 'object') ?? false;
      const writeBedrockEvents = (events) => {
        res.writeHead(200, {
          'content-type': 'application/vnd.amazon.eventstream',
          connection: 'close'
        });
        for (const [eventType, payload] of events) {
          res.write(bedrockEventFrame(eventType, payload));
        }
        res.end();
      };
      if (userText.includes('native bedrock stream tool events')) {
        if (!decodedPath.includes('/model/anthropic.claude-test-v1:0/converse-stream') || !Array.isArray(body.system) || !hasBashTool || body.modelId) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native bedrock request shape mismatch', body, pathname: requestUrl.pathname }));
          return;
        }
        if (toolResults.length === 0) {
          writeBedrockEvents([
            ['messageStart', { messageStart: { role: 'assistant' } }],
            ['contentBlockStart', { contentBlockStart: { contentBlockIndex: 0, start: { toolUse: { toolUseId: 'callbedrock1', name: 'bash' } } } }],
            ['contentBlockDelta', { contentBlockDelta: { contentBlockIndex: 0, delta: { toolUse: { input: '{"command":"printf ' } } } }],
            ['contentBlockDelta', { contentBlockDelta: { contentBlockIndex: 0, delta: { toolUse: { input: 'native-bedrock-ok"}' } } } }],
            ['contentBlockStop', { contentBlockStop: { contentBlockIndex: 0 } }],
            ['messageStop', { messageStop: { stopReason: 'tool_use' } }]
          ]);
          return;
        }
        const lastTool = toolResults.at(-1)?.toolResult;
        const toolText = lastTool?.content?.map((item) => item?.text ?? '').join('\\n') ?? '';
        if (lastTool?.toolUseId !== 'callbedrock1' || toolText.trim() !== 'native-bedrock-ok') {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'native Bedrock tool result mismatch', toolResults }));
          return;
        }
        writeBedrockEvents([
          ['messageStart', { messageStart: { role: 'assistant' } }],
          ['contentBlockDelta', { contentBlockDelta: { contentBlockIndex: 0, delta: { text: 'native bedrock ' } } }],
          ['contentBlockDelta', { contentBlockDelta: { contentBlockIndex: 0, delta: { text: 'tool complete: native-bedrock-ok' } } }],
          ['contentBlockStop', { contentBlockStop: { contentBlockIndex: 0 } }],
          ['messageStop', { messageStop: { stopReason: 'end_turn' } }]
        ]);
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unknown native bedrock request', body, pathname: requestUrl.pathname }));
      return;
    }
    if (req.method !== 'POST' || req.url !== '/v1/chat/completions') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'not found' }));
      return;
    }
    if (req.headers.authorization !== 'Bearer fake-provider-key') {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'missing auth' }));
      return;
    }
    const body = JSON.parse(rawBody);
    const contentText = (content) => Array.isArray(content)
      ? content.filter((part) => part?.type === 'text').map((part) => part.text ?? '').join('\\n')
      : String(content ?? '');
    const lastUserMessage = [...body.messages].reverse().find((message) => message.role === 'user');
    const user = contentText(lastUserMessage?.content);
    const userMessages = body.messages.filter((message) => message.role === 'user').map((message) => contentText(message.content));
    const userMessageIncluding = (text) => body.messages.find((message) => message.role === 'user' && contentText(message.content).includes(text));
    const hasSmokeImage = (content) =>
      Array.isArray(content) &&
      content.some((part) => part?.type === 'image_url' && part.image_url?.url === 'data:image/png;base64,aW1hZ2Utc21va2U=');
    const hasReadToolImage = (content) =>
      Array.isArray(content) &&
      content.some((part) => part?.type === 'image_url' && part.image_url?.url === 'data:image/png;base64,' + tinyPngBase64);
    const system = body.messages.find((message) => message.role === 'system')?.content ?? '';
    const toolMessages = body.messages.filter((message) => message.role === 'tool');
    const hasTool = (name) => body.tools?.some((tool) => tool?.function?.name === name) ?? false;
    const hasBashTool = hasTool('bash');
    const extensionBashOverrideDefinitionError = () => {
      const bashTools = body.tools?.filter((tool) => tool?.function?.name === 'bash') ?? [];
      const bashTool = bashTools[0]?.function;
      if (
        bashTools.length !== 1 ||
        !bashTool?.description?.includes('Extension override') ||
        bashTool?.parameters?.properties?.value?.type !== 'string' ||
        bashTool?.parameters?.properties?.command ||
        !bashTool?.parameters?.required?.includes('value')
      ) {
        return { error: 'extension bash override definition mismatch', tools: body.tools };
      }
      return null;
    };
    const writeStreamEvents = (events) => {
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'close'
      });
      for (const event of events) {
        res.write('data: ' + JSON.stringify(event) + '\\n\\n');
      }
      res.end('data: [DONE]\\n\\n');
    };
    if (user.includes('json provider client error')) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'json provider client error fixture' }));
      return;
    }
    if (user.includes('json retry disabled')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count === 1) {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'temporary json provider failure with retry disabled' }));
        return;
      }
      const content = 'json retry disabled unexpectedly recovered';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('json retry exhausted')) {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'temporary json provider failure' }));
      return;
    }
    if (user.includes('native mistral stream tool events')) {
      if (
        body.stream !== true ||
        body.model !== 'devstral-medium-latest' ||
        !hasBashTool ||
        !body.tools?.some((tool) => tool?.function?.strict === false && tool?.function?.parameters?.type === 'object')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'native mistral request shape mismatch', body }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { toolCalls: [{ index: 0, id: 'callmistr1', type: 'function', function: { name: 'bash', arguments: '{"command":"printf ' } }] } }] },
          { choices: [{ delta: { toolCalls: [{ index: 0, function: { arguments: 'native-mistral-ok"}' } }] }, finishReason: 'tool_calls' }] }
        ]);
        return;
      }
      const lastTool = toolMessages.at(-1);
      const toolText = Array.isArray(lastTool?.content)
        ? lastTool.content.map((part) => part?.text ?? '').join('\\n')
        : String(lastTool?.content ?? '');
      if (lastTool?.tool_call_id !== 'callmistr1' || lastTool?.name !== 'bash' || toolText.trim() !== 'native-mistral-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'native Mistral tool result mismatch', lastTool }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: [{ type: 'text', text: 'native mistral ' }] } }] },
        { choices: [{ delta: { content: [{ type: 'text', text: 'tool complete: native-mistral-ok' }] }, finishReason: 'stop' }] }
      ]);
      return;
    }
    if (user.includes('streaming provider json')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected streaming request' }));
        return;
      }
      if ((body.tools?.length ?? 0) !== 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'streaming text smoke expected no tools' }));
        return;
      }
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'close'
      });
      res.write('data: {"choices":[{"delta":{"content":"stream "}}]}\\n\\n');
      res.write('data: {"choices":[{"delta":{"content":"delta"}}]}\\n\\n');
      res.end('data: [DONE]\\n\\n');
      return;
    }
    if (user.includes('image input json')) {
      const content = lastUserMessage?.content;
      const hasText = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text?.includes('image input json'));
      const hasImage = Array.isArray(content) && content.some((part) => part?.type === 'image_url' && part.image_url?.url === 'data:image/png;base64,aW1hZ2Utc21va2U=');
      if (!hasText || !hasImage || body.stream !== true || (body.tools?.length ?? 0) !== 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing streamed image content part', content, stream: body.stream, tools: body.tools }));
        return;
      }
      writeStreamEvents([{ choices: [{ delta: { content: 'image json observed' } }] }]);
      return;
    }
    if (user.includes('image input agent') && !user.includes('non vision image input agent')) {
      const content = lastUserMessage?.content;
      const hasText = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text?.includes('image input agent'));
      const hasImage = Array.isArray(content) && content.some((part) => part?.type === 'image_url' && part.image_url?.url === 'data:image/png;base64,aW1hZ2Utc21va2U=');
      if (!hasText || !hasImage || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing agent image content part', content, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'image agent observed' } }] }));
      return;
    }
    if (user.includes('non vision image input agent')) {
      const content = lastUserMessage?.content;
      const hasText = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text?.includes('non vision image input agent'));
      const hasPlaceholder = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text === '(image omitted: model does not support images)');
      const hasImage = Array.isArray(content) && content.some((part) => part?.type === 'image_url');
      if (!hasText || !hasPlaceholder || hasImage || body.model !== 'gpt-4' || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'non-vision agent image input was not downgraded', content, model: body.model, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'non vision image agent observed' } }] }));
      return;
    }
    if (userMessages.some((message) => message.includes('non vision read image result'))) {
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_nonvision_read_image_1',
                type: 'function',
                function: {
                  name: 'read',
                  arguments: JSON.stringify({ path: 'zig-out/pi-zig-provider-image-fixture/input.png' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const readToolMessage = toolMessages.find((message) => message.tool_call_id === 'call_nonvision_read_image_1');
      const readToolText = String(readToolMessage?.content ?? '');
      const serializedMessages = JSON.stringify(body.messages);
      if (
        body.model !== 'gpt-4' ||
        !readToolText.includes('Read image file [image/png]') ||
        !readToolText.includes('[Current model does not support images. The image will be omitted from this request.]') ||
        !readToolText.includes('(tool image omitted: model does not support images)') ||
        serializedMessages.includes('data:image/png;base64') ||
        serializedMessages.includes('Attached image(s) from tool result')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'non-vision read image result was not downgraded', messages: body.messages, model: body.model }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'non vision read image result complete' } }] }));
      return;
    }
    if (user.includes('image input rpc')) {
      const content = lastUserMessage?.content;
      const hasText = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text?.includes('image input rpc'));
      const hasImage = Array.isArray(content) && content.some((part) => part?.type === 'image_url' && part.image_url?.url === 'data:image/png;base64,aW1hZ2Utc21va2U=');
      if (!hasText || !hasImage || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing rpc image content part', content, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'image rpc observed' } }] }));
      return;
    }
    if (user.includes('rpc command image user')) {
      const content = lastUserMessage?.content;
      const hasText = Array.isArray(content) && content.some((part) => part?.type === 'text' && part.text?.includes('rpc command image user'));
      if (!hasText || !hasSmokeImage(content) || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing extension command image content part', content, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc command image user observed' } }] }));
      return;
    }
    if (user.includes('rpc image history replay')) {
      const priorContent = userMessageIncluding('image input rpc')?.content;
      if (!hasSmokeImage(priorContent) || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing persisted rpc image history content part', priorContent, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc image history observed' } }] }));
      return;
    }
    if (
      user.includes('rpc slash prompt template expansion') &&
      !userMessages.includes('rpc active slash resource steer start') &&
      !userMessages.includes('rpc active slash resource follow start')
    ) {
      const expected = 'rpc slash prompt template expansion: first=alpha rest=beta gamma delta all=alpha "beta gamma" delta';
      if (user !== expected) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'slash prompt template expansion mismatch', user, expected }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc slash prompt template expansion observed' } }] }));
      return;
    }
    if (user.includes('rpc slash skill expansion body')) {
      const expected = [
        '<skill name="resource-skill" location=".pi/skills/resource-skill/SKILL.md">',
        'References are relative to .pi/skills/resource-skill.',
        '',
        'rpc slash skill expansion body',
        '</skill>',
        '',
        'Focus on loaded instructions'
      ].join('\\n');
      if (user !== expected) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'slash skill expansion mismatch', user, expected }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc slash skill expansion observed' } }] }));
      return;
    }
    if (user.includes('rpc slash resource follow start')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc slash resource follow base complete' } }] }));
      return;
    }
    if (user.includes('expect no tools')) {
      if ((body.tools?.length ?? 0) !== 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected no tool definitions' }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'no tools observed' } }] }));
      return;
    }
    if (user.includes('expect bash tool')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'bash tool observed' } }] }));
      return;
    }
    if (user.includes('expect selected tools')) {
      if (!hasTool('read') || !hasTool('grep') || hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'selected tool definitions did not match read,grep' }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'selected tools observed' } }] }));
      return;
    }
    if (user.includes('responses stream tool events')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected streaming request' }));
        return;
      }
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { type: 'response.output_item.added', item: { type: 'function_call', id: 'item_responses_stream_1', call_id: 'call_responses_stream_1', name: 'bash', arguments: '{"command":"printf ' } },
          { type: 'response.function_call_arguments.delta', delta: 'responses-tool-ok"}' },
          { type: 'response.function_call_arguments.done', arguments: '{"command":"printf responses-tool-ok"}' },
          { type: 'response.output_item.done', item: { type: 'function_call', id: 'item_responses_stream_1', call_id: 'call_responses_stream_1', name: 'bash', arguments: '{"command":"printf responses-tool-ok"}' } }
        ]);
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_responses_stream_1|item_responses_stream_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'Responses tool result did not preserve compound tool_call_id', toolMessages }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolOutput !== 'responses-tool-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected Responses tool output', toolOutput }));
        return;
      }
      writeStreamEvents([
        { type: 'response.output_text.delta', delta: 'responses stream ' },
        { type: 'response.output_text.delta', delta: 'tool complete: ' + toolOutput }
      ]);
      return;
    }
    if (user.includes('anthropic stream tool events')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected streaming request' }));
        return;
      }
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { type: 'message_start', message: { id: 'msg_anthropic_stream_1', usage: { input_tokens: 1, output_tokens: 0 } } },
          { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'call_anthropic_stream_1', name: 'bash', input: {} } },
          { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"command":"printf ' } },
          { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: 'anthropic-tool-ok"}' } },
          { type: 'content_block_stop', index: 0 },
          { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 1 } },
          { type: 'message_stop' }
        ]);
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_anthropic_stream_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'Anthropic tool result did not preserve tool_call_id', toolMessages }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolOutput !== 'anthropic-tool-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected Anthropic tool output', toolOutput }));
        return;
      }
      writeStreamEvents([
        { type: 'message_start', message: { id: 'msg_anthropic_stream_2', usage: { input_tokens: 1, output_tokens: 0 } } },
        { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'anthropic stream ' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'tool complete: ' + toolOutput } },
        { type: 'content_block_stop', index: 0 },
        { type: 'message_stop' }
      ]);
      return;
    }
    if (user.includes('google stream tool events')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected streaming request' }));
        return;
      }
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          {
            candidates: [{
              content: {
                parts: [{ functionCall: { id: 'call_google_stream_1', name: 'bash', args: { command: 'printf google-tool-ok' } } }]
              },
              finishReason: 'STOP'
            }]
          }
        ]);
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_google_stream_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'Google tool result did not preserve tool_call_id', toolMessages }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolOutput !== 'google-tool-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected Google tool output', toolOutput }));
        return;
      }
      writeStreamEvents([
        { candidates: [{ content: { parts: [{ text: 'google stream ' }] } }] },
        { candidates: [{ content: { parts: [{ text: 'tool complete: ' + toolOutput }] }, finishReason: 'STOP' }] }
      ]);
      return;
    }
    if (user.includes('streaming tool loop')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected streaming tool request' }));
        return;
      }
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_stream_tool_1', type: 'function', function: { name: 'bash', arguments: '{"command":"printf ' } }] } }] },
          { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'stream-tool-ok"}' } }] } }] }
        ]);
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_stream_tool_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'streaming tool result did not preserve tool_call_id' }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolOutput !== 'stream-tool-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected streaming tool output', toolOutput }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'streaming tool ' } }] },
        { choices: [{ delta: { content: 'loop complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension hook events') && !user.includes('rpc extension hook events')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension hook stream request' }));
        return;
      }
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_hook_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command: 'printf extension-original' }) } }] } }] }
        ]);
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_hook_1' || toolOutput !== 'extension-result-patched') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension hook did not rewrite arguments and patch result', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension hook ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('rpc extension hook events')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_hook_1',
                type: 'function',
                function: {
                  name: 'bash',
                  arguments: JSON.stringify({ command: 'printf extension-original' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_hook_1' || toolOutput !== 'extension-result-patched') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension hook did not rewrite arguments and patch result', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension hook complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension no builtin registered tool')) {
      const unexpectedBuiltins = ['bash', 'read', 'grep', 'ls', 'find', 'write', 'edit'].filter((name) => hasTool(name));
      if (!hasTool('ext_echo') || unexpectedBuiltins.length > 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc no-builtin extension tool definition mismatch', unexpectedBuiltins, tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_no_builtin_tool_1',
                type: 'function',
                function: {
                  name: 'ext_echo',
                  arguments: JSON.stringify({ value: 'rpc-no-builtin-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_no_builtin_tool_1' || toolOutput !== 'ext-echo: rpc-no-builtin-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc no-builtin extension registered tool did not execute', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension no builtin tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension allowlist registered tool')) {
      const unexpectedBuiltins = ['bash', 'read', 'grep', 'ls', 'find', 'write', 'edit'].filter((name) => hasTool(name));
      if (!hasTool('ext_echo') || unexpectedBuiltins.length > 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc allowlisted extension tool definition mismatch', unexpectedBuiltins, tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_allowlist_tool_1',
                type: 'function',
                function: {
                  name: 'ext_echo',
                  arguments: JSON.stringify({ value: 'rpc-allowlist-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_allowlist_tool_1' || toolOutput !== 'ext-echo: rpc-allowlist-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc allowlisted extension registered tool did not execute', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension allowlist tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension permission gate')) {
      if (!hasTool('bash')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool for rpc permission gate', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_permission_gate_1',
                type: 'function',
                function: {
                  name: 'bash',
                  arguments: JSON.stringify({ command: 'printf should-not-run' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = String(toolMessages.at(-1)?.content ?? '').trim();
      if (
        toolMessages.at(-1)?.tool_call_id !== 'call_rpc_extension_permission_gate_1' ||
        !toolOutput.includes('blocked by headless permission gate') ||
        toolOutput.includes('should-not-run')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension permission gate did not block bash before execution', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension permission gate complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension registered tool')) {
      if (!hasTool('ext_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing rpc extension tool definition', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_tool_1',
                type: 'function',
                function: {
                  name: 'ext_echo',
                  arguments: JSON.stringify({ value: 'rpc-registered-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_tool_1' || toolOutput !== 'ext-echo: rpc-registered-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension registered tool did not execute', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension flag registered tool')) {
      if (!hasTool('ext_flag_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing rpc extension flag tool definition', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_flag_tool_1',
                type: 'function',
                function: {
                  name: 'ext_flag_echo',
                  arguments: '{}'
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_flag_tool_1' || toolOutput !== 'ext-flag: plan=review;debug=true;missing=undefined') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension flag registered tool did not receive CLI flags', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension flag tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc extension bash override tool')) {
      const definitionError = extensionBashOverrideDefinitionError();
      if (definitionError) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify(definitionError));
        return;
      }
      if (body.stream === true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension bash override expected non-stream request' }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_bash_override_1',
                type: 'function',
                function: {
                  name: 'bash',
                  arguments: JSON.stringify({ value: 'rpc-override-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const lastTool = toolMessages.at(-1);
      const toolOutput = String(lastTool?.content ?? '').trim();
      if (lastTool?.tool_call_id !== 'call_rpc_extension_bash_override_1' || toolOutput !== 'ext-bash: rpc-override-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension bash override did not execute extension tool', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension bash override complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('rpc next-turn normal prompt')) {
      if (!userMessages.includes('rpc next-turn custom note')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing rpc nextTurn custom message in provider history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc next-turn custom observed' } }] }));
      return;
    }
    if (user.includes('rpc extension typescript tool')) {
      if (!hasTool('ext_ts_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing rpc extension TypeScript tool definition', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_rpc_extension_ts_tool_1',
                type: 'function',
                function: {
                  name: 'ext_ts_echo',
                  arguments: JSON.stringify({ value: 'rpc-ts-registered-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_rpc_extension_ts_tool_1' || toolOutput !== 'ext-ts-echo: rpc-ts-registered-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'rpc extension TypeScript tool did not execute', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc extension ts tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('extension registered tool') && !user.includes('rpc extension registered tool')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension registered tool stream request' }));
        return;
      }
      if (!hasTool('ext_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing extension tool definition', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_tool_1', type: 'function', function: { name: 'ext_echo', arguments: JSON.stringify({ value: 'registered-ok' }) } }] } }] }
        ]);
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_tool_1' || toolOutput !== 'ext-echo: registered-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension registered tool did not execute', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension tool ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension flag registered tool')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension flag registered tool stream request' }));
        return;
      }
      if (!hasTool('ext_flag_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing extension flag tool definition', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_flag_tool_1', type: 'function', function: { name: 'ext_flag_echo', arguments: '{}' } }] } }] }
        ]);
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_flag_tool_1' || toolOutput !== 'ext-flag: plan=review;debug=true;missing=undefined') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension flag registered tool did not receive CLI flags', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension flag tool ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension no builtin registered tool')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension no-builtin registered tool stream request' }));
        return;
      }
      const unexpectedBuiltins = ['bash', 'read', 'grep', 'ls', 'find', 'write', 'edit'].filter((name) => hasTool(name));
      if (!hasTool('ext_echo') || unexpectedBuiltins.length > 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'no-builtin extension tool definition mismatch', unexpectedBuiltins, tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_no_builtin_tool_1', type: 'function', function: { name: 'ext_echo', arguments: JSON.stringify({ value: 'no-builtin-ok' }) } }] } }] }
        ]);
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_no_builtin_tool_1' || toolOutput !== 'ext-echo: no-builtin-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'no-builtin extension registered tool did not execute', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension no builtin tool ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension allowlist registered tool')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension allowlist registered tool stream request' }));
        return;
      }
      const unexpectedBuiltins = ['bash', 'read', 'grep', 'ls', 'find', 'write', 'edit'].filter((name) => hasTool(name));
      if (!hasTool('ext_echo') || unexpectedBuiltins.length > 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'allowlisted extension tool definition mismatch', unexpectedBuiltins, tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_allowlist_tool_1', type: 'function', function: { name: 'ext_echo', arguments: JSON.stringify({ value: 'allowlist-ok' }) } }] } }] }
        ]);
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_allowlist_tool_1' || toolOutput !== 'ext-echo: allowlist-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'allowlisted extension registered tool did not execute', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension allowlist tool ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension permission gate') && !user.includes('rpc extension permission gate')) {
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension permission gate stream request' }));
        return;
      }
      if (!hasTool('bash')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool for extension permission gate', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_permission_gate_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command: 'printf should-not-run' }) } }] } }] }
        ]);
        return;
      }
      const toolOutput = String(toolMessages.at(-1)?.content ?? '').trim();
      if (
        toolMessages.at(-1)?.tool_call_id !== 'call_extension_permission_gate_1' ||
        !toolOutput.includes('blocked by headless permission gate') ||
        toolOutput.includes('should-not-run')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension permission gate did not block bash before execution', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension permission gate ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension bash override tool') && !user.includes('rpc extension bash override tool')) {
      const definitionError = extensionBashOverrideDefinitionError();
      if (definitionError) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify(definitionError));
        return;
      }
      if (body.stream !== true) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected extension bash override stream request' }));
        return;
      }
      if (toolMessages.length === 0) {
        writeStreamEvents([
          { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_bash_override_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ value: 'json-override-ok' }) } }] } }] }
        ]);
        return;
      }
      const lastTool = toolMessages.at(-1);
      const toolOutput = String(lastTool?.content ?? '').trim();
      if (lastTool?.tool_call_id !== 'call_extension_bash_override_1' || toolOutput !== 'ext-bash: json-override-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension bash override did not execute extension tool', toolMessages }));
        return;
      }
      writeStreamEvents([
        { choices: [{ delta: { content: 'extension bash override ' } }] },
        { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
      ]);
      return;
    }
    if (user.includes('extension typescript tool') && !user.includes('rpc extension typescript tool')) {
      if (!hasTool('ext_ts_echo')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing extension TypeScript tool definition', tools: body.tools }));
        return;
      }
      const tsTool = body.tools?.find((tool) => tool?.function?.name === 'ext_ts_echo')?.function;
      if (
        !tsTool?.description?.includes('TypeScript extension tool') ||
        tsTool?.parameters?.properties?.value?.type !== 'string' ||
        !tsTool?.parameters?.required?.includes('value')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension TypeScript tool schema mismatch', tool: tsTool }));
        return;
      }
      if (toolMessages.length === 0) {
        if (body.stream === true) {
          writeStreamEvents([
            { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_extension_ts_tool_1', type: 'function', function: { name: 'ext_ts_echo', arguments: JSON.stringify({ value: 'ts-registered-ok' }) } }] } }] }
          ]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_extension_ts_tool_1',
                type: 'function',
                function: {
                  name: 'ext_ts_echo',
                  arguments: JSON.stringify({ value: 'ts-registered-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_extension_ts_tool_1' || toolOutput !== 'ext-ts-echo: ts-registered-ok') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'extension TypeScript tool did not execute', toolMessages }));
        return;
      }
      if (body.stream === true) {
        writeStreamEvents([
          { choices: [{ delta: { content: 'extension ts tool ' } }] },
          { choices: [{ delta: { content: 'complete: ' + toolOutput } }] }
        ]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'extension ts tool complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('multi tool loop')) {
      const requiredTools = ['read', 'ls', 'grep', 'find', 'write', 'edit'];
      const missingTools = requiredTools.filter((name) => !hasTool(name));
      if (missingTools.length > 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing tool definitions: ' + missingTools.join(',') }));
        return;
      }
      if (toolMessages.length === 0) {
        const fixture = 'zig-out/pi-zig-agent-tool-fixture';
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [
                {
                  id: 'call_read_1',
                  type: 'function',
                  function: { name: 'read', arguments: JSON.stringify({ path: fixture + '/input.txt', limit: 1 }) }
                },
                {
                  id: 'call_ls_1',
                  type: 'function',
                  function: { name: 'ls', arguments: JSON.stringify({ path: fixture, limit: 10 }) }
                },
                {
                  id: 'call_grep_1',
                  type: 'function',
                  function: { name: 'grep', arguments: JSON.stringify({ pattern: 'needle', path: fixture, glob: '*.txt', ignoreCase: true, literal: true, limit: 5 }) }
                },
                {
                  id: 'call_find_1',
                  type: 'function',
                  function: { name: 'find', arguments: JSON.stringify({ pattern: '*.txt', path: fixture, limit: 10 }) }
                },
                {
                  id: 'call_write_1',
                  type: 'function',
                  function: { name: 'write', arguments: JSON.stringify({ path: fixture + '/generated.txt', content: 'generated by provider' }) }
                },
                {
                  id: 'call_edit_1',
                  type: 'function',
                  function: { name: 'edit', arguments: JSON.stringify({ path: fixture + '/editable.txt', edits: [{ oldText: 'before edit', newText: 'after edit' }] }) }
                }
              ]
            }
          }]
        }));
        return;
      }
      const byId = Object.fromEntries(toolMessages.map((message) => [message.tool_call_id, message.content]));
      const assistantToolMessage = body.messages.find(
        (message) => message.role === 'assistant' && Array.isArray(message.tool_calls)
      );
      const expectedToolCallIds = [
        'call_read_1',
        'call_ls_1',
        'call_grep_1',
        'call_find_1',
        'call_write_1',
        'call_edit_1'
      ];
      const assistantToolCallIds = assistantToolMessage?.tool_calls?.map((call) => call.id) ?? [];
      const toolMessageIds = toolMessages.map((message) => message.tool_call_id);
      if (
        assistantToolCallIds.length !== expectedToolCallIds.length ||
        expectedToolCallIds.some((id) => !assistantToolCallIds.includes(id) || !toolMessageIds.includes(id))
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'multi tool transcript did not preserve all tool_call_ids', assistantToolCallIds, toolMessageIds }));
        return;
      }
      const hasExpectedResults =
        byId.call_read_1?.includes('Needle Alpha') &&
        byId.call_ls_1?.includes('input.txt') &&
        byId.call_grep_1?.includes('input.txt:1:Needle Alpha') &&
        byId.call_find_1?.includes('input.txt') &&
        byId.call_write_1?.includes('Successfully wrote') &&
        byId.call_edit_1?.includes('Successfully replaced');
      if (!hasExpectedResults) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected multi tool results', byId }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'multi tool loop complete' } }] }));
      return;
    }
    if (user.includes('slow bash updates')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        if (body.stream === true) {
          writeStreamEvents([
            { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_slow_bash_updates_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command: 'printf slow-first; sleep 0.2; printf slow-second' }) } }] } }] }
          ]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_slow_bash_updates_1',
                type: 'function',
                function: {
                  name: 'bash',
                  arguments: JSON.stringify({ command: 'printf slow-first; sleep 0.2; printf slow-second' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (toolMessages.at(-1).tool_call_id !== 'call_slow_bash_updates_1' || toolOutput !== 'slow-firstslow-second') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected slow bash update output', toolOutput }));
        return;
      }
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content: 'slow bash updates complete: ' + toolOutput } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'slow bash updates complete: ' + toolOutput } }] }));
      return;
    }
    if (user.includes('timeout bash tool')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        const toolCall = {
          index: 0,
          id: 'call_timeout_bash_1',
          type: 'function',
          function: {
            name: 'bash',
            arguments: JSON.stringify({ command: 'printf before-timeout; sleep 1; printf after-timeout', timeout: 0.1 })
          }
        };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_timeout_bash_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'timeout bash result did not preserve tool_call_id' }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content;
      if (!toolOutput.includes('before-timeout') || toolOutput.includes('after-timeout') || !toolOutput.includes('Command timed out after 0.100 seconds')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected timeout bash output', toolOutput }));
        return;
      }
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content: 'timeout bash complete' } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'timeout bash complete' } }] }));
      return;
    }
    if (user.includes('long bash updates')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        const command = 'node -e ' + JSON.stringify("for (let i = 0; i < 2105; i++) console.log('json-update-line-' + String(i).padStart(4, '0'))");
        const toolCall = {
          index: 0,
          id: 'call_long_bash_updates_1',
          type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command }) }
        };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content;
      if (
        toolMessages.at(-1).tool_call_id !== 'call_long_bash_updates_1' ||
        toolOutput.includes('json-update-line-0000') ||
        !toolOutput.includes('json-update-line-2104') ||
        !toolOutput.includes('Full output: zig-out/pi-zig-bash-full-output.log')
      ) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'unexpected long bash update output', toolOutput }));
        return;
      }
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content: 'long bash updates complete' } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'long bash updates complete' } }] }));
      return;
    }
    if (user.includes('invalid tool arguments loop')) {
      if (!hasTool('read')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing read tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_invalid_tool_args_1',
                type: 'function',
                function: {
                  name: 'read',
                  arguments: '{"path":'
                }
              }]
            }
          }]
        }));
        return;
      }
      const invalidToolMessage = toolMessages.find((message) => message.tool_call_id === 'call_invalid_tool_args_1');
      if (!invalidToolMessage?.content?.includes('read tool argument JSON is invalid:')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'invalid tool arguments did not return a structured tool error', toolMessages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'invalid tool arguments loop complete' } }] }));
      return;
    }
    if (userMessages.some((message) => message.includes('read image result'))) {
      if (!hasTool('read')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing read tool definition for image result smoke', tools: body.tools }));
        return;
      }
      if (toolMessages.length === 0) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_read_image_1',
                type: 'function',
                function: {
                  name: 'read',
                  arguments: JSON.stringify({ path: 'zig-out/pi-zig-agent-tool-image-fixture/input.png' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const assistantToolCall = body.messages.find((message) =>
        message.role === 'assistant' &&
        message.tool_calls?.some((call) => call.id === 'call_read_image_1' && call.function?.name === 'read')
      );
      const readToolMessage = toolMessages.find((message) => message.tool_call_id === 'call_read_image_1');
      const syntheticImageMessage = body.messages.find((message) =>
        message.role === 'user' &&
        Array.isArray(message.content) &&
        message.content.some((part) => part?.type === 'text' && part.text === 'Attached image(s) from tool result:') &&
        hasReadToolImage(message.content)
      );
      if (!assistantToolCall || !readToolMessage?.content?.includes('Read image file [image/png]') || !syntheticImageMessage) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing image-capable read tool result replay', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'read image result complete' } }] }));
      return;
    }
    if (user.includes('tool loop')) {
      if (!hasBashTool) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing bash tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        if (body.stream === true) {
          writeStreamEvents([
            { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_tool_loop_1', type: 'function', function: { name: 'bash', arguments: '{"command":"printf ' } }] } }] },
            { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'tool-loop-ok"}' } }] } }] }
          ]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_tool_loop_1',
                type: 'function',
                function: {
                  name: 'bash',
                  arguments: JSON.stringify({ command: 'printf tool-loop-ok' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const assistantToolMessage = body.messages.find((message) => message.role === 'assistant' && Array.isArray(message.tool_calls));
      if (!assistantToolMessage) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing assistant tool call transcript' }));
        return;
      }
      if (toolMessages.at(-1).tool_call_id !== 'call_tool_loop_1') {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'tool result did not preserve tool_call_id' }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content: 'tool loop complete: ' + toolOutput } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        choices: [{
          message: {
            content: 'tool loop complete: ' + toolOutput
          }
        }]
      }));
      return;
    }
    if (user.includes('failing read loop')) {
      if (!hasTool('read')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing read tool definition' }));
        return;
      }
      if (toolMessages.length === 0) {
        if (body.stream === true) {
          writeStreamEvents([
            { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_failing_read_1', type: 'function', function: { name: 'read', arguments: '{"path":"zig-out/pi-zig-missing-' } }] } }] },
            { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'provider-read.txt"}' } }] } }] }
          ]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          choices: [{
            message: {
              content: null,
              tool_calls: [{
                id: 'call_failing_read_1',
                type: 'function',
                function: {
                  name: 'read',
                  arguments: JSON.stringify({ path: 'zig-out/pi-zig-missing-provider-read.txt' })
                }
              }]
            }
          }]
        }));
        return;
      }
      const toolOutput = toolMessages.at(-1).content.trim();
      if (!toolOutput.includes('read tool failed:')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'expected read failure tool output', toolOutput }));
        return;
      }
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content: 'failing read loop complete: ' + toolOutput } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        choices: [{
          message: {
            content: 'failing read loop complete: ' + toolOutput
          }
        }]
      }));
      return;
    }
    if (user.includes('rpc steer image one')) {
      const promptContent = userMessageIncluding('rpc prompt image before steer')?.content;
      const steerContent = lastUserMessage?.content;
      if (!hasSmokeImage(promptContent) || !hasSmokeImage(steerContent) || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing queued steer image content parts', promptContent, steerContent, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc queued steer image observed' } }] }));
      return;
    }
    if (user.includes('rpc follow image two')) {
      const followOneContent = userMessageIncluding('rpc follow image one')?.content;
      const followTwoContent = lastUserMessage?.content;
      if (!hasSmokeImage(followOneContent) || !hasSmokeImage(followTwoContent) || (body.tools?.length ?? 0) === 0) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing queued follow-up image content parts', followOneContent, followTwoContent, tools: body.tools }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc queued follow image observed' } }] }));
      return;
    }
    if (userMessages.includes('rpc active slash resource steer start')) {
      if (userMessages.includes('rpc slash prompt template expansion: first=alpha rest=beta gamma delta all=alpha "beta gamma" delta')) {
        const content = 'rpc active slash resource steer observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-active-resource-steer.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-active-resource-steer.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_active_resource_steer_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      res.writeHead(409, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'active slash resource steer was not drained before tool-result continuation', userMessages, toolMessages }));
      return;
    }
    if (userMessages.includes('rpc active slash resource follow start')) {
      if (userMessages.includes('rpc slash prompt template expansion: first=alpha rest=beta gamma delta all=alpha "beta gamma" delta')) {
        const content = 'rpc active slash resource follow observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-active-resource-follow.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-active-resource-follow.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_active_resource_follow_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      const content = 'rpc active slash resource follow base complete';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (userMessages.includes('rpc active prompt streaming steer start')) {
      if (userMessages.includes('rpc active prompt streaming steer queued')) {
        const content = 'rpc active prompt streaming steer observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-prompt-streaming-steer.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-prompt-streaming-steer.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_prompt_streaming_steer_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      res.writeHead(409, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'prompt streaming steer was not drained before tool-result continuation', userMessages, toolMessages }));
      return;
    }
    if (userMessages.includes('rpc active prompt streaming follow start')) {
      if (userMessages.includes('rpc active prompt streaming follow queued')) {
        const content = 'rpc active prompt streaming follow observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-prompt-streaming-follow.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-prompt-streaming-follow.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_prompt_streaming_follow_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      const content = 'rpc active prompt streaming follow base complete';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (userMessages.includes('rpc active extension steer start')) {
      if (userMessages.includes('/write-marker active raw steer') && userMessages.includes('rpc active custom steer')) {
        const content = 'rpc active extension steer observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-extension-active-steer.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-extension-active-steer.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_active_extension_steer_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      res.writeHead(409, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'active extension steer was not drained before tool-result continuation', userMessages, toolMessages }));
      return;
    }
    if (userMessages.includes('rpc active extension follow start')) {
      if (userMessages.includes('/write-marker active raw follow') && userMessages.includes('rpc active custom follow')) {
        const content = 'rpc active extension follow observed';
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { content } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content } }] }));
        return;
      }
      if (toolMessages.length === 0) {
        const started = process.cwd() + '/zig-out/pi-zig-rpc-provider-extension-active-follow.started';
        const release = process.cwd() + '/zig-out/pi-zig-rpc-provider-extension-active-follow.release';
        const command = 'printf started > ' + JSON.stringify(started) + '; while [ ! -f ' + JSON.stringify(release) + ' ]; do sleep 0.05; done; printf released';
        const toolCall = { index: 0, id: 'call_rpc_active_extension_follow_1', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } };
        if (body.stream === true) {
          writeStreamEvents([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [toolCall] } }] }));
        return;
      }
      const content = 'rpc active extension follow base complete';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (userMessages.includes('rpc steer start')) {
      const content = userMessages.includes('rpc steer two')
        ? 'handled rpc steer two'
        : userMessages.includes('rpc steer one')
          ? 'handled rpc steer one'
          : 'missing rpc steer';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (userMessages.includes('rpc follow start')) {
      const content = userMessages.includes('rpc follow two')
        ? 'batched rpc follow response'
        : 'rpc follow base complete';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('json retry transient')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count === 1) {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'temporary json provider failure' }));
        return;
      }
      const content = user.includes('tool-capable') ? 'json retry tool-capable recovered' : 'json retry stream recovered';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('rpc retry transient')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count === 1) {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'temporary provider failure' }));
        return;
      }
      const content = 'rpc retry recovered';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('rpc retry body overloaded')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count === 1) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'provider returned error: upstream connect reset before headers' } }));
        return;
      }
      const content = 'rpc retry body overloaded recovered';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('rpc retry abort delay')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count === 1) {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'temporary provider failure before abortable retry delay' }));
        return;
      }
      const content = 'rpc retry abort delay unexpectedly recovered';
      if (body.stream === true) {
        writeStreamEvents([{ choices: [{ delta: { content } }] }]);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
      return;
    }
    if (user.includes('rpc retry context overflow')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count > 1) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: 'context overflow was retried' } }] }));
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'Your input exceeds the context window of this model' } }));
      return;
    }
    if (user.includes('rpc retry exhausted')) {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'temporary provider failure' }));
      return;
    }
    if (user.includes('rpc retry client error')) {
      const count = (requestCounts.get(user) ?? 0) + 1;
      requestCounts.set(user, count);
      if (count > 1) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: 'client error was retried' } }] }));
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad user request' }));
      return;
    }
    if (user.includes('second rpc history')) {
      const hasPriorUser = body.messages.some((message) => message.role === 'user' && message.content === 'first rpc history');
      const hasPriorAssistant = body.messages.some((message) => message.role === 'assistant' && String(message.content ?? '').includes('first rpc history'));
      if (!hasPriorUser || !hasPriorAssistant) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing prior RPC history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc history observed' } }] }));
      return;
    }
    if (user.includes('rpc bash history check')) {
      const bashHistory = body.messages.find((message) => {
        const content = String(message.content ?? '');
        return message.role === 'user' && content.includes('Ran ') && content.includes('printf rpc-history-bash');
      });
      if (!bashHistory || !String(bashHistory.content).includes('rpc-history-bash')) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing prior bashExecution history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc bash history observed' } }] }));
      return;
    }
    if (user.includes('rpc truncated bash history check')) {
      const bashHistory = body.messages.find((message) => {
        const content = String(message.content ?? '');
        return (
          message.role === 'user' &&
          content.includes('rpc-truncated-history-line-2104') &&
          content.includes('[Output truncated. Full output: zig-out/pi-zig-bash-full-output.log]')
        );
      });
      if (!bashHistory) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing truncated bashExecution full output path history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc truncated bash history observed' } }] }));
      return;
    }
    if (user.includes('rpc tool history check')) {
      const assistantToolHistory = body.messages.find(
        (message) =>
          message.role === 'assistant' &&
          Array.isArray(message.tool_calls) &&
          message.tool_calls.some((call) => call.id === 'call_tool_loop_1' && call.function?.name === 'bash')
      );
      const toolHistory = body.messages.find(
        (message) =>
          message.role === 'tool' &&
          message.tool_call_id === 'call_tool_loop_1' &&
          String(message.content ?? '').includes('tool-loop-ok')
      );
      if (!assistantToolHistory || !toolHistory) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing prior assistant/tool-call transcript history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc tool history observed' } }] }));
      return;
    }
    if (user.includes('rpc compaction history check')) {
      const compactionHistory = body.messages.find(
        (message) =>
          message.role === 'user' &&
          String(message.content ?? '').includes('The conversation history before this point was compacted') &&
          String(message.content ?? '').includes('summary of compacted provider history')
      );
      const keptHistory = body.messages.find(
        (message) => message.role === 'user' && String(message.content ?? '').includes('kept provider message')
      );
      const rawCompactedHistory = body.messages.find(
        (message) => String(message.content ?? '') === 'raw compacted provider message'
      );
      if (!compactionHistory || !keptHistory || rawCompactedHistory) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing compacted context history', messages: body.messages }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'rpc compaction history observed' } }] }));
      return;
    }
    if (user.includes('rpc provider abort in flight')) {
      fs.writeFileSync('zig-out/pi-zig-rpc-provider-abort-in-flight.started', 'started');
      setTimeout(() => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ choices: [{ message: { content: 'rpc provider abort unexpectedly completed' } }] }));
      }, 1200);
      return;
    }
    const defaultContent = 'mock provider response for ' + body.model + ': ' + user + (system ? ' [system=' + system + ']' : '');
    if (body.stream === true) {
      writeStreamEvents([{ choices: [{ delta: { content: defaultContent } }] }]);
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      choices: [{
        message: {
          content: defaultContent
        }
      }]
    }));
  });
});
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  console.log('http://127.0.0.1:' + address.port + '/v1');
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`
    ],
    { stdio: ['ignore', 'pipe', 'inherit'] }
  );

  const baseUrl = await new Promise((resolve, reject) => {
    let text = '';
    child.stdout.on('data', (chunk) => {
      text += chunk.toString('utf8');
      const newline = text.indexOf('\n');
      if (newline >= 0) resolve(text.slice(0, newline).trim());
    });
    child.once('error', reject);
    child.once('exit', (code) => {
      if (code !== 0) reject(new Error(`fake provider exited early with ${code}`));
    });
  });

  return {
    baseUrl,
    stop() {
      child.kill('SIGTERM');
    }
  };
}

const status = run(['status']);
if (!status.includes('pi-zig foundation')) {
  throw new Error('status smoke did not identify pi-zig foundation');
}

const packages = JSON.parse(run(['packages']));
if (packages.packages.length !== 4) {
  throw new Error(`expected 4 packages, got ${packages.packages.length}`);
}

const rpc = JSON.parse(run(['rpc-schema']));
if (
  !rpc.commands.includes('prompt') ||
  !rpc.commands.includes('get_state') ||
  !rpc.commands.includes('get_available_models')
) {
  throw new Error('rpc-schema smoke missing core commands');
}
if (rpc.commands.length !== 29 || rpc.commands.includes('select') || !rpc.commands.includes('get_messages')) {
  throw new Error('rpc-schema smoke does not match authoritative RpcCommand union');
}

const emptyCommands = JSON.parse(run(['commands']));
if (!Array.isArray(emptyCommands.commands)) {
  throw new Error('commands smoke did not return command array');
}

const commandsFixtureRoot = path.resolve('zig-out/pi-zig-commands-fixture');
const commandsFixtureHome = path.join(commandsFixtureRoot, 'home');
const commandsFixtureEnv = { ...process.env, HOME: commandsFixtureHome };
const commandsFixtureCommandExecMarker = path.join(commandsFixtureRoot, 'extensions/command-exec-marker.txt');
fs.rmSync(commandsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.git'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/agent/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/agent/skills/brave-search'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/skills/project-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/skills/resource-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-plus-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-reincluded-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-force-off-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/utility-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-plus-skills/project-plus-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.agents/skills/ancestor-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-manifest/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-manifest/skills/project-package-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-convention/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-convention/skills/project-convention-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-keep-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-drop-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-disabled/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-disabled/skills/project-package-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'workspace/nested'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'explicit/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'explicit/skills/ship-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'extensions'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/skills/global-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-plus-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-reincluded-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-force-off-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-plus-skills/global-plus-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/skills/global-package-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, 'settings-home-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, 'settings-home-skills/home-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.agents/skills/external-skill'), { recursive: true });
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings.json'),
  JSON.stringify({
    prompts: [
      'settings-prompts',
      'project-*.md',
      '!project-excluded.md',
      '!project-reincluded.md',
      '+settings-prompts/project-reincluded.md',
      '-settings-prompts/project-force-off.md'
    ],
    skills: [
      'settings-skills',
      'project-*-skill',
      '!project-disabled-skill',
      '!project-reincluded-skill',
      '+settings-skills/project-reincluded-skill',
      '-settings-skills/project-force-off-skill'
    ],
    packages: [
      '../packages/project-manifest',
      '../packages/project-convention',
      { source: '../packages/project-filtered', prompts: ['project-filter-keep.md'], skills: ['project-filter-keep-skill'] },
      { source: '../packages/project-disabled', prompts: [], skills: [] }
    ],
    enableSkillCommands: true
  })
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings.json'),
  JSON.stringify({
    prompts: [
      'settings-prompts',
      '~/settings-home-prompts',
      '!global-disabled.md',
      '!global-reincluded.md',
      '+settings-prompts/global-reincluded.md',
      '-settings-prompts/global-force-off.md'
    ],
    skills: [
      'settings-skills',
      '~/settings-home-skills',
      '!global-disabled-skill',
      '!global-reincluded-skill',
      '+settings-skills/global-reincluded-skill',
      '-settings-skills/global-force-off-skill'
    ],
    packages: ['packages/global-manifest'],
    enableSkillCommands: true
  })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/agent/prompts/fix-tests.md'),
  ['---', 'description: Fix failing tests', 'argument-hint: test command', '---', 'Run the tests and fix failures.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/prompts/review-code.md'),
  ['---', 'description: Review code changes', '---', 'Review code for bugs.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/prompts/resource-check.md'),
  [
    '---',
    'description: Resource expansion prompt',
    '---',
    'rpc slash prompt template expansion: first=$1 rest=${@:2} all=$ARGUMENTS'
  ].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-settings.md'),
  ['---', 'description: Project settings prompt', '---', 'Prompt from .pi/settings.json.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-excluded.md'),
  ['---', 'description: Project excluded prompt', '---', 'Prompt excluded by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-reincluded.md'),
  ['---', 'description: Project reincluded prompt', '---', 'Prompt re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-force-off.md'),
  ['---', 'description: Project force-off prompt', '---', 'Prompt disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/skip-settings.md'),
  ['---', 'description: Project skipped by include glob', '---', 'Prompt not matched by include glob.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-plus-prompts/project-plus.md'),
  ['---', 'description: Project plus prompt should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/agent/skills/brave-search/SKILL.md'),
  ['---', 'name: brave-search', 'description: Web search via Brave API', '---', 'Use Brave Search.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/skills/project-skill/SKILL.md'),
  ['---', 'name: project-skill', 'description: Project skill command', '---', 'Use the project skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/skills/resource-skill/SKILL.md'),
  ['---', 'name: resource-skill', 'description: Resource expansion skill', '---', 'rpc slash skill expansion body'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-settings-skill/SKILL.md'),
  ['---', 'name: project-settings-skill', 'description: Project settings skill command', '---', 'Use the project settings skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-disabled-skill/SKILL.md'),
  ['---', 'name: project-disabled-skill', 'description: Project disabled skill command', '---', 'Disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-reincluded-skill/SKILL.md'),
  ['---', 'name: project-reincluded-skill', 'description: Project reincluded skill command', '---', 'Re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-force-off-skill/SKILL.md'),
  ['---', 'name: project-force-off-skill', 'description: Project force-off skill command', '---', 'Disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/utility-skill/SKILL.md'),
  ['---', 'name: utility-skill', 'description: Utility skill excluded by include glob', '---', 'Not matched by include glob.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-plus-skills/project-plus-skill/SKILL.md'),
  ['---', 'name: project-plus-skill', 'description: Project plus skill should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.agents/skills/ancestor-skill/SKILL.md'),
  ['---', 'name: ancestor-skill', 'description: Ancestor agents skill command', '---', 'Use the ancestor skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/package.json'),
  JSON.stringify({
    name: 'project-manifest-package',
    pi: {
      prompts: ['prompts/project-package-review.md'],
      skills: ['skills/project-package-skill']
    }
  })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/prompts/project-package-review.md'),
  ['---', 'description: Project package prompt', '---', 'Prompt from project package manifest.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/skills/project-package-skill/SKILL.md'),
  ['---', 'name: project-package-skill', 'description: Project package skill command', '---', 'Use the project package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/package.json'),
  JSON.stringify({ name: 'project-convention-package' })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/prompts/project-convention-prompt.md'),
  ['---', 'description: Project convention package prompt', '---', 'Prompt from package prompts directory.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/skills/project-convention-skill/SKILL.md'),
  ['---', 'name: project-convention-skill', 'description: Project convention package skill command', '---', 'Use the project convention package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/prompts/project-filter-keep.md'),
  ['---', 'description: Project filtered package prompt', '---', 'Prompt kept by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/prompts/project-filter-drop.md'),
  ['---', 'description: Project filtered package prompt should be disabled', '---', 'Prompt dropped by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-keep-skill/SKILL.md'),
  ['---', 'name: project-filter-keep-skill', 'description: Project filtered package skill command', '---', 'Use the filtered package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-drop-skill/SKILL.md'),
  ['---', 'name: project-filter-drop-skill', 'description: Project filtered package skill should be disabled', '---', 'Dropped by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-disabled/prompts/project-disabled-prompt.md'),
  ['---', 'description: Project disabled package prompt', '---', 'Disabled by empty package prompt filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-disabled/skills/project-package-disabled-skill/SKILL.md'),
  ['---', 'name: project-package-disabled-skill', 'description: Project disabled package skill', '---', 'Disabled by empty package skill filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'explicit/prompts/ship.md'),
  ['---', 'description: Ship a release', '---', 'Prepare release notes.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'explicit/skills/ship-skill/SKILL.md'),
  ['---', 'name: ship-skill', 'description: Temporary release skill', '---', 'Use the release skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'extensions/commands-a.mjs'),
  [
    'export default function(pi) {',
    '  pi.registerCommand("deploy", { description: "Deploy from extension A", handler: async () => {} });',
    '  pi.registerCommand("review", { description: "Review from extension A", handler: async () => {} });',
    '}'
  ].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'extensions/commands-b.mjs'),
  [
    'export default function(pi) {',
    '  pi.registerCommand("deploy", { description: "Deploy from extension B", handler: async () => {} });',
    '}'
  ].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'extensions/command-exec.mjs'),
  [
    'import fs from "node:fs";',
    '',
    'export default function(pi) {',
    '  pi.registerCommand("write-marker", {',
    '    description: "Write marker from extension command",',
    '    handler: async (args, ctx) => {',
    '      await ctx.waitForIdle();',
    `      fs.writeFileSync(${JSON.stringify(commandsFixtureCommandExecMarker)}, args + "|hasUI:" + ctx.hasUI);`,
    '    }',
    '  });',
    '  pi.registerCommand("send-user-message", {',
    '    description: "Send raw text as a user message",',
    '    handler: async (args) => {',
    '      await pi.sendUserMessage(args);',
    '    }',
    '  });',
    '  pi.registerCommand("send-user-image-message", {',
    '    description: "Send raw text and an image as a user message",',
    '    handler: async (args) => {',
    '      await pi.sendUserMessage([',
    '        { type: "text", text: args },',
    '        { type: "image", data: "aW1hZ2Utc21va2U=", mimeType: "image/png" }',
    '      ]);',
    '    }',
    '  });',
    '  pi.registerCommand("send-custom-message", {',
    '    description: "Send an extension custom message",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "test-extension", content: args, display: false });',
    '    }',
    '  });',
    '  pi.registerCommand("send-trigger-message", {',
    '    description: "Send a custom message and trigger a turn",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { triggerTurn: true });',
    '    }',
    '  });',
    '  pi.registerCommand("send-next-turn-message", {',
    '    description: "Queue a custom message for the next turn",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { deliverAs: "nextTurn" });',
    '    }',
    '  });',
    '  pi.registerCommand("send-next-turn-rpc-provider", {',
    '    description: "Queue a custom message for the next provider-backed RPC turn",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "next-turn-extension", content: args, display: true }, { deliverAs: "nextTurn" });',
    '    }',
    '  });',
    '  pi.registerCommand("send-user-steer-active", {',
    '    description: "Queue a raw user steering message while active",',
    '    handler: async (args) => {',
    '      await pi.sendUserMessage(args, { deliverAs: "steer" });',
    '    }',
    '  });',
    '  pi.registerCommand("send-user-follow-active", {',
    '    description: "Queue a raw user follow-up message while active",',
    '    handler: async (args) => {',
    '      await pi.sendUserMessage(args, { deliverAs: "followUp" });',
    '    }',
    '  });',
    '  pi.registerCommand("send-custom-steer-active", {',
    '    description: "Queue a custom steering message while active",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "active-steer-extension", content: args, display: true }, { deliverAs: "steer" });',
    '    }',
    '  });',
    '  pi.registerCommand("send-custom-follow-active", {',
    '    description: "Queue a custom follow-up message while active",',
    '    handler: async (args) => {',
    '      await pi.sendMessage({ customType: "active-follow-extension", content: args, display: true }, { deliverAs: "followUp" });',
    '    }',
    '  });',
    '  pi.registerCommand("append-entry", {',
    '    description: "Append an extension state entry",',
    '    handler: async (args) => {',
    '      await pi.appendEntry("test-entry", { content: args, n: 1 });',
    '    }',
    '  });',
    '}'
  ].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/prompts/global-review.md'),
  ['---', 'description: Global review prompt', '---', 'Review globally.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-settings.md'),
  ['---', 'description: Global settings prompt', '---', 'Prompt from global settings.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-disabled.md'),
  ['---', 'description: Global disabled prompt', '---', 'Prompt disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-reincluded.md'),
  ['---', 'description: Global reincluded prompt', '---', 'Prompt re-enabled by + setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-force-off.md'),
  ['---', 'description: Global force-off prompt', '---', 'Prompt disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-plus-prompts/global-plus.md'),
  ['---', 'description: Global plus prompt should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, 'settings-home-prompts/home-settings.md'),
  ['---', 'description: Home-expanded settings prompt', '---', 'Prompt from ~/ setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/skills/global-skill/SKILL.md'),
  ['---', 'name: global-skill', 'description: Global skill command', '---', 'Use the global skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-settings-skill/SKILL.md'),
  ['---', 'name: global-settings-skill', 'description: Global settings skill command', '---', 'Use the global settings skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-disabled-skill/SKILL.md'),
  ['---', 'name: global-disabled-skill', 'description: Global disabled skill command', '---', 'Disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-reincluded-skill/SKILL.md'),
  ['---', 'name: global-reincluded-skill', 'description: Global reincluded skill command', '---', 'Re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-force-off-skill/SKILL.md'),
  ['---', 'name: global-force-off-skill', 'description: Global force-off skill command', '---', 'Disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-plus-skills/global-plus-skill/SKILL.md'),
  ['---', 'name: global-plus-skill', 'description: Global plus skill should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, 'settings-home-skills/home-settings-skill/SKILL.md'),
  ['---', 'name: home-settings-skill', 'description: Home-expanded settings skill command', '---', 'Use the home-expanded skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/package.json'),
  JSON.stringify({
    name: 'global-manifest-package',
    pi: {
      prompts: ['prompts/global-package-review.md'],
      skills: ['skills/global-package-skill']
    }
  })
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/prompts/global-package-review.md'),
  ['---', 'description: Global package prompt', '---', 'Prompt from global package manifest.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/skills/global-package-skill/SKILL.md'),
  ['---', 'name: global-package-skill', 'description: Global package skill command', '---', 'Use the global package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.agents/skills/external-skill/SKILL.md'),
  ['---', 'name: external-skill', 'description: External agents skill command', '---', 'Use the external skill.'].join('\n')
);
const fixtureCommands = JSON.parse(run(
  [
    'commands',
    '--skill',
    'explicit/skills',
    '--prompt-template',
    'explicit/prompts',
    '--extension',
    'extensions/commands-a.mjs',
    '--extension',
    'extensions/commands-b.mjs'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
));
if (
  !fixtureCommands.commands.some((command) =>
    command.name === 'deploy:1' &&
    command.description === 'Deploy from extension A' &&
    command.source === 'extension' &&
    command.sourceInfo?.source === 'extension' &&
    command.sourceInfo?.scope === 'temporary'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'review' &&
    command.description === 'Review from extension A' &&
    command.source === 'extension'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'deploy:2' &&
    command.description === 'Deploy from extension B' &&
    command.source === 'extension'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'fix-tests' &&
    command.description === 'Fix failing tests' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'review-code' &&
    command.description === 'Review code changes' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/prompts')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'resource-check' &&
    command.description === 'Resource expansion prompt' &&
    command.source === 'prompt' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/prompts')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-review' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-settings' &&
    command.description === 'Project settings prompt' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/settings-prompts')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-reincluded' &&
    command.description === 'Project reincluded prompt' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-settings' &&
    command.description === 'Global settings prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-reincluded' &&
    command.description === 'Global reincluded prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'home-settings' &&
    command.description === 'Home-expanded settings prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-package-review' &&
    command.description === 'Project package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-manifest' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-convention-prompt' &&
    command.description === 'Project convention package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-convention'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-filter-keep' &&
    command.description === 'Project filtered package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-filtered' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-package-review' &&
    command.description === 'Global package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === 'packages/global-manifest' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'ship' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'temporary'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:brave-search' &&
    command.description === 'Web search via Brave API' &&
    command.source === 'skill' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/agent/skills/brave-search')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-skill' &&
    command.description === 'Project skill command' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/skills/project-skill')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:resource-skill' &&
    command.description === 'Resource expansion skill' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/skills/resource-skill')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-skill' &&
    command.description === 'Global skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-settings-skill' &&
    command.description === 'Project settings skill command' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-reincluded-skill' &&
    command.description === 'Project reincluded skill command' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-settings-skill' &&
    command.description === 'Global settings skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-reincluded-skill' &&
    command.description === 'Global reincluded skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:home-settings-skill' &&
    command.description === 'Home-expanded settings skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-package-skill' &&
    command.description === 'Project package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-manifest' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-convention-skill' &&
    command.description === 'Project convention package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-convention'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-filter-keep-skill' &&
    command.description === 'Project filtered package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-filtered' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-package-skill' &&
    command.description === 'Global package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === 'packages/global-manifest' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:external-skill' &&
    command.description === 'External agents skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:ship-skill' &&
    command.description === 'Temporary release skill' &&
    command.sourceInfo?.scope === 'temporary'
  )
) {
  throw new Error('commands smoke did not discover project, user, and explicit prompt/skill commands');
}
const unexpectedFixtureCommandNames = new Set([
  'project-excluded',
  'project-force-off',
  'skip-settings',
  'project-plus',
  'project-filter-drop',
  'project-disabled-prompt',
  'global-disabled',
  'global-force-off',
  'global-plus',
  'skill:project-disabled-skill',
  'skill:project-force-off-skill',
  'skill:utility-skill',
  'skill:project-plus-skill',
  'skill:project-filter-drop-skill',
  'skill:project-package-disabled-skill',
  'skill:global-disabled-skill',
  'skill:global-force-off-skill',
  'skill:global-plus-skill'
]);
const unexpectedFixtureCommand = fixtureCommands.commands.find((command) => unexpectedFixtureCommandNames.has(command.name));
if (unexpectedFixtureCommand) {
  throw new Error(`commands smoke returned disabled or pattern-only command ${unexpectedFixtureCommand.name}`);
}
const nestedFixtureCommands = JSON.parse(run(
  ['commands'],
  undefined,
  { cwd: path.join(commandsFixtureRoot, 'workspace/nested'), env: commandsFixtureEnv }
));
if (
  !nestedFixtureCommands.commands.some((command) =>
    command.name === 'skill:ancestor-skill' &&
    command.description === 'Ancestor agents skill command' &&
    command.sourceInfo?.scope === 'project'
  )
) {
  throw new Error('commands smoke did not discover ancestor .agents/skills from nested cwd');
}
const fixtureRpcCommandsOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    'zig-out/pi-zig-rpc-commands.jsonl',
    '--skill',
    'explicit/skills',
    '--prompt-template',
    'explicit/prompts',
    '--extension',
    'extensions/commands-a.mjs',
    '--extension',
    'extensions/commands-b.mjs'
  ],
  `${JSON.stringify({ id: 'cmds', type: 'get_commands' })}\n`,
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommands = fixtureRpcCommandsOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandsResponse = fixtureRpcCommands.find((response) => response.id === 'cmds');
if (
  !rpcCommandsResponse?.success ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'deploy:1' && command.source === 'extension') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'review' && command.source === 'extension') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'deploy:2' && command.source === 'extension') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'fix-tests' && command.source === 'prompt') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'resource-check' && command.source === 'prompt') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'global-review' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-settings' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-reincluded' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'home-settings' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-package-review' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-filter-keep' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'global-package-review' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'ship' && command.sourceInfo?.scope === 'temporary') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:brave-search' && command.source === 'skill') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:resource-skill' && command.source === 'skill') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-settings-skill' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-reincluded-skill' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-package-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-filter-keep-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:global-package-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:home-settings-skill' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:ship-skill' && command.sourceInfo?.scope === 'temporary')
) {
  throw new Error('rpc get_commands smoke did not return project, user, and explicit prompt/skill commands');
}
const unexpectedRpcCommand = rpcCommandsResponse.data.commands.find((command) => unexpectedFixtureCommandNames.has(command.name));
if (unexpectedRpcCommand) {
  throw new Error(`rpc get_commands smoke returned disabled or pattern-only command ${unexpectedRpcCommand.name}`);
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const fixtureRpcCommandExecOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    path.join(commandsFixtureRoot, 'rpc-command-exec.jsonl'),
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-exec-prompt', type: 'prompt', message: '/write-marker hello world' }),
    JSON.stringify({ id: 'rpc-command-exec-messages', type: 'get_messages' }),
    JSON.stringify({ id: 'rpc-command-exec-steer', type: 'steer', message: '/write-marker queued steer' }),
    JSON.stringify({ id: 'rpc-command-exec-follow', type: 'follow_up', message: '/write-marker queued follow' }),
    JSON.stringify({ id: 'rpc-command-exec-unknown', type: 'prompt', message: '/not-an-extension-command ordinary prompt' }),
    JSON.stringify({ id: 'rpc-command-exec-unknown-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandExecResponses = fixtureRpcCommandExecOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandExecPrompt = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-prompt');
const rpcCommandExecMessages = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-messages');
const rpcCommandExecSteer = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-steer');
const rpcCommandExecFollow = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-follow');
const rpcCommandExecUnknown = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-unknown');
const rpcCommandExecUnknownMessages = fixtureRpcCommandExecResponses.find((response) => response.id === 'rpc-command-exec-unknown-messages');
if (
  !rpcCommandExecPrompt?.success ||
  fs.readFileSync(commandsFixtureCommandExecMarker, 'utf8') !== 'hello world|hasUI:false' ||
  rpcCommandExecMessages?.data?.messages?.length !== 0 ||
  rpcCommandExecSteer?.success !== false ||
  !rpcCommandExecSteer?.error?.includes('Extension command "/write-marker" cannot be queued') ||
  rpcCommandExecFollow?.success !== false ||
  !rpcCommandExecFollow?.error?.includes('Extension command "/write-marker" cannot be queued') ||
  !rpcCommandExecUnknown?.success ||
  !rpcCommandExecUnknownMessages?.data?.messages?.some((message) => message.role === 'user' && message.content === '/not-an-extension-command ordinary prompt')
) {
  throw new Error('rpc extension command execution smoke did not match upstream prompt/queue semantics');
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const fixtureRpcCommandSendUserOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    path.join(commandsFixtureRoot, 'rpc-command-send-user-message.jsonl'),
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-send-user', type: 'prompt', message: '/send-user-message /write-marker raw user' }),
    JSON.stringify({ id: 'rpc-command-send-user-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandSendUserResponses = fixtureRpcCommandSendUserOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandSendUser = fixtureRpcCommandSendUserResponses.find((response) => response.id === 'rpc-command-send-user');
const rpcCommandSendUserMessages = fixtureRpcCommandSendUserResponses.find((response) => response.id === 'rpc-command-send-user-messages');
if (
  !rpcCommandSendUser?.success ||
  fs.existsSync(commandsFixtureCommandExecMarker) ||
  !rpcCommandSendUserMessages?.data?.messages?.some((message) => message.role === 'user' && message.content === '/write-marker raw user')
) {
  throw new Error('rpc extension command sendUserMessage action did not persist raw slash-looking user text');
}
const fixtureRpcCommandSendUserImageOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    path.join(commandsFixtureRoot, 'rpc-command-send-user-image-message.jsonl'),
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-send-user-image', type: 'prompt', message: '/send-user-image-message rpc command image user' }),
    JSON.stringify({ id: 'rpc-command-send-user-image-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandSendUserImageResponses = fixtureRpcCommandSendUserImageOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandSendUserImage = fixtureRpcCommandSendUserImageResponses.find((response) => response.id === 'rpc-command-send-user-image');
const rpcCommandSendUserImageMessages = fixtureRpcCommandSendUserImageResponses.find((response) => response.id === 'rpc-command-send-user-image-messages');
const rpcCommandSendUserImageMessage = rpcCommandSendUserImageMessages?.data?.messages?.find((message) => message.role === 'user' && message.content === 'rpc command image user');
if (
  !rpcCommandSendUserImage?.success ||
  rpcCommandSendUserImageMessage?.images?.[0]?.type !== 'image' ||
  rpcCommandSendUserImageMessage?.images?.[0]?.data !== 'aW1hZ2Utc21va2U=' ||
  rpcCommandSendUserImageMessage?.images?.[0]?.mimeType !== 'image/png'
) {
  throw new Error('rpc extension command sendUserMessage image action did not persist user image content');
}
const fixtureRpcCommandCustomSession = path.join(commandsFixtureRoot, 'rpc-command-send-custom-message.jsonl');
fs.rmSync(fixtureRpcCommandCustomSession, { force: true });
const fixtureRpcCommandCustomOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    fixtureRpcCommandCustomSession,
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-send-custom', type: 'prompt', message: '/send-custom-message custom note' }),
    JSON.stringify({ id: 'rpc-command-send-custom-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandCustomResponses = fixtureRpcCommandCustomOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandCustom = fixtureRpcCommandCustomResponses.find((response) => response.id === 'rpc-command-send-custom');
const rpcCommandCustomMessages = fixtureRpcCommandCustomResponses.find((response) => response.id === 'rpc-command-send-custom-messages');
const rpcCustomSessionText = fs.readFileSync(fixtureRpcCommandCustomSession, 'utf8');
if (
  !rpcCommandCustom?.success ||
  !rpcCommandCustomMessages?.data?.messages?.some((message) =>
    message.role === 'custom' &&
    message.customType === 'test-extension' &&
    message.content === 'custom note' &&
    message.display === false
  ) ||
  !rpcCustomSessionText.includes('"type":"custom_message"') ||
  !rpcCustomSessionText.includes('"customType":"test-extension"')
) {
  throw new Error('rpc extension command sendMessage action did not persist an upstream-shaped custom message');
}
const fixtureRpcCommandNextTurnSession = path.join(commandsFixtureRoot, 'rpc-command-send-next-turn-message.jsonl');
fs.rmSync(fixtureRpcCommandNextTurnSession, { force: true });
const fixtureRpcCommandNextTurnOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    fixtureRpcCommandNextTurnSession,
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-send-next-turn', type: 'prompt', message: '/send-next-turn-message queued custom note' }),
    JSON.stringify({ id: 'rpc-command-send-next-turn-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandNextTurnResponses = fixtureRpcCommandNextTurnOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandNextTurn = fixtureRpcCommandNextTurnResponses.find((response) => response.id === 'rpc-command-send-next-turn');
const rpcCommandNextTurnMessages = fixtureRpcCommandNextTurnResponses.find((response) => response.id === 'rpc-command-send-next-turn-messages');
const rpcNextTurnSessionText = fs.existsSync(fixtureRpcCommandNextTurnSession)
  ? fs.readFileSync(fixtureRpcCommandNextTurnSession, 'utf8')
  : '';
if (
  !rpcCommandNextTurn?.success ||
  rpcCommandNextTurnMessages?.data?.messages?.length !== 0 ||
  rpcNextTurnSessionText.includes('"type":"custom_message"') ||
  rpcNextTurnSessionText.includes('queued custom note')
) {
  throw new Error('rpc extension command sendMessage nextTurn action did not queue invisibly for the next turn');
}
const fixtureRpcCommandAppendEntrySession = path.join(commandsFixtureRoot, 'rpc-command-append-entry.jsonl');
fs.rmSync(fixtureRpcCommandAppendEntrySession, { force: true });
const fixtureRpcCommandAppendEntryOutput = run(
  [
    '--mode',
    'rpc',
    '--session',
    fixtureRpcCommandAppendEntrySession,
    '--extension',
    'extensions/command-exec.mjs'
  ],
  [
    JSON.stringify({ id: 'rpc-command-append-entry', type: 'prompt', message: '/append-entry persisted state' }),
    JSON.stringify({ id: 'rpc-command-append-entry-messages', type: 'get_messages' }),
    JSON.stringify({ id: 'rpc-command-append-entry-state', type: 'get_state' }),
    JSON.stringify({ id: 'rpc-command-append-entry-after-prompt', type: 'prompt', message: 'after append entry' }),
    JSON.stringify({ id: 'rpc-command-append-entry-after-messages', type: 'get_messages' }),
    JSON.stringify({ id: 'rpc-command-append-entry-clone', type: 'clone' }),
    JSON.stringify({ id: 'rpc-command-append-entry-clone-state', type: 'get_state' }),
    JSON.stringify({ id: 'rpc-command-append-entry-clone-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommandAppendEntryResponses = fixtureRpcCommandAppendEntryOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandAppendEntry = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry');
const rpcCommandAppendEntryMessages = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-messages');
const rpcCommandAppendEntryState = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-state');
const rpcCommandAppendEntryAfterPrompt = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-after-prompt');
const rpcCommandAppendEntryAfterMessages = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-after-messages');
const rpcCommandAppendEntryClone = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-clone');
const rpcCommandAppendEntryCloneState = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-clone-state');
const rpcCommandAppendEntryCloneMessages = fixtureRpcCommandAppendEntryResponses.find((response) => response.id === 'rpc-command-append-entry-clone-messages');
const rpcAppendEntrySessionEntries = fs.existsSync(fixtureRpcCommandAppendEntrySession)
  ? fs.readFileSync(fixtureRpcCommandAppendEntrySession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
const rpcAppendEntry = rpcAppendEntrySessionEntries.find((entry) =>
  entry.type === 'custom' &&
  entry.customType === 'test-entry' &&
  entry.data?.content === 'persisted state' &&
  entry.data?.n === 1
);
const rpcAppendEntryAfterPromptEntry = rpcAppendEntrySessionEntries.find((entry) =>
  entry.type === 'message' &&
  entry.message?.role === 'user' &&
  entry.message?.content === 'after append entry'
);
const rpcAppendEntryCloneSession = rpcCommandAppendEntryCloneState?.data?.sessionFile;
const rpcAppendEntryCloneSessionEntries = rpcAppendEntryCloneSession && fs.existsSync(rpcAppendEntryCloneSession)
  ? fs.readFileSync(rpcAppendEntryCloneSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  !rpcCommandAppendEntry?.success ||
  rpcCommandAppendEntryMessages?.data?.messages?.length !== 0 ||
  rpcCommandAppendEntryState?.data?.messageCount !== 0 ||
  !rpcAppendEntry ||
  !rpcCommandAppendEntryAfterPrompt?.success ||
  !rpcCommandAppendEntryAfterMessages?.data?.messages?.some((message) => message.role === 'user' && message.content === 'after append entry') ||
  rpcCommandAppendEntryAfterMessages?.data?.messages?.some((message) => message.customType === 'test-entry' || message.content === 'persisted state') ||
  !rpcAppendEntryAfterPromptEntry ||
  rpcAppendEntryAfterPromptEntry.parentId !== rpcAppendEntry.id ||
  !rpcCommandAppendEntryClone?.success ||
  !rpcCommandAppendEntryCloneState?.success ||
  !rpcCommandAppendEntryCloneMessages?.data?.messages?.some((message) => message.role === 'user' && message.content === 'after append entry') ||
  rpcCommandAppendEntryCloneMessages?.data?.messages?.some((message) => message.customType === 'test-entry' || message.content === 'persisted state') ||
  !rpcAppendEntryCloneSessionEntries.some((entry) =>
    entry.type === 'custom' &&
    entry.customType === 'test-entry' &&
    entry.data?.content === 'persisted state' &&
    entry.data?.n === 1
  )
) {
  throw new Error('rpc extension command appendEntry smoke did not persist a hidden custom entry, continue the parent chain, and preserve clone state');
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const topLevelCommandEnv = envWithoutAnthropicAuth({ HOME: commandsFixtureHome });
const topLevelTextCommandSession = path.join(commandsFixtureRoot, 'top-level-command-text.jsonl');
fs.rmSync(topLevelTextCommandSession, { force: true });
const topLevelTextCommandOutput = run(
  [
    '--session',
    topLevelTextCommandSession,
    '--provider',
    'anthropic',
    '--model',
    'claude-haiku-4-5',
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/write-marker top text'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelTextCommandSessionText = fs.existsSync(topLevelTextCommandSession)
  ? fs.readFileSync(topLevelTextCommandSession, 'utf8')
  : '';
if (
  topLevelTextCommandOutput !== '' ||
  fs.readFileSync(commandsFixtureCommandExecMarker, 'utf8') !== 'top text|hasUI:false' ||
  topLevelTextCommandSessionText.includes('"type":"message"')
) {
  throw new Error('top-level text mode extension command did not execute without provider output/auth');
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const topLevelJsonCommandSession = path.join(commandsFixtureRoot, 'top-level-command-json.jsonl');
fs.rmSync(topLevelJsonCommandSession, { force: true });
const topLevelJsonCommandOutput = run(
  [
    '--mode',
    'json',
    '--provider',
    'anthropic',
    '--model',
    'claude-haiku-4-5',
    '--session',
    topLevelJsonCommandSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/write-marker top json'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelJsonCommandLines = jsonLines(topLevelJsonCommandOutput);
const topLevelJsonCommandSessionText = fs.readFileSync(topLevelJsonCommandSession, 'utf8');
if (
  fs.readFileSync(commandsFixtureCommandExecMarker, 'utf8') !== 'top json|hasUI:false' ||
  topLevelJsonCommandLines.length !== 1 ||
  topLevelJsonCommandLines[0]?.type !== 'session' ||
  topLevelJsonCommandLines.some((line) => line.type === 'agent_start' || line.type === 'turn_start') ||
  topLevelJsonCommandSessionText.includes('"type":"message"') ||
  topLevelJsonCommandSessionText.includes('/write-marker top json')
) {
  throw new Error('top-level JSON mode extension command did not match upstream command-only prompt semantics');
}
const topLevelAppendEntrySession = path.join(commandsFixtureRoot, 'top-level-command-append-entry.jsonl');
fs.rmSync(topLevelAppendEntrySession, { force: true });
const topLevelAppendEntryOutput = run(
  [
    '--session',
    topLevelAppendEntrySession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/append-entry top hidden state'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelAppendEntryEntries = fs.existsSync(topLevelAppendEntrySession)
  ? fs.readFileSync(topLevelAppendEntrySession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
const topLevelAppendEntry = topLevelAppendEntryEntries.find((entry) =>
  entry.type === 'custom' &&
  entry.customType === 'test-entry' &&
  entry.data?.content === 'top hidden state' &&
  entry.data?.n === 1
);
if (
  topLevelAppendEntryOutput !== '' ||
  !topLevelAppendEntry ||
  topLevelAppendEntryEntries.some((entry) => entry.type === 'message' || entry.type === 'custom_message')
) {
  throw new Error('top-level extension command appendEntry smoke did not persist a hidden custom entry without model output');
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const topLevelSendUserSession = path.join(commandsFixtureRoot, 'top-level-command-send-user-message.jsonl');
fs.rmSync(topLevelSendUserSession, { force: true });
const topLevelSendUserOutput = run(
  [
    '--session',
    topLevelSendUserSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-user-message /write-marker raw top user'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelSendUserEntries = fs.existsSync(topLevelSendUserSession)
  ? fs.readFileSync(topLevelSendUserSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  !topLevelSendUserOutput.includes('pi-zig print-mode foundation accepted') ||
  !topLevelSendUserOutput.includes('Prompt:\n/write-marker raw top user') ||
  fs.existsSync(commandsFixtureCommandExecMarker) ||
  topLevelSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.content === '/send-user-message /write-marker raw top user') ||
  !topLevelSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'user' && entry.message?.content === '/write-marker raw top user') ||
  !topLevelSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'assistant')
) {
  throw new Error('top-level extension command sendUserMessage smoke did not run a raw slash-looking prompt');
}
const topLevelSendUserImageSession = path.join(commandsFixtureRoot, 'top-level-command-send-user-image-message.jsonl');
fs.rmSync(topLevelSendUserImageSession, { force: true });
const topLevelSendUserImageOutput = run(
  [
    '--session',
    topLevelSendUserImageSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-user-image-message top image user'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelSendUserImageEntries = fs.existsSync(topLevelSendUserImageSession)
  ? fs.readFileSync(topLevelSendUserImageSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
const topLevelSendUserImageUser = topLevelSendUserImageEntries.find((entry) => entry.type === 'message' && entry.message?.role === 'user');
if (
  !topLevelSendUserImageOutput.includes('pi-zig print-mode foundation accepted') ||
  !topLevelSendUserImageOutput.includes('Prompt:\ntop image user') ||
  fs.existsSync(commandsFixtureCommandExecMarker) ||
  topLevelSendUserImageEntries.some((entry) => entry.type === 'message' && entry.message?.content === '/send-user-image-message top image user') ||
  !Array.isArray(topLevelSendUserImageUser?.message?.content) ||
  !topLevelSendUserImageUser.message.content.some((part) => part?.type === 'text' && part.text === 'top image user') ||
  !topLevelSendUserImageUser.message.content.some((part) => part?.type === 'image' && part.data === 'aW1hZ2Utc21va2U=' && part.mimeType === 'image/png')
) {
  throw new Error('top-level extension command sendUserMessage image smoke did not persist image content');
}
fs.rmSync(commandsFixtureCommandExecMarker, { force: true });
const topLevelJsonSendUserSession = path.join(commandsFixtureRoot, 'top-level-command-json-send-user-message.jsonl');
fs.rmSync(topLevelJsonSendUserSession, { force: true });
const topLevelJsonSendUserOutput = run(
  [
    '--mode',
    'json',
    '--session',
    topLevelJsonSendUserSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-user-message /write-marker raw top json user'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelJsonSendUserLines = jsonLines(topLevelJsonSendUserOutput);
const topLevelJsonSendUserEntries = fs.existsSync(topLevelJsonSendUserSession)
  ? fs.readFileSync(topLevelJsonSendUserSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  !topLevelJsonSendUserLines.some((line) => line.type === 'agent_start') ||
  !topLevelJsonSendUserLines.some((line) => line.type === 'turn_end') ||
  !topLevelJsonSendUserLines.some((line) => line.type === 'agent_end') ||
  fs.existsSync(commandsFixtureCommandExecMarker) ||
  topLevelJsonSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.content === '/send-user-message /write-marker raw top json user') ||
  !topLevelJsonSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'user' && entry.message?.content === '/write-marker raw top json user') ||
  !topLevelJsonSendUserEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'assistant')
) {
  throw new Error('top-level JSON extension command sendUserMessage smoke did not run a raw slash-looking prompt');
}
const topLevelCustomMessageSession = path.join(commandsFixtureRoot, 'top-level-command-send-custom-message.jsonl');
fs.rmSync(topLevelCustomMessageSession, { force: true });
const topLevelCustomMessageOutput = run(
  [
    '--session',
    topLevelCustomMessageSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-custom-message top custom note'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelCustomMessageEntries = fs.existsSync(topLevelCustomMessageSession)
  ? fs.readFileSync(topLevelCustomMessageSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  topLevelCustomMessageOutput !== '' ||
  !topLevelCustomMessageEntries.some((entry) =>
    entry.type === 'custom_message' &&
    entry.customType === 'test-extension' &&
    entry.content === 'top custom note' &&
    entry.display === false
  ) ||
  topLevelCustomMessageEntries.some((entry) => entry.type === 'message')
) {
  throw new Error('top-level extension command sendMessage smoke did not persist custom_message without triggering a turn');
}
const topLevelTriggerMessageSession = path.join(commandsFixtureRoot, 'top-level-command-send-trigger-message.jsonl');
fs.rmSync(topLevelTriggerMessageSession, { force: true });
const topLevelTriggerMessageOutput = run(
  [
    '--session',
    topLevelTriggerMessageSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-trigger-message top triggered note'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelTriggerMessageEntries = fs.existsSync(topLevelTriggerMessageSession)
  ? fs.readFileSync(topLevelTriggerMessageSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  !topLevelTriggerMessageOutput.includes('pi-zig print-mode foundation accepted') ||
  !topLevelTriggerMessageOutput.includes('Prompt:\ntop triggered note') ||
  !topLevelTriggerMessageEntries.some((entry) =>
    entry.type === 'custom_message' &&
    entry.customType === 'test-extension' &&
    entry.content === 'top triggered note' &&
    entry.display === true
  ) ||
  topLevelTriggerMessageEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'user') ||
  !topLevelTriggerMessageEntries.some((entry) => entry.type === 'message' && entry.message?.role === 'assistant')
) {
  throw new Error('top-level extension command triggerTurn sendMessage smoke did not persist custom_message and run a prompt');
}
const topLevelNextTurnSession = path.join(commandsFixtureRoot, 'top-level-command-send-next-turn-message.jsonl');
fs.rmSync(topLevelNextTurnSession, { force: true });
const topLevelNextTurnFailure = runFail(
  [
    '--session',
    topLevelNextTurnSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/send-next-turn-message top queued custom note'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelNextTurnEntries = fs.existsSync(topLevelNextTurnSession)
  ? fs.readFileSync(topLevelNextTurnSession, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : [];
if (
  !(topLevelNextTurnFailure.stdout + topLevelNextTurnFailure.stderr).includes('UnsupportedCommandActionNextTurn') ||
  topLevelNextTurnEntries.some((entry) => entry.type === 'message' || entry.type === 'custom_message') ||
  topLevelNextTurnEntries.some((entry) => JSON.stringify(entry).includes('top queued custom note'))
) {
  throw new Error('top-level extension command sendMessage nextTurn smoke did not fail visibly without side effects');
}
const topLevelUnknownSlashSession = path.join(commandsFixtureRoot, 'top-level-unknown-slash.jsonl');
fs.rmSync(topLevelUnknownSlashSession, { force: true });
const topLevelUnknownSlashOutput = run(
  [
    '--session',
    topLevelUnknownSlashSession,
    '--extension',
    'extensions/command-exec.mjs',
    '-p',
    '/not-an-extension-command ordinary prompt'
  ],
  undefined,
  { cwd: commandsFixtureRoot, env: topLevelCommandEnv }
);
const topLevelUnknownSlashSessionText = fs.readFileSync(topLevelUnknownSlashSession, 'utf8');
if (
  !topLevelUnknownSlashOutput.includes('pi-zig print-mode foundation accepted') ||
  !topLevelUnknownSlashSessionText.includes('/not-an-extension-command ordinary prompt')
) {
  throw new Error('top-level unknown slash prompt should continue through the normal prompt path');
}

const packageCommandRoot = path.resolve('zig-out/pi-zig-package-command-fixture');
const packageCommandHome = path.join(packageCommandRoot, 'home');
const packageCommandProject = path.join(packageCommandRoot, 'project');
const packageCommandGlobalPackage = path.join(packageCommandProject, 'packages/global-local');
const packageCommandProjectPackage = path.join(packageCommandProject, 'packages/project-local');
const packageCommandFakeBin = path.join(packageCommandRoot, 'fake-bin');
const packageCommandRecord = path.join(packageCommandRoot, 'commands.jsonl');
const packageCommandGlobalPrefix = path.join(packageCommandRoot, 'global-prefix');
const packageCommandManagedPackageDir = path.join(
  packageCommandGlobalPrefix,
  'lib/node_modules/@earendil-works/pi-coding-agent'
);
const packageCommandManagedBin = path.join(packageCommandManagedPackageDir, 'bin/pi-zig');
const packageCommandGlobalBin = path.join(packageCommandGlobalPrefix, 'bin/pi-zig');
const packageCommandPnpmRoot = path.join(packageCommandRoot, 'pnpm/global/node_modules');
const packageCommandPnpmBin = path.join(packageCommandPnpmRoot, '@earendil-works/pi-coding-agent/bin/pi-zig');
const packageCommandYarnDir = path.join(packageCommandRoot, '.yarn/global');
const packageCommandYarnBin = path.join(packageCommandYarnDir, 'node_modules/@earendil-works/pi-coding-agent/bin/pi-zig');
const packageCommandBunRoot = path.join(packageCommandHome, '.bun/install/global/node_modules');
const packageCommandBunBin = path.join(packageCommandBunRoot, '@earendil-works/pi-coding-agent/bin/pi-zig');
const packageCommandEnv = {
  ...process.env,
  HOME: packageCommandHome,
  PATH: `${packageCommandFakeBin}${path.delimiter}${process.env.PATH ?? ''}`,
  PI_ZIG_FAKE_COMMAND_RECORD: packageCommandRecord,
  PI_ZIG_FAKE_GLOBAL_PREFIX: packageCommandGlobalPrefix,
  PI_ZIG_FAKE_PNPM_ROOT: packageCommandPnpmRoot,
  PI_ZIG_FAKE_YARN_DIR: packageCommandYarnDir,
  PI_ZIG_FAKE_LATEST_RESPONSE: JSON.stringify({ version: '0.1.0' })
};
function runPackageBinary(commandBin, args, input, options = {}) {
  return execFileSync(commandBin, args, { encoding: 'utf8', input, ...options });
}
function runPackageManaged(args, input, options = {}) {
  return runPackageBinary(packageCommandManagedBin, args, input, options);
}
function runPackageManagedFail(args, input, options = {}) {
  try {
    const stdout = execFileSync(packageCommandManagedBin, args, { encoding: 'utf8', input, ...options });
    throw new Error(`expected managed package command to fail but it succeeded: ${args.join(' ')}\n${stdout}`);
  } catch (error) {
    if (error.status === undefined) throw error;
    return {
      status: error.status,
      stdout: error.stdout ?? '',
      stderr: error.stderr ?? ''
    };
  }
}
function readPackageCommandRecords() {
  const text = fs.existsSync(packageCommandRecord) ? fs.readFileSync(packageCommandRecord, 'utf8').trim() : '';
  return text ? text.split('\n').map((line) => JSON.parse(line)) : [];
}
fs.rmSync(packageCommandRoot, { recursive: true, force: true });
fs.mkdirSync(packageCommandGlobalPackage, { recursive: true });
fs.mkdirSync(packageCommandProjectPackage, { recursive: true });
fs.mkdirSync(packageCommandFakeBin, { recursive: true });
fs.mkdirSync(path.dirname(packageCommandManagedBin), { recursive: true });
fs.mkdirSync(path.dirname(packageCommandGlobalBin), { recursive: true });
fs.writeFileSync(path.join(packageCommandManagedPackageDir, 'package.json'), JSON.stringify({ name: '@earendil-works/pi-coding-agent' }));
fs.copyFileSync(bin, packageCommandManagedBin);
fs.chmodSync(packageCommandManagedBin, 0o755);
fs.symlinkSync(packageCommandManagedBin, packageCommandGlobalBin);
for (const managedBin of [packageCommandPnpmBin, packageCommandYarnBin, packageCommandBunBin]) {
  fs.mkdirSync(path.dirname(managedBin), { recursive: true });
  fs.writeFileSync(path.join(path.dirname(path.dirname(managedBin)), 'package.json'), JSON.stringify({ name: '@earendil-works/pi-coding-agent' }));
  fs.copyFileSync(bin, managedBin);
  fs.chmodSync(managedBin, 0o755);
}
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'npm'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'npm', args, cwd: process.cwd() }) + '\\n');
function optionValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}
function packageName(spec) {
  const start = spec.startsWith('@') ? 1 : 0;
  const at = spec.lastIndexOf('@');
  return at > start ? spec.slice(0, at) : spec;
}
const root = optionValue('--prefix') || optionValue('--cwd') || process.cwd();
if (args[0] === 'root' && args[1] === '-g') {
  console.log(path.join(process.env.PI_ZIG_FAKE_GLOBAL_PREFIX, 'lib/node_modules'));
  process.exit(0);
}
if (args[0] === 'view' && args[2] === 'version') {
  const name = args[1];
  console.log(JSON.stringify(name === 'current-extension' ? '1.0.0' : '2.0.0'));
  process.exit(0);
}
const installIndex = args.indexOf('install');
if (installIndex >= 0) {
  fs.mkdirSync(path.join(root, 'node_modules'), { recursive: true });
  for (const spec of args.slice(installIndex + 1)) {
    if (spec.startsWith('--')) break;
    const name = packageName(spec);
    if (!name) continue;
    const packageDir = path.join(root, 'node_modules', ...name.split('/'));
    fs.mkdirSync(packageDir, { recursive: true });
    fs.writeFileSync(path.join(packageDir, 'package.json'), JSON.stringify({ name, version: spec.includes('@latest') ? 'latest' : '1.0.0' }));
  }
  process.exit(0);
}
const uninstallIndex = args.indexOf('uninstall');
if (uninstallIndex >= 0) {
  const name = args[uninstallIndex + 1];
  if (name) fs.rmSync(path.join(root, 'node_modules', ...name.split('/')), { recursive: true, force: true });
  process.exit(0);
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'npm'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'pnpm'),
  `#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'pnpm', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'root' && args[1] === '-g') {
  console.log(process.env.PI_ZIG_FAKE_PNPM_ROOT);
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'pnpm'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'yarn'),
  `#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'yarn', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'global' && args[1] === 'dir') {
  console.log(process.env.PI_ZIG_FAKE_YARN_DIR);
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'yarn'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'bun'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'bun', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'pm' && args[1] === 'bin' && args[2] === '-g') {
  console.log(path.join(process.env.HOME, '.bun/bin'));
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'bun'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'curl'),
  `#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'curl', args, cwd: process.cwd() }) + '\\n');
console.log(process.env.PI_ZIG_FAKE_LATEST_RESPONSE || JSON.stringify({ version: '0.1.0' }));
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'curl'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'git'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'git', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'clone') {
  const target = args[2];
  fs.mkdirSync(path.join(target, '.git'), { recursive: true });
  fs.writeFileSync(path.join(target, 'extension.js'), 'fake git extension');
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'git'), 0o755);
if (!run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv }).includes('No packages installed.')) {
  throw new Error('package list smoke did not report an empty package set');
}
const packageInstallHelp = run(['install', '--help'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (!packageInstallHelp.includes('pi-zig install <source> [-l]')) {
  throw new Error('package install help smoke did not print usage');
}
run(['install', './packages/global-local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['install', './packages/project-local', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const globalPackageSettingsPath = path.join(packageCommandHome, '.pi/agent/settings.json');
const projectPackageSettingsPath = path.join(packageCommandProject, '.pi/settings.json');
const globalPackageSettings = JSON.parse(fs.readFileSync(globalPackageSettingsPath, 'utf8'));
const projectPackageSettings = JSON.parse(fs.readFileSync(projectPackageSettingsPath, 'utf8'));
if (
  path.resolve(path.dirname(globalPackageSettingsPath), globalPackageSettings.packages?.[0] ?? '') !== packageCommandGlobalPackage ||
  path.resolve(path.dirname(projectPackageSettingsPath), projectPackageSettings.packages?.[0] ?? '') !== packageCommandProjectPackage
) {
  throw new Error('package install smoke did not persist local package paths relative to the selected settings file');
}
const packageList = run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  !packageList.includes('User packages:') ||
  !packageList.includes('Project packages:') ||
  !packageList.includes(packageCommandGlobalPackage) ||
  !packageList.includes(packageCommandProjectPackage)
) {
  throw new Error('package list smoke did not show user and project local packages with installed paths');
}
run(['remove', `${packageCommandGlobalPackage}/`], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['uninstall', './packages/project-local', '-l'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  (JSON.parse(fs.readFileSync(globalPackageSettingsPath, 'utf8')).packages ?? []).length !== 0 ||
  (JSON.parse(fs.readFileSync(projectPackageSettingsPath, 'utf8')).packages ?? []).length !== 0
) {
  throw new Error('package remove smoke did not clear matching user and project packages');
}

run(['install', 'npm:fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['install', 'npm:current-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['install', 'git:github.com/example/fake-extension', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const npmInstallPath = path.join(packageCommandHome, '.pi/agent/npm/node_modules/fake-extension/package.json');
const currentNpmInstallPath = path.join(packageCommandHome, '.pi/agent/npm/node_modules/current-extension/package.json');
const gitInstallPath = path.join(packageCommandProject, '.pi/git/github.com/example/fake-extension/extension.js');
if (!fs.existsSync(npmInstallPath) || !fs.existsSync(currentNpmInstallPath) || !fs.existsSync(gitInstallPath)) {
  throw new Error('package npm/git install smoke did not create managed install paths');
}
const packageUpdateSuggestion = runFail(['update', 'fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  packageUpdateSuggestion.status !== 1 ||
  !packageUpdateSuggestion.stderr.includes('No matching package found for fake-extension. Did you mean npm:fake-extension?')
) {
  throw new Error('package update smoke did not suggest configured npm: source for shorthand input');
}
const packageManagedList = run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  !packageManagedList.includes(path.join(packageCommandHome, '.pi/agent/npm/node_modules/fake-extension')) ||
  !packageManagedList.includes(path.join(packageCommandProject, '.pi/git/github.com/example/fake-extension'))
) {
  throw new Error('package list smoke did not show managed npm and git install paths');
}
run(['update', '--extension', 'git:github.com/example/fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['update', '--extensions'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const packageCommandRecords = readPackageCommandRecords();
if (
  !packageCommandRecords.some((record) => record.command === 'npm' && record.args.includes('fake-extension@latest')) ||
  packageCommandRecords.some((record) => record.command === 'npm' && record.args.includes('current-extension@latest')) ||
  !packageCommandRecords.some((record) => record.command === 'npm' && record.args.includes('view') && record.args.includes('fake-extension')) ||
  !packageCommandRecords.some((record) => record.command === 'npm' && record.args.includes('view') && record.args.includes('current-extension')) ||
  !packageCommandRecords.some((record) => record.command === 'git' && record.args[0] === 'fetch') ||
  !packageCommandRecords.some((record) => record.command === 'git' && record.args[0] === 'reset')
) {
  throw new Error('package update smoke did not check npm versions, update stale npm packages, and run git reconciliation commands');
}
run(['remove', 'npm:fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['remove', 'npm:current-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['remove', 'git:github.com/example/fake-extension', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (fs.existsSync(npmInstallPath) || fs.existsSync(currentNpmInstallPath) || fs.existsSync(gitInstallPath)) {
  throw new Error('package remove smoke did not remove managed npm and git installs');
}
const packageSelfUnsupported = runFail(['update', '--self', '--force'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  packageSelfUnsupported.status !== 1 ||
  !packageSelfUnsupported.stderr.includes('cannot self-update this installation') ||
  !packageSelfUnsupported.stderr.includes('Location of pi-zig executable:')
) {
  throw new Error('package self-update smoke did not fail visibly for unmanaged checkout binary');
}
const packageSelfNoUpdateRecordCount = readPackageCommandRecords().length;
const packageSelfNoUpdateOutput = runPackageManaged(['update', '--self'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const packageSelfNoUpdateRecords = readPackageCommandRecords().slice(packageSelfNoUpdateRecordCount);
if (
  !packageSelfNoUpdateOutput.includes('pi-zig is already up to date (v0.1.0)') ||
  !packageSelfNoUpdateRecords.some((record) => record.command === 'curl' && record.args.includes('https://pi.dev/api/latest-version')) ||
  packageSelfNoUpdateRecords.some((record) => record.command === 'npm' && record.args.includes('-g'))
) {
  throw new Error('package self-update smoke did not check latest release and skip current version');
}
fs.chmodSync(packageCommandManagedPackageDir, 0o555);
const packageSelfUnwritable = runPackageManagedFail(['update', '--self', '--force'], undefined, {
  cwd: packageCommandProject,
  env: packageCommandEnv
});
fs.chmodSync(packageCommandManagedPackageDir, 0o755);
if (
  packageSelfUnwritable.status !== 1 ||
  !packageSelfUnwritable.stderr.includes('managed by a global npm install') ||
  !packageSelfUnwritable.stderr.includes('install path is not writable')
) {
  throw new Error('package self-update smoke did not reject managed but unwritable install paths');
}
const packageSelfForceRecordCount = readPackageCommandRecords().length;
const packageSelfUpdateOutput = runPackageManaged(['update', '--self', '--force'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const packageSelfUpdateRecords = readPackageCommandRecords().slice(packageSelfForceRecordCount);
if (
  !packageSelfUpdateOutput.includes('Updated pi-zig') ||
  packageSelfUpdateRecords.some((record) => record.command === 'curl') ||
  !packageSelfUpdateRecords.some((record) => record.command === 'npm' && record.args[0] === 'root' && record.args[1] === '-g') ||
  !packageSelfUpdateRecords.some((record) =>
    record.command === 'npm' &&
    record.args.includes('install') &&
    record.args.includes('-g') &&
    record.args.includes('--ignore-scripts') &&
    record.args.includes('@earendil-works/pi-coding-agent')
  )
) {
  throw new Error('package self-update smoke did not run upstream-shaped package-manager command');
}
const packageSelfSymlinkRecordCount = readPackageCommandRecords().length;
const packageSelfSymlinkOutput = runPackageBinary(packageCommandGlobalBin, ['update', '--self', '--force'], undefined, {
  cwd: packageCommandProject,
  env: packageCommandEnv
});
const packageSelfSymlinkRecords = readPackageCommandRecords().slice(packageSelfSymlinkRecordCount);
if (
  !packageSelfSymlinkOutput.includes('Updated pi-zig') ||
  !packageSelfSymlinkRecords.some((record) => record.command === 'npm' && record.args[0] === 'root' && record.args[1] === '-g') ||
  !packageSelfSymlinkRecords.some((record) =>
    record.command === 'npm' &&
    record.args.includes('install') &&
    record.args.includes('-g') &&
    record.args.includes('--ignore-scripts') &&
    record.args.includes('@earendil-works/pi-coding-agent')
  )
) {
  throw new Error('package self-update smoke did not follow a global bin symlink back to the managed npm package');
}
for (const [manager, managedBin, rootArgs, installArgs] of [
  ['pnpm', packageCommandPnpmBin, ['root', '-g'], ['install', '-g', '--ignore-scripts', '@earendil-works/pi-coding-agent']],
  ['yarn', packageCommandYarnBin, ['global', 'dir'], ['global', 'add', '--ignore-scripts', '@earendil-works/pi-coding-agent']],
  ['bun', packageCommandBunBin, ['pm', 'bin', '-g'], ['install', '-g', '--ignore-scripts', '@earendil-works/pi-coding-agent']]
]) {
  const recordCount = readPackageCommandRecords().length;
  const output = runPackageBinary(managedBin, ['update', '--self', '--force'], undefined, {
    cwd: packageCommandProject,
    env: packageCommandEnv
  });
  const records = readPackageCommandRecords().slice(recordCount);
  if (
    !output.includes('Updated pi-zig') ||
    !records.some((record) => record.command === manager && rootArgs.every((arg, index) => record.args[index] === arg)) ||
    !records.some((record) => record.command === manager && installArgs.every((arg) => record.args.includes(arg)))
  ) {
    throw new Error(`package self-update smoke did not validate ${manager} global install detection and command shape`);
  }
}

const authFixtureRoot = path.resolve('zig-out/pi-zig-auth-fixture');
const authFixtureHome = path.join(authFixtureRoot, 'home');
const authFixtureEnv = {
  ...process.env,
  HOME: authFixtureHome,
  OPENAI_API_KEY: 'env-openai-key'
};
fs.rmSync(authFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(authFixtureHome, { recursive: true });
const emptyAuthList = JSON.parse(run(['auth', 'list', '--json'], undefined, { env: authFixtureEnv }));
if (emptyAuthList.providers.length !== 0) {
  throw new Error('auth list smoke did not start with an empty auth store');
}
const authProviders = JSON.parse(run(['auth', 'providers', '--json'], undefined, { env: authFixtureEnv }));
if (
  !authProviders.providers.some((provider) => provider.id === 'anthropic') ||
  !authProviders.providers.some((provider) => provider.id === 'github-copilot') ||
  !authProviders.providers.some((provider) => provider.id === 'openai-codex')
) {
  throw new Error('auth providers smoke did not expose upstream built-in OAuth providers');
}
const envOpenAiStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (envOpenAiStatus.hasAuth !== true || envOpenAiStatus.source !== 'environment' || envOpenAiStatus.label !== 'OPENAI_API_KEY') {
  throw new Error('auth status smoke did not report provider environment fallback');
}
run(['auth', 'set-api-key', 'openai', '!printf command-openai-key'], undefined, { env: authFixtureEnv });
const storedOpenAiStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (storedOpenAiStatus.configured !== true || storedOpenAiStatus.source !== 'stored' || storedOpenAiStatus.type !== 'api_key') {
  throw new Error('auth status smoke did not report stored API key credential');
}
const resolvedOpenAi = JSON.parse(run(['auth', 'resolve', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (resolvedOpenAi.value !== 'command-openai-key') {
  throw new Error('auth resolve smoke did not execute ! command API key');
}
run(['auth', 'set-api-key', 'groq', 'GROQ_API_KEY'], undefined, { env: { ...authFixtureEnv, GROQ_API_KEY: 'env-groq-key' } });
const resolvedGroq = JSON.parse(run(['auth', 'resolve', 'groq', '--json'], undefined, { env: { ...authFixtureEnv, GROQ_API_KEY: 'env-groq-key' } }));
if (resolvedGroq.value !== 'env-groq-key') {
  throw new Error('auth resolve smoke did not resolve stored env-var API key');
}
run(['auth', 'set-oauth', 'openai-codex', 'oauth-access', 'oauth-refresh', '4102444800000'], undefined, { env: authFixtureEnv });
const oauthOpenAiCodex = JSON.parse(run(['auth', 'resolve', 'openai-codex', '--json'], undefined, { env: authFixtureEnv }));
if (oauthOpenAiCodex.value !== 'oauth-access') {
  throw new Error('auth resolve smoke did not return unexpired OAuth access token');
}
run(['auth', 'set-oauth', 'anthropic', 'expired-access', 'expired-refresh', '1'], undefined, { env: authFixtureEnv });
const expiredAnthropic = run(['auth', 'resolve', 'anthropic', '--json'], undefined, { env: authFixtureEnv });
if (!expiredAnthropic.includes('"resolved":false') || !expiredAnthropic.includes('"value":null')) {
  throw new Error('auth resolve smoke did not fail visibly for expired OAuth refresh gap');
}
run(['auth', 'remove', 'openai'], undefined, { env: authFixtureEnv });
const postRemoveAuthStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (postRemoveAuthStatus.source !== 'environment' || postRemoveAuthStatus.configured !== false) {
  throw new Error('auth remove smoke did not remove stored credential and reveal env fallback');
}

const extensionsFixtureRoot = path.resolve('zig-out/pi-zig-extensions-fixture');
const extensionsFixtureHome = path.join(extensionsFixtureRoot, 'home');
const extensionsFixtureProject = path.join(extensionsFixtureRoot, 'project');
const extensionsFixtureEnv = { ...process.env, HOME: extensionsFixtureHome };
fs.rmSync(extensionsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/src'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'packages/ext-package'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'packages/disabled-package/extensions'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'explicit-package'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureHome, '.pi/agent/extensions'), { recursive: true });
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/direct.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/module.mjs'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/drop.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index/index.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index/index.js'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/src/main.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/package.json'), JSON.stringify({ pi: { extensions: ['./src/main.ts', './missing.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/settings-ext.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/settings.json'), JSON.stringify({
  extensions: ['./settings-ext.ts', '!drop.ts'],
  packages: [
    { source: '../packages/ext-package', extensions: ['entry.ts'] },
    { source: '../packages/disabled-package', extensions: [] }
  ]
}, null, 2));
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/ext-package/package.json'), JSON.stringify({ pi: { extensions: ['./entry.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/ext-package/entry.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/disabled-package/extensions/disabled.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, 'explicit-package/package.json'), JSON.stringify({ pi: { extensions: ['./custom.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, 'explicit-package/custom.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/global-settings.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureHome, 'home-explicit.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/settings.json'), JSON.stringify({ extensions: ['./global-settings.ts', '~/home-explicit.ts'] }, null, 2));
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/extensions/global.ts'), 'export default function(){}');
const extensions = JSON.parse(run(
  ['extensions', '--json', '--extension', './explicit-package'],
  undefined,
  { cwd: extensionsFixtureProject, env: extensionsFixtureEnv }
)).extensions;
function extensionEntry(suffix, predicate = () => true) {
  return extensions.find((entry) => entry.path.endsWith(suffix) && predicate(entry));
}
if (
  !extensionEntry('/.pi/settings-ext.ts', (entry) => entry.sourceInfo.source === 'local' && entry.sourceInfo.scope === 'project') ||
  !extensionEntry('/.pi/extensions/direct.ts', (entry) => entry.enabled === true && entry.sourceInfo.source === 'auto') ||
  !extensionEntry('/.pi/extensions/module.mjs', (entry) => entry.enabled === true && entry.sourceInfo.source === 'auto') ||
  !extensionEntry('/.pi/extensions/drop.ts', (entry) => entry.enabled === false) ||
  !extensionEntry('/.pi/extensions/prefer-index/index.ts') ||
  extensionEntry('/.pi/extensions/prefer-index/index.js') ||
  !extensionEntry('/.pi/extensions/manifest/src/main.ts') ||
  !extensionEntry('/.pi/agent/global-settings.ts', (entry) => entry.sourceInfo.source === 'local' && entry.sourceInfo.scope === 'user') ||
  !extensionEntry('/home-explicit.ts', (entry) => entry.sourceInfo.source === 'local' && entry.sourceInfo.scope === 'user') ||
  !extensionEntry('/.pi/agent/extensions/global.ts', (entry) => entry.sourceInfo.source === 'auto' && entry.sourceInfo.scope === 'user') ||
  !extensionEntry('/packages/ext-package/entry.ts', (entry) => entry.sourceInfo.origin === 'package') ||
  !extensionEntry('/packages/disabled-package/extensions/disabled.ts', (entry) => entry.enabled === false) ||
  !extensionEntry('/explicit-package/custom.ts', (entry) => entry.sourceInfo.source === 'cli' && entry.sourceInfo.scope === 'temporary')
) {
  throw new Error('extensions smoke did not match upstream discovery order, manifests, settings, package filters, and explicit paths');
}
const explicitOnlyExtensions = JSON.parse(run(
  ['extensions', '--json', '--no-extensions', '--extension', './explicit-package'],
  undefined,
  { cwd: extensionsFixtureProject, env: extensionsFixtureEnv }
)).extensions;
if (explicitOnlyExtensions.length !== 1 || !explicitOnlyExtensions[0].path.endsWith('/explicit-package/custom.ts')) {
  throw new Error('extensions --no-extensions smoke did not keep explicit extension paths only');
}

const settingsFixtureRoot = path.resolve('zig-out/pi-zig-settings-fixture');
const settingsFixtureHome = path.join(settingsFixtureRoot, 'home');
const settingsFixtureProject = path.join(settingsFixtureRoot, 'project');
const settingsFixtureNoPiProject = path.join(settingsFixtureRoot, 'no-pi-project');
const settingsFixtureEnv = { ...process.env, HOME: settingsFixtureHome };
fs.rmSync(settingsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(settingsFixtureHome, '.pi/agent'), { recursive: true });
fs.mkdirSync(path.join(settingsFixtureProject, '.pi'), { recursive: true });
fs.mkdirSync(settingsFixtureNoPiProject, { recursive: true });
fs.writeFileSync(
  path.join(settingsFixtureHome, '.pi/agent/settings.json'),
  JSON.stringify({
    queueMode: 'all',
    websockets: false,
    skills: {
      enableSkillCommands: false,
      customDirectories: ['legacy-skills']
    },
    retry: {
      maxDelayMs: 1234,
      maxRetries: 4
    },
    compaction: {
      reserveTokens: 111
    },
    shellCommandPrefix: 'export PI_ZIG_PREFIX=global-prefix',
    enabledModels: ['claude-opus-4-5', 'gpt-5.2-codex'],
    httpIdleTimeoutMs: 'disabled',
    sessionDir: '~/sessions'
  }, null, 2)
);
fs.writeFileSync(
  path.join(settingsFixtureProject, '.pi/settings.json'),
  JSON.stringify({
    websockets: true,
    theme: 'dark',
    compaction: {
      keepRecentTokens: 222
    },
    branchSummary: {
      skipPrompt: true
    },
    shellPath: '~/custom-shell',
    shellCommandPrefix: 'export PI_ZIG_PREFIX=project-prefix'
  }, null, 2)
);
const settingsReport = JSON.parse(run(['settings', '--json'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv }));
if (
  settingsReport.globalSettings.queueMode !== undefined ||
  settingsReport.globalSettings.websockets !== undefined ||
  settingsReport.globalSettings.steeringMode !== 'all' ||
  settingsReport.globalSettings.transport !== 'sse' ||
  settingsReport.globalSettings.enableSkillCommands !== false ||
  settingsReport.globalSettings.skills?.[0] !== 'legacy-skills' ||
  settingsReport.globalSettings.retry?.maxDelayMs !== undefined ||
  settingsReport.globalSettings.retry?.provider?.maxRetryDelayMs !== 1234 ||
  settingsReport.settings.transport !== 'websocket' ||
  settingsReport.settings.compaction?.reserveTokens !== 111 ||
  settingsReport.settings.compaction?.keepRecentTokens !== 222 ||
  settingsReport.resolved.followUpMode !== 'one-at-a-time' ||
  settingsReport.resolved.compaction?.enabled !== true ||
  settingsReport.resolved.retry?.maxRetries !== 4 ||
  settingsReport.resolved.retry?.baseDelayMs !== 2000 ||
  settingsReport.resolved.retry?.provider?.maxRetryDelayMs !== 1234 ||
  settingsReport.resolved.branchSummary?.skipPrompt !== true ||
  settingsReport.resolved.httpIdleTimeoutMs !== 0 ||
  settingsReport.resolved.shellPath !== path.join(settingsFixtureHome, 'custom-shell') ||
  settingsReport.resolved.shellCommandPrefix !== 'export PI_ZIG_PREFIX=project-prefix' ||
  settingsReport.resolved.sessionDir !== path.join(settingsFixtureHome, 'sessions') ||
  settingsReport.resolved.enableSkillCommands !== false
) {
  throw new Error('settings smoke did not migrate, merge, and resolve upstream settings defaults');
}
const settingsGet = JSON.parse(run(['settings', 'get', 'resolved.compaction.keepRecentTokens'], undefined, {
  cwd: settingsFixtureProject,
  env: settingsFixtureEnv
}));
if (settingsGet !== 222) {
  throw new Error('settings get smoke did not read a resolved dotted value');
}
run(['settings', 'set-model', 'openai', 'gpt-4o'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv });
const settingsGlobalAfterModel = JSON.parse(fs.readFileSync(path.join(settingsFixtureHome, '.pi/agent/settings.json'), 'utf8'));
if (
  settingsGlobalAfterModel.defaultProvider !== 'openai' ||
  settingsGlobalAfterModel.defaultModel !== 'gpt-4o' ||
  settingsGlobalAfterModel.enabledModels?.[1] !== 'gpt-5.2-codex'
) {
  throw new Error('settings set-model smoke did not preserve unrelated global settings');
}
run(['settings', 'set', 'theme', 'light', '--local'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv });
const settingsProjectAfterTheme = JSON.parse(fs.readFileSync(path.join(settingsFixtureProject, '.pi/settings.json'), 'utf8'));
if (settingsProjectAfterTheme.theme !== 'light' || settingsProjectAfterTheme.compaction?.keepRecentTokens !== 222) {
  throw new Error('settings set --local smoke did not preserve unrelated project settings');
}
run(['settings', '--json'], undefined, { cwd: settingsFixtureNoPiProject, env: settingsFixtureEnv });
if (fs.existsSync(path.join(settingsFixtureNoPiProject, '.pi'))) {
  throw new Error('settings read smoke created a project .pi directory');
}
const invalidSettingsHome = path.join(settingsFixtureRoot, 'invalid-home');
fs.mkdirSync(path.join(invalidSettingsHome, '.pi/agent'), { recursive: true });
fs.writeFileSync(path.join(invalidSettingsHome, '.pi/agent/settings.json'), '{ invalid json');
const invalidRead = JSON.parse(run(['settings', '--json'], undefined, {
  cwd: settingsFixtureProject,
  env: { ...process.env, HOME: invalidSettingsHome }
}));
if (!invalidRead.errors.some((error) => error.scope === 'global')) {
  throw new Error('settings invalid-read smoke did not report a global load error');
}
const invalidWrite = runFail(['settings', 'set', 'theme', 'dark'], undefined, {
  cwd: settingsFixtureProject,
  env: { ...process.env, HOME: invalidSettingsHome }
});
if (invalidWrite.status === 0 || !invalidWrite.stderr.includes('Refusing to overwrite invalid settings file')) {
  throw new Error('settings invalid-write smoke did not refuse to overwrite invalid JSON');
}

const themeFixtureRoot = path.resolve('zig-out/pi-zig-theme-fixture');
const themeFixtureHome = path.join(themeFixtureRoot, 'home');
const themeFixtureEnv = { ...process.env, HOME: themeFixtureHome };
fs.rmSync(themeFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(themeFixtureRoot, '.pi/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, '.pi/settings-themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureHome, '.pi/agent/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'explicit-themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-disabled/themes'), { recursive: true });
const darkTheme = JSON.parse(fs.readFileSync('src/pi/themes/dark.json', 'utf8'));
const userNamedTheme = { ...darkTheme, name: 'bar' };
const settingsNamedTheme = { ...darkTheme, name: 'settings-theme' };
const explicitTheme = { ...darkTheme, name: 'explicit-theme' };
const packageNiceTheme = { ...darkTheme, name: 'package-nice' };
const packageUglyTheme = { ...darkTheme, name: 'package-ugly' };
const packageManifestTheme = { ...darkTheme, name: 'package-manifest' };
const packageDropTheme = { ...darkTheme, name: 'package-drop' };
const packageDisabledTheme = { ...darkTheme, name: 'package-disabled' };
const recursiveExportTheme = {
  ...darkTheme,
  name: 'custom-export-recursive',
  vars: {
    ...(darkTheme.vars ?? {}),
    deepPageBg: '#abcdef',
    pageBgAlias: 'deepPageBg',
    cardBgAnsi: 24
  },
  export: {
    pageBg: 'pageBgAlias',
    cardBg: 'cardBgAnsi',
    infoBg: ''
  }
};
fs.writeFileSync(path.join(themeFixtureHome, '.pi/agent/themes/foo.json'), JSON.stringify(userNamedTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, '.pi/settings-themes/settings.json'), JSON.stringify(settingsNamedTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, '.pi/themes/custom-export-recursive.json'), JSON.stringify(recursiveExportTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'explicit-themes/explicit.json'), JSON.stringify(explicitTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes/nice.json'), JSON.stringify(packageNiceTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes/ugly.json'), JSON.stringify(packageUglyTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes/manifest.json'), JSON.stringify(packageManifestTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes/drop.json'), JSON.stringify(packageDropTheme, null, 2));
fs.writeFileSync(
  path.join(themeFixtureRoot, 'packages/theme-manifest/package.json'),
  JSON.stringify({ name: 'theme-manifest', pi: { themes: ['themes/*.json', '!themes/drop.json'] } }, null, 2)
);
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-disabled/themes/disabled.json'), JSON.stringify(packageDisabledTheme, null, 2));
fs.writeFileSync(
  path.join(themeFixtureRoot, '.pi/settings.json'),
  JSON.stringify({
    themes: ['settings-themes'],
    packages: [
      { source: '../packages/theme-convention', themes: ['!ugly.json'] },
      '../packages/theme-manifest',
      { source: '../packages/theme-disabled', themes: [] }
    ]
  }, null, 2)
);
const themes = JSON.parse(run(['themes', '--theme', 'explicit-themes'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (
  !themes.themes.some((theme) => theme.name === 'dark' && theme.source === 'builtin') ||
  !themes.themes.some((theme) => theme.name === 'bar' && theme.source === 'user') ||
  themes.themes.some((theme) => theme.name === 'foo') ||
  !themes.themes.some((theme) => theme.name === 'settings-theme' && theme.source === 'project') ||
  !themes.themes.some((theme) => theme.name === 'package-nice' && theme.source === 'package') ||
  themes.themes.some((theme) => theme.name === 'package-ugly') ||
  !themes.themes.some((theme) => theme.name === 'package-manifest' && theme.source === 'package') ||
  themes.themes.some((theme) => theme.name === 'package-drop') ||
  themes.themes.some((theme) => theme.name === 'package-disabled') ||
  !themes.themes.some((theme) => theme.name === 'explicit-theme' && theme.source === 'temporary')
) {
  throw new Error('themes smoke did not discover builtin, content-named custom, settings, package, and temporary themes with filters');
}
const noThemes = JSON.parse(run(['themes', '--no-themes'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (noThemes.themes.some((theme) => theme.name === 'bar' || theme.name === 'settings-theme')) {
  throw new Error('themes --no-themes smoke did not suppress user/project theme discovery');
}
const themeExport = JSON.parse(run(['themes', '--export', 'custom-export-recursive'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (
  themeExport.export.pageBg !== '#abcdef' ||
  themeExport.export.cardBg !== '#005f87' ||
  Object.prototype.hasOwnProperty.call(themeExport.export, 'infoBg')
) {
  throw new Error('themes export smoke did not resolve recursive variables, ANSI colors, and empty values');
}
const resolvedLight = JSON.parse(run(['themes', '--resolved', 'light'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (resolvedLight.colors.accent !== '#5a8080' || resolvedLight.colors.text !== '#1f2328') {
  throw new Error('themes resolved smoke did not expose built-in light colors as hex values');
}
const detectedLight = JSON.parse(run(['themes', '--detect'], undefined, {
  cwd: themeFixtureRoot,
  env: { ...themeFixtureEnv, COLORFGBG: '0;7;15' }
}));
const detectedDark = JSON.parse(run(['themes', '--detect'], undefined, {
  cwd: themeFixtureRoot,
  env: { ...themeFixtureEnv, COLORFGBG: '15;0' }
}));
if (detectedLight.theme !== 'light' || detectedLight.source !== 'COLORFGBG' || detectedDark.theme !== 'dark') {
  throw new Error('themes detect smoke did not classify COLORFGBG background colors');
}

const contextFixtureRoot = path.resolve('zig-out/pi-zig-context-fixture');
const contextFixtureHome = path.join(contextFixtureRoot, 'home');
const contextFixtureChild = path.join(contextFixtureRoot, 'workspace/parent/child');
const contextFixtureEnv = { ...process.env, HOME: contextFixtureHome };
fs.rmSync(contextFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(contextFixtureHome, '.pi/agent'), { recursive: true });
fs.mkdirSync(path.join(contextFixtureChild, '.pi'), { recursive: true });
fs.mkdirSync(path.join(contextFixtureRoot, 'workspace'), { recursive: true });
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/AGENTS.md'), '# Global Agent\n\nUse global instructions.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/CLAUDE.md'), '# Global Claude\n\nThis should lose to AGENTS.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/SYSTEM.md'), 'Global system prompt.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/APPEND_SYSTEM.md'), 'Global append prompt.');
fs.writeFileSync(path.join(contextFixtureRoot, 'AGENTS.md'), '# Fixture Root\n\nUse root project instructions.');
fs.writeFileSync(path.join(contextFixtureRoot, 'workspace/CLAUDE.md'), '# Workspace Claude\n\nUse workspace instructions.');
fs.writeFileSync(path.join(contextFixtureChild, 'AGENTS.md'), '# Child Agent\n\nUse child instructions.');
fs.writeFileSync(path.join(contextFixtureChild, 'CLAUDE.md'), '# Child Claude\n\nThis should lose to AGENTS.');
fs.writeFileSync(path.join(contextFixtureChild, '.pi/SYSTEM.md'), 'Project system prompt.');
fs.writeFileSync(path.join(contextFixtureChild, '.pi/APPEND_SYSTEM.md'), 'Project append prompt.');
const contextFiles = JSON.parse(run(['context-files'], undefined, { cwd: contextFixtureChild, env: contextFixtureEnv }));
if (
  contextFiles.contextFilesEnabled !== true ||
  contextFiles.contextFiles.length !== 4 ||
  !contextFiles.contextFiles[0].path.endsWith('home/.pi/agent/AGENTS.md') ||
  !contextFiles.contextFiles[1].path.endsWith('pi-zig-context-fixture/AGENTS.md') ||
  !contextFiles.contextFiles[2].path.endsWith('workspace/CLAUDE.md') ||
  !contextFiles.contextFiles[3].path.endsWith('workspace/parent/child/AGENTS.md') ||
  contextFiles.contextFiles.some((file) => file.content.includes('should lose to AGENTS')) ||
  contextFiles.systemPrompt?.content !== 'Project system prompt.' ||
  !contextFiles.systemPrompt?.path.endsWith('workspace/parent/child/.pi/SYSTEM.md') ||
  contextFiles.appendSystemPrompt?.content !== 'Project append prompt.'
) {
  throw new Error('context-files smoke did not match upstream AGENTS/CLAUDE ordering and project system prompt discovery');
}
const noContextFiles = JSON.parse(run(['context-files', '--no-context-files'], undefined, { cwd: contextFixtureChild, env: contextFixtureEnv }));
if (
  noContextFiles.contextFilesEnabled !== false ||
  noContextFiles.contextFiles.length !== 0 ||
  noContextFiles.systemPrompt?.content !== 'Project system prompt.' ||
  noContextFiles.appendSystemPrompt?.content !== 'Project append prompt.'
) {
  throw new Error('context-files --no-context-files smoke suppressed system prompt discovery or kept context files');
}
const contextFallbackCwd = path.join(contextFixtureRoot, 'fallback-project');
fs.mkdirSync(contextFallbackCwd, { recursive: true });
const contextFallback = JSON.parse(run(['context-files', '--no-context-files'], undefined, { cwd: contextFallbackCwd, env: contextFixtureEnv }));
if (
  contextFallback.systemPrompt?.content !== 'Global system prompt.' ||
  !contextFallback.systemPrompt?.path.endsWith('home/.pi/agent/SYSTEM.md') ||
  contextFallback.appendSystemPrompt?.content !== 'Global append prompt.'
) {
  throw new Error('context-files smoke did not fall back to global system prompt files');
}
const upstreamCodingAgentPackageDir = path.resolve('upstream/pi/packages/coding-agent');
const systemPrompt = JSON.parse(run(
  [
    'system-prompt',
    '--json',
    '--date',
    '2026-05-26',
    '--package-dir',
    upstreamCodingAgentPackageDir,
    '--guideline',
    'Use dynamic_tool for summaries.',
    '--guideline',
    '  Use dynamic_tool for summaries.  '
  ],
  undefined,
  { cwd: contextFixtureChild, env: contextFixtureEnv }
));
if (
  systemPrompt.contextFileCount !== 4 ||
  systemPrompt.hasSystemPrompt !== true ||
  systemPrompt.hasAppendSystemPrompt !== true ||
  !systemPrompt.prompt.startsWith('Project system prompt.\n\nProject append prompt.') ||
  !systemPrompt.prompt.includes('<project_context>') ||
  !systemPrompt.prompt.includes('home/.pi/agent/AGENTS.md') ||
  !systemPrompt.prompt.includes('Use root project instructions.') ||
  !systemPrompt.prompt.includes('Use workspace instructions.') ||
  !systemPrompt.prompt.includes('Use child instructions.') ||
  systemPrompt.prompt.includes('should lose to AGENTS') ||
  !systemPrompt.prompt.includes('Current date: 2026-05-26') ||
  !systemPrompt.prompt.includes(`Current working directory: ${contextFixtureChild}`)
) {
  throw new Error('system-prompt smoke did not assemble custom system prompt, append text, context files, date, and cwd');
}
const defaultSystemPrompt = JSON.parse(run(
  ['system-prompt', '--json', '--date', '2026-05-26', '--package-dir', upstreamCodingAgentPackageDir, '--no-context-files', '--no-tools'],
  undefined,
  { cwd: contextFallbackCwd, env: { ...contextFixtureEnv, PI_CODING_AGENT_DIR: path.join(contextFixtureRoot, 'empty-agent') } }
));
if (
  !defaultSystemPrompt.prompt.includes('Available tools:\n(none)') ||
  !defaultSystemPrompt.prompt.includes(`Main documentation: ${upstreamCodingAgentPackageDir}/README.md`) ||
  !defaultSystemPrompt.prompt.includes('Show file paths clearly when working with files') ||
  !defaultSystemPrompt.prompt.includes('Current date: 2026-05-26') ||
  defaultSystemPrompt.contextFileCount !== 0 ||
  defaultSystemPrompt.hasSystemPrompt !== false
) {
  throw new Error('system-prompt default smoke did not match upstream empty-tools/default-docs behavior');
}
const guidelineSystemPrompt = JSON.parse(run(
  [
    'system-prompt',
    '--json',
    '--date',
    '2026-05-26',
    '--package-dir',
    upstreamCodingAgentPackageDir,
    '--no-context-files',
    '--tools',
    'read,dynamic_tool',
    '--guideline',
    'Use dynamic_tool for summaries.',
    '--guideline',
    '  Use dynamic_tool for summaries.  '
  ],
  undefined,
  { cwd: contextFallbackCwd, env: { ...contextFixtureEnv, PI_CODING_AGENT_DIR: path.join(contextFixtureRoot, 'empty-agent') } }
));
if (
  !guidelineSystemPrompt.prompt.includes('- read: Read file contents') ||
  guidelineSystemPrompt.prompt.includes('dynamic_tool:') ||
  (guidelineSystemPrompt.prompt.match(/- Use dynamic_tool for summaries\./g) ?? []).length !== 1
) {
  throw new Error('system-prompt guideline smoke did not include read metadata, omit unsnippeted custom tools, and dedupe guidelines');
}

const anthropicEnv = JSON.parse(run(['provider-env', 'anthropic']));
if (!anthropicEnv.envKeys.includes('ANTHROPIC_OAUTH_TOKEN') || !anthropicEnv.envKeys.includes('ANTHROPIC_API_KEY')) {
  throw new Error('provider-env smoke missing anthropic env keys');
}

const providers = JSON.parse(run(['providers']));
if (providers.providers.length !== 32 || !providers.providers.includes('anthropic') || !providers.providers.includes('openai')) {
  throw new Error('providers smoke did not expose full upstream model provider list');
}

const modelCatalog = JSON.parse(run(['models']));
if (
  modelCatalog.totalModels !== 924 ||
  modelCatalog.providers.length !== 32 ||
  !modelCatalog.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('models smoke did not expose full upstream generated catalog');
}

const anthropicModels = JSON.parse(run(['models-for', 'anthropic']));
if (!anthropicModels.models.some((model) => model.id === 'claude-haiku-4-5')) {
  throw new Error('models-for smoke did not include anthropic claude-haiku-4-5');
}

const haiku = JSON.parse(run(['model', 'anthropic', 'claude-haiku-4-5']));
if (
  haiku.provider !== 'anthropic' ||
  haiku.id !== 'claude-haiku-4-5' ||
  haiku.name !== 'Claude Haiku 4.5 (latest)' ||
  haiku.api !== 'anthropic-messages' ||
  haiku.reasoning !== true ||
  haiku.contextWindow !== 200000 ||
  !haiku.input.includes('image')
) {
  throw new Error('model smoke did not return expected upstream model metadata');
}

const listedHaiku = JSON.parse(run(['list-models', 'haiku']));
if (listedHaiku.count < 10 || !listedHaiku.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')) {
  throw new Error('list-models smoke did not fuzzy-search model provider/id/name');
}

const topLevelListedHaiku = JSON.parse(run(['--list-models', 'haiku']));
if (
  topLevelListedHaiku.count !== listedHaiku.count ||
  !topLevelListedHaiku.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('top-level --list-models smoke did not route through upstream-style CLI parsing');
}

const resolvedProviderModel = JSON.parse(run(['resolve-model', 'openai/gpt-4o']));
if (
  resolvedProviderModel.error !== null ||
  resolvedProviderModel.model?.provider !== 'openai' ||
  resolvedProviderModel.model?.id !== 'gpt-4o'
) {
  throw new Error('resolve-model smoke did not resolve provider/model syntax');
}

const resolvedThinking = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'haiku:high']));
if (
  resolvedThinking.error !== null ||
  resolvedThinking.thinkingLevel !== 'high' ||
  resolvedThinking.model?.provider !== 'anthropic' ||
  !resolvedThinking.model?.id.includes('haiku')
) {
  throw new Error('resolve-model smoke did not parse fuzzy model plus thinking suffix');
}

const customModel = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'custom-claude']));
if (
  customModel.error !== null ||
  customModel.customModel !== true ||
  customModel.model?.provider !== 'anthropic' ||
  customModel.model?.id !== 'custom-claude'
) {
  throw new Error('resolve-model smoke did not build provider-scoped custom model fallback');
}

const tools = JSON.parse(run(['tools']));
if (!tools.builtins.includes('read') || !tools.builtins.includes('bash')) {
  throw new Error('tools smoke missing built-ins');
}

const parsedArgs = JSON.parse(run([
  'parse-args',
  '--provider', 'openai',
  '--model', 'gpt-4o',
  '--api-key', 'test-key-ref',
  '--system-prompt', 'system base',
  '--append-system-prompt', 'extra one',
  '--append-system-prompt', 'extra two',
  '--mode', 'json',
  '--thinking', 'xhigh',
  '--continue',
  '--resume',
  '--no-session',
  '--session', 'session.jsonl',
  '--fork', 'fork.jsonl',
  '--session-dir', 'zig-out/sessions',
  '--models', 'anthropic/*,openai/*',
  '--tools', 'read,bash',
  '--no-tools',
  '--no-builtin-tools',
  '--list-models', 'haiku',
  '--offline',
  '--verbose',
  '--no-context-files',
  '--export', 'out.html',
  '--extension', 'ext.ts',
  '--no-extensions',
  '--skill', 'skill.md',
  '--no-skills',
  '--prompt-template', 'prompt.md',
  '--no-prompt-templates',
  '--theme', 'theme.json',
  '--no-themes',
  '-p', 'say ok',
  '@README.md',
  '--unknown-flag=value'
]));
if (
  parsedArgs.provider !== 'openai' ||
  parsedArgs.model !== 'gpt-4o' ||
  parsedArgs.apiKey !== 'test-key-ref' ||
  parsedArgs.systemPrompt !== 'system base' ||
  parsedArgs.appendSystemPrompts.join('|') !== 'extra one|extra two' ||
  parsedArgs.mode !== 'json' ||
  parsedArgs.thinking !== 'xhigh' ||
  parsedArgs.print !== true ||
  parsedArgs.continue !== true ||
  parsedArgs.resume !== true ||
  parsedArgs.noSession !== true ||
  parsedArgs.session !== 'session.jsonl' ||
  parsedArgs.fork !== 'fork.jsonl' ||
  parsedArgs.sessionDir !== 'zig-out/sessions' ||
  parsedArgs.models !== 'anthropic/*,openai/*' ||
  parsedArgs.tools !== 'read,bash' ||
  parsedArgs.noTools !== true ||
  parsedArgs.noBuiltinTools !== true ||
  parsedArgs.listModels !== true ||
  parsedArgs.listModelsPattern !== 'haiku' ||
  parsedArgs.offline !== true ||
  parsedArgs.verbose !== true ||
  parsedArgs.noContextFiles !== true ||
  parsedArgs.export !== 'out.html' ||
  parsedArgs.extensions[0] !== 'ext.ts' ||
  parsedArgs.noExtensions !== true ||
  parsedArgs.skills[0] !== 'skill.md' ||
  parsedArgs.noSkills !== true ||
  parsedArgs.promptTemplates[0] !== 'prompt.md' ||
  parsedArgs.noPromptTemplates !== true ||
  parsedArgs.themes[0] !== 'theme.json' ||
  parsedArgs.noThemes !== true ||
  parsedArgs.messages[0] !== 'say ok' ||
  parsedArgs.fileArgs[0] !== 'README.md' ||
  parsedArgs.unknownFlags[0]?.name !== 'unknown-flag' ||
  parsedArgs.unknownFlags[0]?.value !== 'value'
) {
  throw new Error('parse-args smoke did not match upstream-style parsing');
}

const topLevelPrint = run(['-p', 'hello top-level print']);
if (
  !topLevelPrint.includes('pi-zig print-mode foundation accepted 1 prompt input(s)') ||
  !topLevelPrint.includes('Prompt:\nhello top-level print')
) {
  throw new Error('top-level print mode smoke did not accept an inline prompt');
}

const fakeProvider = await startFakeProviderServer();
try {
  const providerRuntimeAgentDir = path.resolve('zig-out/pi-zig-provider-runtime-agent');
  fs.rmSync(providerRuntimeAgentDir, { recursive: true, force: true });
  fs.mkdirSync(providerRuntimeAgentDir, { recursive: true });
  fs.writeFileSync(path.join(providerRuntimeAgentDir, 'settings.json'), JSON.stringify({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 0 } }));
  const providerEnv = {
    ...process.env,
    OPENAI_API_KEY: 'fake-provider-key',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl,
    PI_CODING_AGENT_DIR: providerRuntimeAgentDir
  };
  const extensionHookFixture = path.resolve('zig-out/pi-zig-extension-hook-fixture');
  fs.rmSync(extensionHookFixture, { recursive: true, force: true });
  fs.mkdirSync(extensionHookFixture, { recursive: true });
  const extensionHookPath = path.join(extensionHookFixture, 'hook.mjs');
  fs.writeFileSync(extensionHookPath, `
export default function(pi) {
  pi.on("tool_call", (event) => {
    if (event.toolName === "bash" && event.input.command === "printf extension-original") {
      event.input.command = "printf extension-rewritten-ok";
    }
  });
  pi.on("tool_result", (event) => {
    const text = Array.isArray(event.content)
      ? event.content.filter((part) => part?.type === "text").map((part) => part.text ?? "").join("\\n")
      : "";
    if (event.toolName === "bash" && text.trim() === "extension-rewritten-ok") {
      return { content: [{ type: "text", text: "extension-result-patched" }], isError: false };
    }
  });
}
`);
  const extensionToolPath = path.join(extensionHookFixture, 'tool.mjs');
  fs.writeFileSync(extensionToolPath, `
export default function(pi) {
  pi.registerTool({
    name: "ext_echo",
    label: "Extension Echo",
    description: "Echo a value through an explicit extension tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId, params) => ({
      content: [{ type: "text", text: "ext-echo: " + params.value }],
      isError: false
    })
  });
}
`);
  const extensionFlagToolPath = path.join(extensionHookFixture, 'flag-tool.mjs');
  fs.writeFileSync(extensionFlagToolPath, `
export default function(pi) {
  pi.registerFlag("plan", { default: "default-plan" });
  pi.registerFlag("debug-flag", { default: false });
  pi.registerTool({
    name: "ext_flag_echo",
    label: "Extension Flag Echo",
    description: "Echo values from extension flags",
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false
    },
    execute: async () => ({
      content: [{
        type: "text",
        text: "ext-flag: plan=" + String(pi.getFlag("plan")) + ";debug=" + String(pi.getFlag("debug-flag")) + ";missing=" + String(pi.getFlag("missing"))
      }],
      isError: false
    })
  });
}
`);
  const extensionPermissionGatePath = path.join(extensionHookFixture, 'permission-gate.mjs');
  fs.writeFileSync(extensionPermissionGatePath, `
export default function(pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash" && event.input.command === "printf should-not-run") {
      const allowed = await ctx.ui.confirm("Run bash command?", event.input.command);
      if (!allowed) {
        return { block: true, reason: "blocked by headless permission gate" };
      }
    }
  });
}
`);
  const extensionBashOverridePath = path.join(extensionHookFixture, 'bash-override.mjs');
  fs.writeFileSync(extensionBashOverridePath, `
export default function(pi) {
  pi.registerTool({
    name: "bash",
    label: "Extension Bash Override",
    description: "Extension override for the built-in bash tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId, params) => ({
      content: [{ type: "text", text: "ext-bash: " + params.value }],
      isError: false
    })
  });
}
`);
  const extensionTsHelperPath = path.join(extensionHookFixture, 'helper.ts');
  fs.writeFileSync(extensionTsHelperPath, `
export const prefix: string = "ext-ts-echo";
`);
  const extensionTsToolPath = path.join(extensionHookFixture, 'tool.ts');
  fs.writeFileSync(extensionTsToolPath, `
import { prefix } from "./helper.ts";

type Params = { value: string };

export default function(pi: any): void {
  pi.on("tool_call", (event: any) => {
    if (event.toolName === "bash" && event.input.command === "printf extension-original") {
      event.input.command = "printf extension-rewritten-ok";
    }
  });
  pi.on("tool_result", (event: any) => {
    const text = Array.isArray(event.content)
      ? event.content.filter((part: any) => part?.type === "text").map((part: any) => part.text ?? "").join("\\n")
      : "";
    if (event.toolName === "bash" && text.trim() === "extension-rewritten-ok") {
      return { content: [{ type: "text", text: "extension-result-patched" }], isError: false };
    }
  });
  pi.registerTool({
    name: "ext_ts_echo",
    label: "Extension TS Echo",
    description: "Echo a value through a TypeScript extension tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId: string, params: Params) => ({
      content: [{ type: "text", text: prefix + ": " + params.value }],
      isError: false
    })
  });
}
`);
  const discoveredExtensionProject = path.resolve('zig-out/pi-zig-discovered-extension-project');
  fs.rmSync(discoveredExtensionProject, { recursive: true, force: true });
  fs.mkdirSync(path.join(discoveredExtensionProject, '.pi/extensions'), { recursive: true });
  fs.copyFileSync(extensionHookPath, path.join(discoveredExtensionProject, '.pi/extensions/hook.mjs'));
  fs.copyFileSync(extensionToolPath, path.join(discoveredExtensionProject, '.pi/extensions/tool.mjs'));
  fs.copyFileSync(extensionTsHelperPath, path.join(discoveredExtensionProject, '.pi/extensions/helper.ts'));
  fs.copyFileSync(extensionTsToolPath, path.join(discoveredExtensionProject, '.pi/extensions/tool.ts'));
  const providerPrint = run(
    [
      '--provider', 'openai',
      '--model', 'mock-chat-model',
      '--system-prompt', 'system base',
      '--append-system-prompt', 'extra system',
      '-p', 'hello provider print'
    ],
    undefined,
    { env: providerEnv }
  );
  if (!providerPrint.includes('mock provider response for mock-chat-model: hello provider print [system=system base')) {
    throw new Error('top-level print mode smoke did not execute the OpenAI-compatible provider path');
  }

  const providerContextFixture = path.resolve('zig-out/pi-zig-provider-context-fixture');
  const providerContextCwd = path.join(providerContextFixture, 'project');
  const providerContextAgentDir = path.join(providerContextFixture, 'agent-home');
  fs.rmSync(providerContextFixture, { recursive: true, force: true });
  fs.mkdirSync(path.join(providerContextCwd, '.pi'), { recursive: true });
  fs.mkdirSync(providerContextAgentDir, { recursive: true });
  fs.writeFileSync(path.join(providerContextCwd, 'AGENTS.md'), 'provider project context sentinel');
  fs.writeFileSync(path.join(providerContextCwd, '.pi', 'SYSTEM.md'), 'provider system sentinel');
  fs.writeFileSync(path.join(providerContextCwd, '.pi', 'APPEND_SYSTEM.md'), 'provider append sentinel');
  const providerContextPrint = run(
    ['--provider', 'openai', '--model', 'mock-context-model', '-p', 'hello provider context'],
    undefined,
    {
      cwd: providerContextCwd,
      env: {
        ...providerEnv,
        PI_CODING_AGENT_DIR: providerContextAgentDir
      }
    }
  );
  if (
    !providerContextPrint.includes('mock provider response for mock-context-model: hello provider context') ||
    !providerContextPrint.includes('provider system sentinel') ||
    !providerContextPrint.includes('provider append sentinel') ||
    !providerContextPrint.includes('provider project context sentinel')
  ) {
    throw new Error('provider-backed print mode did not build a system prompt with custom system, append, and project context');
  }
  fs.rmSync(path.join(providerContextCwd, '.pi', 'SYSTEM.md'));
  const providerDefaultContextPrint = run(
    ['--provider', 'openai', '--model', 'mock-context-tools-model', '-p', 'hello provider context tools'],
    undefined,
    {
      cwd: providerContextCwd,
      env: {
        ...providerEnv,
        PI_CODING_AGENT_DIR: providerContextAgentDir
      }
    }
  );
  if (
    !providerDefaultContextPrint.includes('mock provider response for mock-context-tools-model: hello provider context tools') ||
    !providerDefaultContextPrint.includes('Available tools:') ||
    !providerDefaultContextPrint.includes('read: Read file contents') ||
    !providerDefaultContextPrint.includes('provider append sentinel') ||
    !providerDefaultContextPrint.includes('provider project context sentinel')
  ) {
    throw new Error('provider-backed print mode did not build a default system prompt with context and tool metadata');
  }

  const providerJsonLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-model', '-p', 'hello provider json'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('mock provider response for mock-json-model: hello provider json')) ||
    !providerJsonLines.some((line) => line.type === 'agent_end')
  ) {
    throw new Error('top-level JSON mode smoke did not include provider-backed assistant output');
  }

  const providerJsonStreamLines = run(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'mock-json-stream-model', '-p', 'hello streaming provider json'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonStreamLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'stream ') ||
    !providerJsonStreamLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'delta') ||
    !providerJsonStreamLines.some((line) => line.type === 'message_end' && JSON.stringify(line.message).includes('stream delta')) ||
    !providerJsonStreamLines.some((line) => line.type === 'turn_end' && line.toolResults?.length === 0) ||
    !providerJsonStreamLines.some((line) => line.type === 'agent_end' && JSON.stringify(line.messages).includes('stream delta'))
  ) {
    throw new Error('top-level JSON mode smoke did not stream provider text deltas');
  }

  const assertJsonRetryEvents = (lines, label, expectedDelta) => {
    const summary = lines
      .filter((line) => ['agent_end', 'auto_retry_start', 'auto_retry_end'].includes(line.type))
      .map((line) => {
        if (line.type === 'agent_end') return `agent_end:${line.willRetry}`;
        if (line.type === 'auto_retry_start') return `auto_retry_start:${line.attempt}:${line.maxAttempts}:${line.delayMs}:${line.errorMessage}`;
        return `auto_retry_end:${line.success}:${line.attempt}:${line.finalError ?? ''}`;
      });
    if (
      JSON.stringify(summary) !== JSON.stringify([
        'agent_end:true',
        'auto_retry_start:1:2:0:ProviderRequestFailed',
        'auto_retry_end:true:1:',
        'agent_end:false'
      ]) ||
      !lines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === expectedDelta)
    ) {
      throw new Error(label + ' did not emit upstream-shaped JSON retry events');
    }
    const failedAgentEndIndex = lines.findIndex((line) => line.type === 'agent_end' && line.willRetry === true);
    const retryStartIndex = lines.findIndex((line) => line.type === 'auto_retry_start');
    const finalMessageEndIndex = lines.findIndex((line) => line.type === 'message_end' && JSON.stringify(line.message).includes(expectedDelta));
    const retryEndIndex = lines.findIndex((line) => line.type === 'auto_retry_end' && line.success === true);
    const finalTurnEndIndex = lines.findIndex((line) => line.type === 'turn_end' && JSON.stringify(line.message).includes(expectedDelta));
    const finalAgentEndIndex = lines.findIndex((line) => line.type === 'agent_end' && line.willRetry === false);
    if (
      !(failedAgentEndIndex >= 0 &&
        failedAgentEndIndex < retryStartIndex &&
        retryStartIndex < finalMessageEndIndex &&
        finalMessageEndIndex < retryEndIndex &&
        retryEndIndex < finalTurnEndIndex &&
        finalTurnEndIndex < finalAgentEndIndex)
    ) {
      throw new Error(label + ' JSON retry event order regressed');
    }
  };

  const assertJsonRetryExhaustedEvents = (lines, label) => {
    const summary = lines
      .filter((line) => ['agent_end', 'auto_retry_start', 'auto_retry_end'].includes(line.type))
      .map((line) => {
        if (line.type === 'agent_end') return `agent_end:${line.willRetry}`;
        if (line.type === 'auto_retry_start') return `auto_retry_start:${line.attempt}:${line.maxAttempts}:${line.delayMs}:${line.errorMessage}`;
        return `auto_retry_end:${line.success}:${line.attempt}:${line.finalError ?? ''}`;
      });
    if (
      JSON.stringify(summary) !== JSON.stringify([
        'agent_end:true',
        'auto_retry_start:1:2:0:ProviderRequestFailed',
        'agent_end:true',
        'auto_retry_start:2:2:0:ProviderRequestFailed',
        'agent_end:false',
        'auto_retry_end:false:2:ProviderRequestFailed'
      ])
    ) {
      throw new Error(label + ' did not emit exhausted JSON retry events');
    }
  };

  const assertNoJsonRetryEvents = (lines, label) => {
    if (lines.some((line) => line.type === 'auto_retry_start' || line.type === 'auto_retry_end' || line.willRetry === true)) {
      throw new Error(label + ' unexpectedly emitted JSON retry events');
    }
  };

  const providerJsonRetryStreamLines = run(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry transient stream'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  assertJsonRetryEvents(providerJsonRetryStreamLines, 'top-level JSON text-stream retry', 'json retry stream recovered');

  const providerJsonRetryToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry transient tool-capable'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  assertJsonRetryEvents(providerJsonRetryToolLines, 'top-level JSON tool-capable retry', 'json retry tool-capable recovered');

  const providerJsonRetryExhausted = runFail(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry exhausted stream'],
    undefined,
    { env: providerEnv }
  );
  assertJsonRetryExhaustedEvents(jsonLines(providerJsonRetryExhausted.stdout), 'top-level JSON exhausted retry');

  const providerJsonRetryToolExhausted = runFail(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry exhausted tool-capable'],
    undefined,
    { env: providerEnv }
  );
  assertJsonRetryExhaustedEvents(jsonLines(providerJsonRetryToolExhausted.stdout), 'top-level JSON tool-capable exhausted retry');

  const providerRetryDisabledAgentDir = path.resolve('zig-out/pi-zig-json-retry-disabled-agent');
  fs.rmSync(providerRetryDisabledAgentDir, { recursive: true, force: true });
  fs.mkdirSync(providerRetryDisabledAgentDir, { recursive: true });
  fs.writeFileSync(path.join(providerRetryDisabledAgentDir, 'settings.json'), JSON.stringify({ retry: { enabled: false, maxRetries: 2, baseDelayMs: 0 } }));
  const providerJsonRetryDisabled = runFail(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry disabled stream'],
    undefined,
    { env: { ...providerEnv, PI_CODING_AGENT_DIR: providerRetryDisabledAgentDir } }
  );
  assertNoJsonRetryEvents(jsonLines(providerJsonRetryDisabled.stdout), 'top-level JSON disabled retry');

  const providerJsonRetryToolDisabled = runFail(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json retry disabled tool-capable'],
    undefined,
    { env: { ...providerEnv, PI_CODING_AGENT_DIR: providerRetryDisabledAgentDir } }
  );
  assertNoJsonRetryEvents(jsonLines(providerJsonRetryToolDisabled.stdout), 'top-level JSON tool-capable disabled retry');

  const assertJsonProviderErrorLifecycle = (lines, label) => {
    const assistantStartCount = lines.filter((line) => line.type === 'message_start' && line.message?.role === 'assistant').length;
    const messageStart = lines.find((line) => line.type === 'message_start' && line.message?.role === 'assistant');
    const messageEnd = lines.find((line) => line.type === 'message_end' && line.message?.role === 'assistant');
    const turnEnd = lines.find((line) => line.type === 'turn_end' && line.message?.role === 'assistant');
    const agentEnd = lines.find((line) => line.type === 'agent_end');
    if (
      assistantStartCount !== 1 ||
      messageStart?.message?.stopReason !== 'error' ||
      messageStart?.message?.errorMessage !== 'ProviderClientError' ||
      messageEnd?.message?.stopReason !== 'error' ||
      messageEnd?.message?.errorMessage !== 'ProviderClientError' ||
      turnEnd?.message?.stopReason !== 'error' ||
      turnEnd?.message?.errorMessage !== 'ProviderClientError' ||
      !Array.isArray(turnEnd?.toolResults) ||
      turnEnd.toolResults.length !== 0 ||
      agentEnd?.messages?.at(-1)?.stopReason !== 'error' ||
      agentEnd?.messages?.at(-1)?.errorMessage !== 'ProviderClientError'
    ) {
      throw new Error(label + ' did not emit an upstream-shaped assistant error lifecycle');
    }
  };

  const assertJsonProviderErrorSession = (sessionFile, label) => {
    const records = jsonLines(fs.readFileSync(sessionFile, 'utf8'));
    const assistant = records
      .filter((record) => record.type === 'message' && record.message?.role === 'assistant')
      .at(-1);
    if (
      assistant?.message?.stopReason !== 'error' ||
      assistant?.message?.errorMessage !== 'ProviderClientError' ||
      assistant?.message?.provider !== 'openai' ||
      assistant?.message?.model !== 'gpt-4o'
    ) {
      throw new Error(label + ' did not persist the provider error assistant turn');
    }
  };

  const providerJsonStreamErrorSessionFile = path.resolve('zig-out/pi-zig-json-stream-provider-error-smoke.jsonl');
  fs.rmSync(providerJsonStreamErrorSessionFile, { force: true });
  const providerJsonStreamError = runFail(
    ['--mode', 'json', '--session', providerJsonStreamErrorSessionFile, '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json provider client error streamed'],
    undefined,
    { env: providerEnv }
  );
  const providerJsonStreamErrorLines = jsonLines(providerJsonStreamError.stdout);
  assertJsonProviderErrorLifecycle(providerJsonStreamErrorLines, 'top-level JSON no-tools provider failure');
  assertNoJsonRetryEvents(providerJsonStreamErrorLines, 'top-level JSON no-tools client failure');
  assertJsonProviderErrorSession(providerJsonStreamErrorSessionFile, 'top-level JSON no-tools provider failure');

  const providerJsonToolErrorSessionFile = path.resolve('zig-out/pi-zig-json-tool-provider-error-smoke.jsonl');
  fs.rmSync(providerJsonToolErrorSessionFile, { force: true });
  const providerJsonToolProviderError = runFail(
    ['--mode', 'json', '--session', providerJsonToolErrorSessionFile, '--provider', 'openai', '--model', 'gpt-4o', '-p', 'json provider client error tool-capable'],
    undefined,
    { env: providerEnv }
  );
  const providerJsonToolProviderErrorLines = jsonLines(providerJsonToolProviderError.stdout);
  assertJsonProviderErrorLifecycle(providerJsonToolProviderErrorLines, 'top-level JSON tool-capable provider failure');
  assertNoJsonRetryEvents(providerJsonToolProviderErrorLines, 'top-level JSON tool-capable client failure');
  assertJsonProviderErrorSession(providerJsonToolErrorSessionFile, 'top-level JSON tool-capable provider failure');

  const providerImageFixture = path.resolve('zig-out/pi-zig-provider-image-fixture');
  fs.rmSync(providerImageFixture, { recursive: true, force: true });
  fs.mkdirSync(providerImageFixture, { recursive: true });
  const providerImagePath = path.join(providerImageFixture, 'input.png');
  fs.writeFileSync(providerImagePath, Buffer.from('aW1hZ2Utc21va2U=', 'base64'));
  const providerJsonImageLines = run(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'mock-json-image-model', '@' + providerImagePath, '-p', 'image input json'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (!providerJsonImageLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'image json observed')) {
    throw new Error('top-level JSON no-tools provider path did not send image content parts');
  }
  const providerAgentImage = run(
    ['--no-session', '--provider', 'openai', '--model', 'mock-agent-image-model', '@' + providerImagePath, '-p', 'image input agent'],
    undefined,
    { env: providerEnv }
  );
  if (!providerAgentImage.includes('image agent observed')) {
    throw new Error('provider-backed agent loop did not send image content parts');
  }
  const providerNonVisionAgentImage = run(
    ['--no-session', '--provider', 'openai', '--model', 'gpt-4', '@' + providerImagePath, '-p', 'non vision image input agent'],
    undefined,
    { env: providerEnv }
  );
  if (!providerNonVisionAgentImage.includes('non vision image agent observed')) {
    throw new Error('provider-backed agent loop did not downgrade direct image content parts for non-vision models');
  }
  const providerNonVisionReadImage = run(
    ['--no-session', '--provider', 'openai', '--model', 'gpt-4', '-p', 'non vision read image result'],
    undefined,
    { env: providerEnv }
  );
  if (!providerNonVisionReadImage.includes('non vision read image result complete')) {
    throw new Error('provider-backed agent loop did not downgrade read-tool image result parts for non-vision models');
  }

  const providerJsonToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-tool-model', '-p', 'please run the tool loop'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_tool_loop_1') ||
    !providerJsonToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_tool_loop_1' && JSON.stringify(line.partialResult).includes('tool-loop-ok')) ||
    !providerJsonToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('tool-loop-ok')) ||
    !providerJsonToolLines.some((line) => line.type === 'message_end' && line.message?.role === 'toolResult' && line.message?.toolCallId === 'call_tool_loop_1') ||
    !providerJsonToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_tool_loop_1')) ||
    !providerJsonToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('tool loop complete: tool-loop-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not emit provider-backed tool execution events');
  }
  const providerJsonToolStartIndex = providerJsonToolLines.findIndex((line) => line.type === 'tool_execution_start');
  const providerJsonAssistantStartIndex = providerJsonToolLines.findIndex((line) => line.type === 'message_start' && line.message?.role === 'assistant');
  if (providerJsonToolStartIndex < 0 || providerJsonAssistantStartIndex < 0 || providerJsonToolStartIndex > providerJsonAssistantStartIndex) {
    throw new Error('top-level JSON mode smoke did not emit live tool events before final assistant output');
  }

  const providerJsonBashUpdateLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-bash-updates-model', '-p', 'please run slow bash updates'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const slowBashUpdates = providerJsonBashUpdateLines.filter(
    (line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_slow_bash_updates_1'
  );
  const slowBashUpdateTexts = slowBashUpdates.map((line) => line.partialResult?.content?.[0]?.text ?? '');
  const slowFirstIndex = slowBashUpdateTexts.findIndex((text) => text === 'slow-first');
  const slowCombinedIndex = slowBashUpdateTexts.findIndex((text) => text.includes('slow-firstslow-second'));
  if (
    !providerJsonBashUpdateLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_slow_bash_updates_1') ||
    slowBashUpdates.length < 3 ||
    slowFirstIndex < 0 ||
    slowCombinedIndex < 0 ||
    slowFirstIndex > slowCombinedIndex ||
    !providerJsonBashUpdateLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('slow-firstslow-second')) ||
    !providerJsonBashUpdateLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('slow bash updates complete: slow-firstslow-second'))
  ) {
    throw new Error('top-level JSON mode smoke did not emit intermediate bash output update snapshots');
  }

  const providerJsonTimeoutToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-bash-timeout-model', '-p', 'please run timeout bash tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const timeoutToolTexts = providerJsonTimeoutToolLines.flatMap((line) => [
    line.partialResult?.content?.[0]?.text,
    line.result?.content?.[0]?.text,
    ...(line.toolResults ?? []).map((result) => result.content)
  ].filter(Boolean));
  if (
    !providerJsonTimeoutToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_timeout_bash_1' && JSON.stringify(line.partialResult).includes('before-timeout')) ||
    !providerJsonTimeoutToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && line.toolCallId === 'call_timeout_bash_1' && line.isError === true && JSON.stringify(line.result).includes('Command timed out after 0.100 seconds')) ||
    timeoutToolTexts.some((text) => text.includes('after-timeout')) ||
    !providerJsonTimeoutToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_timeout_bash_1' && result.isError === true)) ||
    !providerJsonTimeoutToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('timeout bash complete'))
  ) {
    throw new Error('top-level JSON mode smoke did not preserve partial output from a timed out bash tool call');
  }

  const providerJsonLongBashUpdateLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-long-bash-updates-model', '-p', 'please run long bash updates'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const longBashTruncatedUpdate = providerJsonLongBashUpdateLines.find(
    (line) => line.type === 'tool_execution_update' &&
      line.toolName === 'bash' &&
      line.toolCallId === 'call_long_bash_updates_1' &&
      line.partialResult?.details?.truncation?.truncated === true &&
      line.partialResult?.details?.truncation?.totalLines === 2105 &&
      line.partialResult?.content?.[0]?.text?.includes('json-update-line-2104')
  );
  if (
    longBashTruncatedUpdate?.partialResult?.details?.truncation?.truncatedBy !== 'lines' ||
    longBashTruncatedUpdate?.partialResult?.details?.truncation?.totalLines !== 2105 ||
    longBashTruncatedUpdate?.partialResult?.details?.truncation?.outputLines !== 2000 ||
    longBashTruncatedUpdate?.partialResult?.details?.truncation?.maxLines !== 2000 ||
    longBashTruncatedUpdate?.partialResult?.details?.truncation?.maxBytes !== 50 * 1024 ||
    longBashTruncatedUpdate?.partialResult?.details?.fullOutputPath !== 'zig-out/pi-zig-bash-full-output.log' ||
    longBashTruncatedUpdate?.partialResult?.content?.[0]?.text?.includes('json-update-line-0000') ||
    !longBashTruncatedUpdate?.partialResult?.content?.[0]?.text?.includes('json-update-line-2104') ||
    !providerJsonLongBashUpdateLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('Full output: zig-out/pi-zig-bash-full-output.log')) ||
    !providerJsonLongBashUpdateLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('long bash updates complete'))
  ) {
    throw new Error('top-level JSON mode smoke did not emit upstream-shaped bash truncation update details');
  }

  const providerJsonStreamingToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-stream-tool-model', '-p', 'please run the streaming tool loop'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonStreamingToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_stream_tool_1') ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_stream_tool_1' && JSON.stringify(line.partialResult).includes('stream-tool-ok')) ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('stream-tool-ok')) ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_stream_tool_1')) ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'streaming tool ') ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'loop complete: stream-tool-ok') ||
    !providerJsonStreamingToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('streaming tool loop complete: stream-tool-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not assemble streamed provider tool calls');
  }

  const providerJsonExtensionHookLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionHookPath, '--provider', 'openai', '--model', 'mock-json-extension-hook-model', '-p', 'please run extension hook events'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionHookLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('extension-result-patched')) ||
    !providerJsonExtensionHookLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_hook_1' && JSON.stringify(result).includes('extension-result-patched'))) ||
    !providerJsonExtensionHookLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension hook ') ||
    !providerJsonExtensionHookLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension hook complete: extension-result-patched'))
  ) {
    throw new Error('top-level JSON mode smoke did not bind explicit extension tool_call/tool_result hooks');
  }

  const providerJsonExtensionToolLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionToolPath, '--provider', 'openai', '--model', 'mock-json-extension-tool-model', '-p', 'please run extension registered tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_echo' && line.toolCallId === 'call_extension_tool_1') ||
    !providerJsonExtensionToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_echo' && JSON.stringify(line.result).includes('ext-echo: registered-ok')) ||
    !providerJsonExtensionToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_tool_1' && JSON.stringify(result).includes('ext-echo: registered-ok'))) ||
    !providerJsonExtensionToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension tool ') ||
    !providerJsonExtensionToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension tool complete: ext-echo: registered-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not expose and execute an explicit registered extension tool');
  }

  const providerJsonExtensionFlagToolLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionFlagToolPath, '--plan', 'review', '--debug-flag', '--provider', 'openai', '--model', 'mock-json-extension-flag-tool-model', '-p', 'please run extension flag registered tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionFlagToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_flag_echo' && line.toolCallId === 'call_extension_flag_tool_1') ||
    !providerJsonExtensionFlagToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_flag_echo' && JSON.stringify(line.result).includes('ext-flag: plan=review;debug=true;missing=undefined')) ||
    !providerJsonExtensionFlagToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_flag_tool_1' && JSON.stringify(result).includes('ext-flag: plan=review;debug=true;missing=undefined'))) ||
    !providerJsonExtensionFlagToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension flag tool complete: ext-flag: plan=review;debug=true;missing=undefined'))
  ) {
    throw new Error('top-level JSON mode smoke did not pass CLI extension flags to a registered extension tool');
  }

  const providerJsonExtensionNoBuiltinToolLines = run(
    ['--mode', 'json', '--no-session', '--no-builtin-tools', '--extension', extensionToolPath, '--provider', 'openai', '--model', 'mock-json-extension-no-builtin-tool-model', '-p', 'please run extension no builtin registered tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionNoBuiltinToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_echo' && line.toolCallId === 'call_extension_no_builtin_tool_1') ||
    !providerJsonExtensionNoBuiltinToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_echo' && JSON.stringify(line.result).includes('ext-echo: no-builtin-ok')) ||
    !providerJsonExtensionNoBuiltinToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_no_builtin_tool_1' && JSON.stringify(result).includes('ext-echo: no-builtin-ok'))) ||
    !providerJsonExtensionNoBuiltinToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension no builtin tool ') ||
    !providerJsonExtensionNoBuiltinToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension no builtin tool complete: ext-echo: no-builtin-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not keep extension tools active under --no-builtin-tools');
  }

  const providerJsonExtensionAllowlistToolLines = run(
    ['--mode', 'json', '--no-session', '--tools', 'ext_echo', '--extension', extensionToolPath, '--provider', 'openai', '--model', 'mock-json-extension-allowlist-tool-model', '-p', 'please run extension allowlist registered tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionAllowlistToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_echo' && line.toolCallId === 'call_extension_allowlist_tool_1') ||
    !providerJsonExtensionAllowlistToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_echo' && JSON.stringify(line.result).includes('ext-echo: allowlist-ok')) ||
    !providerJsonExtensionAllowlistToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_allowlist_tool_1' && JSON.stringify(result).includes('ext-echo: allowlist-ok'))) ||
    !providerJsonExtensionAllowlistToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension allowlist tool ') ||
    !providerJsonExtensionAllowlistToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension allowlist tool complete: ext-echo: allowlist-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not allowlist an extension registered tool');
  }

  const providerJsonExtensionPermissionGateLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionPermissionGatePath, '--provider', 'openai', '--model', 'mock-json-extension-permission-gate-model', '-p', 'please run extension permission gate'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionPermissionGateLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_extension_permission_gate_1') ||
    !providerJsonExtensionPermissionGateLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && line.isError === true && JSON.stringify(line.result).includes('blocked by headless permission gate') && !JSON.stringify(line.result).includes('should-not-run')) ||
    !providerJsonExtensionPermissionGateLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_permission_gate_1' && result.isError === true && JSON.stringify(result).includes('blocked by headless permission gate'))) ||
    !providerJsonExtensionPermissionGateLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension permission gate ') ||
    !providerJsonExtensionPermissionGateLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension permission gate complete: blocked by headless permission gate'))
  ) {
    throw new Error('top-level JSON mode smoke did not block a bash tool call through extension headless permission UI');
  }

  const providerJsonExtensionBashOverrideLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionBashOverridePath, '--provider', 'openai', '--model', 'mock-json-extension-bash-override-model', '-p', 'please run extension bash override tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonExtensionBashOverrideLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_extension_bash_override_1' && line.args?.value === 'json-override-ok' && line.args?.command === undefined) ||
    !providerJsonExtensionBashOverrideLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('ext-bash: json-override-ok')) ||
    !providerJsonExtensionBashOverrideLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_bash_override_1' && JSON.stringify(result).includes('ext-bash: json-override-ok'))) ||
    !providerJsonExtensionBashOverrideLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension bash override complete: ext-bash: json-override-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not let a registered extension tool override built-in bash');
  }

  const providerJsonTsExtensionHookLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionTsToolPath, '--provider', 'openai', '--model', 'mock-json-extension-ts-hook-model', '-p', 'please run extension hook events'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonTsExtensionHookLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.args?.command === 'printf extension-rewritten-ok') ||
    !providerJsonTsExtensionHookLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('extension-result-patched')) ||
    !providerJsonTsExtensionHookLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_hook_1' && JSON.stringify(result).includes('extension-result-patched'))) ||
    !providerJsonTsExtensionHookLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension hook complete: extension-result-patched'))
  ) {
    throw new Error('top-level JSON mode smoke did not execute TypeScript extension hooks');
  }

  const providerJsonTsExtensionToolLines = run(
    ['--mode', 'json', '--no-session', '--extension', extensionTsToolPath, '--provider', 'openai', '--model', 'mock-json-extension-ts-tool-model', '-p', 'please run extension typescript tool'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonTsExtensionToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_ts_echo' && line.toolCallId === 'call_extension_ts_tool_1') ||
    !providerJsonTsExtensionToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_ts_echo' && JSON.stringify(line.result).includes('ext-ts-echo: ts-registered-ok')) ||
    !providerJsonTsExtensionToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_ts_tool_1' && JSON.stringify(result).includes('ext-ts-echo: ts-registered-ok'))) ||
    !providerJsonTsExtensionToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'extension ts tool ') ||
    !providerJsonTsExtensionToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension ts tool complete: ext-ts-echo: ts-registered-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not expose and execute an explicit TypeScript registered extension tool');
  }

  const providerJsonDiscoveredExtensionHookLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-discovered-extension-hook-model', '-p', 'please run extension hook events'],
    undefined,
    { cwd: discoveredExtensionProject, env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonDiscoveredExtensionHookLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('extension-result-patched')) ||
    !providerJsonDiscoveredExtensionHookLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_hook_1' && JSON.stringify(result).includes('extension-result-patched'))) ||
    !providerJsonDiscoveredExtensionHookLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension hook complete: extension-result-patched'))
  ) {
    throw new Error('top-level JSON mode smoke did not bind discovered extension tool_call/tool_result hooks');
  }

  const providerJsonDiscoveredExtensionToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-discovered-extension-tool-model', '-p', 'please run extension registered tool'],
    undefined,
    { cwd: discoveredExtensionProject, env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonDiscoveredExtensionToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_echo' && line.toolCallId === 'call_extension_tool_1') ||
    !providerJsonDiscoveredExtensionToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_echo' && JSON.stringify(line.result).includes('ext-echo: registered-ok')) ||
    !providerJsonDiscoveredExtensionToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_tool_1' && JSON.stringify(result).includes('ext-echo: registered-ok'))) ||
    !providerJsonDiscoveredExtensionToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension tool complete: ext-echo: registered-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not expose and execute a discovered registered extension tool');
  }

  const providerJsonDiscoveredTsExtensionToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-discovered-extension-ts-tool-model', '-p', 'please run extension typescript tool'],
    undefined,
    { cwd: discoveredExtensionProject, env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonDiscoveredTsExtensionToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'ext_ts_echo' && line.toolCallId === 'call_extension_ts_tool_1') ||
    !providerJsonDiscoveredTsExtensionToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_ts_echo' && JSON.stringify(line.result).includes('ext-ts-echo: ts-registered-ok')) ||
    !providerJsonDiscoveredTsExtensionToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_extension_ts_tool_1' && JSON.stringify(result).includes('ext-ts-echo: ts-registered-ok'))) ||
    !providerJsonDiscoveredTsExtensionToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('extension ts tool complete: ext-ts-echo: ts-registered-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not expose and execute a discovered TypeScript registered extension tool');
  }

  const providerJsonNoExtensionsExplicitToolLines = run(
    ['--mode', 'json', '--no-session', '--no-extensions', '--extension', extensionToolPath, '--provider', 'openai', '--model', 'mock-json-no-extensions-explicit-tool-model', '-p', 'please run extension registered tool'],
    undefined,
    { cwd: discoveredExtensionProject, env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (!providerJsonNoExtensionsExplicitToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'ext_echo' && JSON.stringify(line.result).includes('ext-echo: registered-ok'))) {
    throw new Error('top-level JSON mode smoke did not keep explicit extension paths under --no-extensions');
  }

  const providerTsExtensionToolLoop = run(
    ['--no-session', '--extension', extensionTsToolPath, '--provider', 'openai', '--model', 'mock-print-extension-ts-tool-model', '-p', 'please run extension typescript tool'],
    undefined,
    { env: providerEnv }
  );
  if (!providerTsExtensionToolLoop.includes('extension ts tool complete: ext-ts-echo: ts-registered-ok')) {
    throw new Error('top-level print mode smoke did not execute an explicit TypeScript registered extension tool');
  }

  const providerJsonResponsesToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-responses-tool-model', '-p', 'please run responses stream tool events'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonResponsesToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_responses_stream_1|item_responses_stream_1') ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_responses_stream_1|item_responses_stream_1' && JSON.stringify(line.partialResult).includes('responses-tool-ok')) ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('responses-tool-ok')) ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_responses_stream_1|item_responses_stream_1')) ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'responses stream ') ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: responses-tool-ok') ||
    !providerJsonResponsesToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('responses stream tool complete: responses-tool-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not assemble OpenAI Responses streamed tool calls');
  }

  const providerJsonAnthropicToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-anthropic-tool-model', '-p', 'please run anthropic stream tool events'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonAnthropicToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_anthropic_stream_1') ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_anthropic_stream_1' && JSON.stringify(line.partialResult).includes('anthropic-tool-ok')) ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('anthropic-tool-ok')) ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_anthropic_stream_1')) ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'anthropic stream ') ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: anthropic-tool-ok') ||
    !providerJsonAnthropicToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('anthropic stream tool complete: anthropic-tool-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not assemble Anthropic streamed tool calls');
  }

  const nativeAnthropicEnv = {
    ...envWithoutAnthropicAuth(),
    ANTHROPIC_API_KEY: 'fake-provider-key',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl
  };
  const providerJsonNativeAnthropicToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'anthropic', '--model', 'claude-haiku-4-5', '-p', 'please run native anthropic stream tool events'],
    undefined,
    { env: nativeAnthropicEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_native_anthropic_stream_1') ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_native_anthropic_stream_1' && JSON.stringify(line.partialResult).includes('native-anthropic-ok')) ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('native-anthropic-ok')) ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_native_anthropic_stream_1')) ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'native anthropic ') ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: native-anthropic-ok') ||
    !providerJsonNativeAnthropicToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('native anthropic tool complete: native-anthropic-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not run native Anthropic messages streamed tool calls');
  }

  const providerJsonGoogleToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-google-tool-model', '-p', 'please run google stream tool events'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonGoogleToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_google_stream_1') ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_google_stream_1' && JSON.stringify(line.partialResult).includes('google-tool-ok')) ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('google-tool-ok')) ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_google_stream_1')) ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'google stream ') ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: google-tool-ok') ||
    !providerJsonGoogleToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('google stream tool complete: google-tool-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not assemble Google streamed tool calls');
  }

  const nativeGoogleEnv = {
    ...envWithoutAnthropicAuth(),
    GEMINI_API_KEY: 'fake-google-key',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl
  };
  const providerJsonNativeGoogleToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'google', '--model', 'gemini-2.5-flash', '-p', 'please run native google stream tool events'],
    undefined,
    { env: nativeGoogleEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_native_google_stream_1') ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_native_google_stream_1' && JSON.stringify(line.partialResult).includes('native-google-ok')) ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('native-google-ok')) ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_native_google_stream_1')) ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'native google ') ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: native-google-ok') ||
    !providerJsonNativeGoogleToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('native google tool complete: native-google-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not run native Google streamed tool calls');
  }

  const nativeVertexEnv = {
    ...envWithoutAnthropicAuth(),
    GOOGLE_CLOUD_API_KEY: 'fake-vertex-key',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl
  };
  const providerJsonNativeVertexToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'google-vertex', '--model', 'gemini-3-flash-preview', '-p', 'please run native vertex stream tool events'],
    undefined,
    { env: nativeVertexEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'call_native_vertex_stream_1') ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'call_native_vertex_stream_1' && JSON.stringify(line.partialResult).includes('native-vertex-ok')) ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('native-vertex-ok')) ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_native_vertex_stream_1')) ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'native vertex ') ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: native-vertex-ok') ||
    !providerJsonNativeVertexToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('native vertex tool complete: native-vertex-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not run native Google Vertex streamed tool calls');
  }

  const nativeMistralEnv = {
    ...envWithoutAnthropicAuth(),
    MISTRAL_API_KEY: 'fake-provider-key',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl
  };
  const providerJsonNativeMistralToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'mistral', '--model', 'devstral-medium-latest', '-p', 'please run native mistral stream tool events'],
    undefined,
    { env: nativeMistralEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'callmistr1') ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'callmistr1' && JSON.stringify(line.partialResult).includes('native-mistral-ok')) ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('native-mistral-ok')) ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'callmistr1')) ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'native mistral ') ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: native-mistral-ok') ||
    !providerJsonNativeMistralToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('native mistral tool complete: native-mistral-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not run native Mistral streamed tool calls');
  }

  const nativeBedrockEnv = {
    ...envWithoutAnthropicAuth(),
    AWS_BEARER_TOKEN_BEDROCK: 'fake-bedrock-token',
    PI_ZIG_PROVIDER_BASE_URL: fakeProvider.baseUrl
  };
  const providerJsonNativeBedrockToolLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'amazon-bedrock', '--model', 'anthropic.claude-test-v1:0', '-p', 'please run native bedrock stream tool events'],
    undefined,
    { env: nativeBedrockEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'tool_execution_start' && line.toolName === 'bash' && line.toolCallId === 'callbedrock1') ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'tool_execution_update' && line.toolName === 'bash' && line.toolCallId === 'callbedrock1' && JSON.stringify(line.partialResult).includes('native-bedrock-ok')) ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'bash' && JSON.stringify(line.result).includes('native-bedrock-ok')) ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'callbedrock1')) ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'native bedrock ') ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'tool complete: native-bedrock-ok') ||
    !providerJsonNativeBedrockToolLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('native bedrock tool complete: native-bedrock-ok'))
  ) {
    throw new Error('top-level JSON mode smoke did not run native Bedrock streamed tool calls');
  }

  const providerJsonToolErrorLines = run(
    ['--mode', 'json', '--no-session', '--provider', 'openai', '--model', 'mock-json-tool-error-model', '-p', 'please run the failing read loop'],
    undefined,
    { env: providerEnv }
  )
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  if (
    !providerJsonToolErrorLines.some((line) => line.type === 'tool_execution_end' && line.toolName === 'read' && line.isError === true && JSON.stringify(line.result).includes('read tool failed:')) ||
    !providerJsonToolErrorLines.some((line) => line.type === 'turn_end' && line.toolResults?.some((result) => result.toolCallId === 'call_failing_read_1' && result.isError === true)) ||
    !providerJsonToolErrorLines.some((line) => line.type === 'message_update' && JSON.stringify(line).includes('failing read loop complete: read tool failed:'))
  ) {
    throw new Error('top-level JSON mode smoke did not mark failed provider tool execution as an error');
  }

  const providerToolLoop = run(
    ['--no-session', '--provider', 'openai', '--model', 'mock-tool-model', '-p', 'please run the tool loop'],
    undefined,
    { env: providerEnv }
  );
  if (!providerToolLoop.includes('tool loop complete: tool-loop-ok')) {
    throw new Error('provider-backed agent loop did not execute bash tool call and return the follow-up response');
  }

  const providerToolImageFixture = path.resolve('zig-out/pi-zig-agent-tool-image-fixture');
  fs.rmSync(providerToolImageFixture, { recursive: true, force: true });
  fs.mkdirSync(providerToolImageFixture, { recursive: true });
  fs.writeFileSync(path.join(providerToolImageFixture, 'input.png'), Buffer.from(tinyPngBase64, 'base64'));
  const providerReadImageTool = run(
    ['--no-session', '--provider', 'openai', '--model', 'mock-read-image-tool-model', '-p', 'please run read image result'],
    undefined,
    { env: providerEnv }
  );
  if (!providerReadImageTool.includes('read image result complete')) {
    throw new Error('provider-backed read tool did not return image tool result content');
  }

  const providerInvalidToolArgumentsLoop = run(
    ['--no-session', '--provider', 'openai', '--model', 'mock-invalid-tool-arguments-model', '-p', 'please run the invalid tool arguments loop'],
    undefined,
    { env: providerEnv }
  );
  if (!providerInvalidToolArgumentsLoop.includes('invalid tool arguments loop complete')) {
    throw new Error('provider-backed agent loop did not surface invalid tool arguments as a tool-result error');
  }

  const providerNoTools = run(
    ['--no-session', '--no-tools', '--provider', 'openai', '--model', 'mock-no-tools-model', '-p', 'expect no tools'],
    undefined,
    { env: providerEnv }
  );
  const providerNoBuiltinTools = run(
    ['--no-session', '--no-builtin-tools', '--provider', 'openai', '--model', 'mock-no-builtin-tools-model', '-p', 'expect no tools'],
    undefined,
    { env: providerEnv }
  );
  const providerFilteredTools = run(
    ['--no-session', '--tools', 'read,grep', '--provider', 'openai', '--model', 'mock-filtered-tools-model', '-p', 'expect selected tools'],
    undefined,
    { env: providerEnv }
  );
  const providerBashTool = run(
    ['--no-session', '--tools', 'bash', '--provider', 'openai', '--model', 'mock-bash-tool-model', '-p', 'expect bash tool'],
    undefined,
    { env: providerEnv }
  );
  if (
    !providerNoTools.includes('no tools observed') ||
    !providerNoBuiltinTools.includes('no tools observed') ||
    !providerFilteredTools.includes('selected tools observed') ||
    !providerBashTool.includes('bash tool observed')
  ) {
    throw new Error('provider-backed agent loop did not honor CLI tool selection flags');
  }

  const agentToolFixture = 'zig-out/pi-zig-agent-tool-fixture';
  fs.rmSync(agentToolFixture, { recursive: true, force: true });
  fs.mkdirSync(agentToolFixture, { recursive: true });
  fs.writeFileSync(path.join(agentToolFixture, 'input.txt'), ['Needle Alpha', 'plain beta'].join('\n'));
  fs.writeFileSync(path.join(agentToolFixture, 'editable.txt'), 'before edit');
  const providerMultiToolLoop = run(
    ['--no-session', '--provider', 'openai', '--model', 'mock-multi-tool-model', '-p', 'please run the multi tool loop'],
    undefined,
    { env: providerEnv }
  );
  if (
    !providerMultiToolLoop.includes('multi tool loop complete') ||
    fs.readFileSync(path.join(agentToolFixture, 'generated.txt'), 'utf8') !== 'generated by provider' ||
    fs.readFileSync(path.join(agentToolFixture, 'editable.txt'), 'utf8') !== 'after edit'
  ) {
    throw new Error('provider-backed agent loop did not execute read/ls/grep/find/write/edit tool calls');
  }
} finally {
  fakeProvider.stop();
}

const topLevelJsonSessionFile = 'zig-out/pi-zig-top-level-json-smoke.jsonl';
fs.rmSync(topLevelJsonSessionFile, { force: true });
const topLevelJsonLines = run(['--mode', 'json', '--session', topLevelJsonSessionFile, '-p', 'hello json mode'])
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => JSON.parse(line));
if (
  topLevelJsonLines[0]?.type !== 'session' ||
  !topLevelJsonLines.some((line) => line.type === 'agent_start') ||
  !topLevelJsonLines.some((line) => line.type === 'turn_end' && line.toolResults?.length === 0) ||
  !topLevelJsonLines.some((line) => line.type === 'message_end' && line.message?.content?.[0]?.text?.includes('hello json mode'))
) {
  throw new Error('top-level --mode json smoke did not emit upstream-shaped JSON event lines');
}
const topLevelJsonSession = fs.readFileSync(topLevelJsonSessionFile, 'utf8');
if (!topLevelJsonSession.includes('"role":"user","content":"hello json mode"') || !topLevelJsonSession.includes('"role":"assistant"')) {
  throw new Error('top-level --mode json smoke did not persist user and assistant foundation messages');
}
const topLevelSessionFixture = path.resolve('zig-out/pi-zig-top-level-session-fixture');
const topLevelSessionDir = path.join(topLevelSessionFixture, 'sessions');
const topLevelForkDir = path.join(topLevelSessionFixture, 'forks');
fs.rmSync(topLevelSessionFixture, { recursive: true, force: true });
run(['--session-dir', topLevelSessionDir, '-p', 'session first']);
let sessionFiles = fs.readdirSync(topLevelSessionDir).filter((file) => file.endsWith('.jsonl')).sort();
if (sessionFiles.length !== 1) {
  throw new Error('top-level --session-dir smoke did not create one timestamped session file');
}
const firstSessionFile = path.join(topLevelSessionDir, sessionFiles[0]);
const firstSessionId = JSON.parse(fs.readFileSync(firstSessionFile, 'utf8').split('\n')[0]).id;
run(['--session-dir', topLevelSessionDir, '--continue', '-p', 'session second']);
sessionFiles = fs.readdirSync(topLevelSessionDir).filter((file) => file.endsWith('.jsonl')).sort();
if (sessionFiles.length !== 1) {
  throw new Error('top-level --continue smoke did not reuse the most recent session file');
}
run(['--session-dir', topLevelSessionDir, '--session', firstSessionId.slice(0, 14), '-p', 'session third']);
const continuedSession = fs.readFileSync(firstSessionFile, 'utf8');
if (!continuedSession.includes('session first') || !continuedSession.includes('session second') || !continuedSession.includes('session third')) {
  throw new Error('top-level session lookup smoke did not append through --continue and --session id prefix');
}
run(['--session-dir', topLevelForkDir, '--fork', firstSessionFile, '-p', 'fork prompt']);
const forkFiles = fs.readdirSync(topLevelForkDir).filter((file) => file.endsWith('.jsonl'));
if (forkFiles.length !== 1) {
  throw new Error('top-level --fork smoke did not create one forked session file');
}
const forkedSession = fs.readFileSync(path.join(topLevelForkDir, forkFiles[0]), 'utf8');
if (!forkedSession.includes(`"parentSession":"${firstSessionFile}"`) || !forkedSession.includes('session first') || !forkedSession.includes('session third') || !forkedSession.includes('fork prompt')) {
  throw new Error('top-level --fork smoke did not copy source history and parentSession into the fork');
}
const forkConflict = runFail(['--fork', firstSessionFile, '--session', firstSessionFile, '-p', 'bad fork']);
if (!forkConflict.stderr.includes('--fork cannot be combined with --session')) {
  throw new Error('top-level --fork conflict smoke did not reject incompatible session flags');
}
const topLevelExportFile = 'zig-out/pi-zig-top-level-export.html';
fs.rmSync(topLevelExportFile, { force: true });
const topLevelExportOutput = run(['--export', topLevelJsonSessionFile, topLevelExportFile]);
if (!topLevelExportOutput.includes(`Exported to: ${topLevelExportFile}`)) {
  throw new Error('top-level --export smoke did not report the requested output path');
}
const topLevelExportHtml = fs.readFileSync(topLevelExportFile, 'utf8');
if (!topLevelExportHtml.includes('pi-zig session') || !topLevelExportHtml.includes('hello json mode')) {
  throw new Error('top-level --export smoke did not render JSONL session messages to HTML');
}

const topLevelRpcSessionFile = 'zig-out/pi-zig-top-level-rpc-smoke.jsonl';
const topLevelRpcSessionPath = path.resolve(topLevelRpcSessionFile);
fs.rmSync(topLevelRpcSessionFile, { force: true });
const topLevelRpcOutput = run(
  ['--mode', 'rpc', '--session', topLevelRpcSessionFile],
  `${JSON.stringify({ id: 'top-rpc', type: 'get_state' })}\n`
);
const topLevelRpcResponse = topLevelRpcOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))[0];
if (
  topLevelRpcResponse?.id !== 'top-rpc' ||
  topLevelRpcResponse?.command !== 'get_state' ||
  topLevelRpcResponse?.data?.sessionFile !== topLevelRpcSessionPath
) {
  throw new Error('top-level --mode rpc smoke did not route to RPC runtime with --session');
}

const readme = run(['tool-read', 'README.md']);
if (!readme.includes('Zig + Preact porting workspace')) {
  throw new Error('tool-read smoke did not return README content');
}
const readFixture = 'zig-out/pi-zig-read-fixture.txt';
fs.writeFileSync(readFixture, ['one', 'two', 'three', 'four', 'five'].join('\n'));
const readWindow = run(['tool-read', readFixture, '2', '2']);
if (readWindow !== 'two\nthree\n\n[2 more lines in file. Use offset=4 to continue.]') {
  throw new Error('tool-read offset/limit smoke did not return upstream-style continuation notice');
}
const readLongLinesFixture = 'zig-out/pi-zig-read-long-lines-fixture.txt';
fs.writeFileSync(readLongLinesFixture, Array.from({ length: 2001 }, (_, index) => `line-${index + 1}`).join('\n'));
const readLongLines = run(['tool-read', readLongLinesFixture]);
if (
  !readLongLines.includes('line-2000') ||
  readLongLines.includes('line-2001') ||
  !readLongLines.includes('[Showing lines 1-2000 of 2001. Use offset=2001 to continue.]')
) {
  throw new Error('tool-read line truncation smoke did not match upstream-style limit notice');
}
const readLongLineFixture = 'zig-out/pi-zig-read-long-line-fixture.txt';
fs.writeFileSync(readLongLineFixture, 'x'.repeat(52 * 1024));
const readLongLine = run(['tool-read', readLongLineFixture]);
if (!readLongLine.includes('Line 1 is 52.0KB') || !readLongLine.includes('head -c 51200')) {
  throw new Error('tool-read long-line smoke did not return bash fallback notice');
}

const bash = run(['tool-bash', 'printf pi-zig-tool-bash']);
if (bash !== 'pi-zig-tool-bash') {
  throw new Error(`tool-bash smoke returned unexpected output: ${JSON.stringify(bash)}`);
}
const bashSanitized = run(['tool-bash', "printf '\\033[31mred\\033[0m\\r\\nbad\\001ok'"]);
if (bashSanitized !== 'red\nbadok') {
  throw new Error(`tool-bash sanitization smoke returned unexpected output: ${JSON.stringify(bashSanitized)}`);
}
const bashInterleaved = run(['tool-bash', 'printf out; printf err >&2; printf done']);
if (bashInterleaved !== 'outerrdone') {
  throw new Error(`tool-bash interleaved stdout/stderr smoke returned unexpected output: ${JSON.stringify(bashInterleaved)}`);
}
const bashNoOutput = run(['tool-bash', 'true']);
if (bashNoOutput !== '(no output)') {
  throw new Error(`tool-bash no-output smoke returned unexpected output: ${JSON.stringify(bashNoOutput)}`);
}
const bashFailure = runFail(['tool-bash', 'printf before-failure; exit 7']);
if (!bashFailure.stdout.includes('before-failure') || !bashFailure.stdout.includes('Command exited with code 7')) {
  throw new Error('tool-bash failure smoke did not include output and exit status');
}
const bashLong = run(['tool-bash', "node -e \"for (let i = 0; i < 2105; i++) console.log('bash-line-' + String(i).padStart(4, '0'))\""]);
if (
  bashLong.includes('bash-line-0000') ||
  !bashLong.includes('bash-line-2104') ||
  !bashLong.includes('Full output: zig-out/pi-zig-bash-full-output.log')
) {
  throw new Error('tool-bash long-output smoke did not keep tail output and full-output path');
}
const bashFullOutput = fs.readFileSync('zig-out/pi-zig-bash-full-output.log', 'utf8');
if (!bashFullOutput.includes('bash-line-0000') || !bashFullOutput.includes('bash-line-2104')) {
  throw new Error('tool-bash full-output smoke did not persist the complete output');
}

const ls = run(['tool-ls', '.']);
if (!ls.includes('README.md')) {
  throw new Error('tool-ls smoke did not list README.md');
}
const lsFixture = 'zig-out/pi-zig-ls-fixture';
fs.rmSync(lsFixture, { recursive: true, force: true });
fs.mkdirSync(path.join(lsFixture, 'dir'), { recursive: true });
fs.writeFileSync(path.join(lsFixture, 'zeta.txt'), 'z');
fs.writeFileSync(path.join(lsFixture, 'alpha.txt'), 'a');
fs.writeFileSync(path.join(lsFixture, 'Beta.txt'), 'b');
const sortedLs = run(['tool-ls', lsFixture, '3']);
if (
  !sortedLs.startsWith('alpha.txt\nBeta.txt\ndir/\n') ||
  !sortedLs.includes('[3 entries limit reached. Use limit=6 for more]')
) {
  throw new Error('tool-ls smoke did not sort entries, mark directories, and report entry limits');
}

const grep = run(['tool-grep', 'Zig + Preact', 'README.md', '--literal']);
if (!grep.includes('Zig + Preact porting workspace')) {
  throw new Error('tool-grep smoke did not find README line');
}
const grepFixture = 'zig-out/pi-zig-grep-fixture';
fs.rmSync(grepFixture, { recursive: true, force: true });
fs.mkdirSync(path.join(grepFixture, 'src'), { recursive: true });
fs.writeFileSync(path.join(grepFixture, 'src/a.txt'), ['before', 'Needle alpha', 'after'].join('\n'));
fs.writeFileSync(path.join(grepFixture, 'src/b.md'), ['needle beta', 'skip'].join('\n'));
fs.writeFileSync(path.join(grepFixture, 'src/c.txt'), ['x'.repeat(505) + ' needle gamma'].join('\n'));
const grepDirectory = run(['tool-grep', 'needle', grepFixture, '--glob', '*.txt', '--ignore-case', '--literal', '--context', '1', '--limit', '1']);
if (
  !grepDirectory.includes('src/a.txt-1-before') ||
  !grepDirectory.includes('src/a.txt:2:Needle alpha') ||
  !grepDirectory.includes('src/a.txt-3-after') ||
  grepDirectory.includes('src/b.md') ||
  !grepDirectory.includes('[1 matches limit reached. Use limit=2 for more, or refine pattern]')
) {
  throw new Error('tool-grep directory smoke did not honor glob, ignore-case, literal, context, and match limit');
}
const grepLongLine = run(['tool-grep', 'needle', grepFixture, '--glob', '*.txt', '--ignore-case', '--literal', '--limit', '10']);
if (!grepLongLine.includes('... [truncated]') || !grepLongLine.includes('Some lines truncated to 500 chars')) {
  throw new Error('tool-grep long-line smoke did not truncate long matches with notice');
}

const find = run(['tool-find', 'README.md', '.', '20']);
if (!find.split('\n').includes('README.md')) {
  throw new Error('tool-find smoke did not find README.md');
}
const findFixture = 'zig-out/pi-zig-find-fixture';
fs.rmSync(findFixture, { recursive: true, force: true });
fs.mkdirSync(path.join(findFixture, 'src/nested'), { recursive: true });
fs.mkdirSync(path.join(findFixture, 'docs'), { recursive: true });
fs.writeFileSync(path.join(findFixture, 'src/a.ts'), '');
fs.writeFileSync(path.join(findFixture, 'src/nested/b.ts'), '');
fs.writeFileSync(path.join(findFixture, 'src/nested/c.js'), '');
fs.writeFileSync(path.join(findFixture, 'docs/a.ts'), '');
const findPathPattern = run(['tool-find', 'src/**/*.ts', findFixture, '10']);
if (
  !findPathPattern.split('\n').includes('src/a.ts') ||
  !findPathPattern.split('\n').includes('src/nested/b.ts') ||
  findPathPattern.includes('docs/a.ts') ||
  findPathPattern.includes('src/nested/c.js')
) {
  throw new Error('tool-find path glob smoke did not match upstream-style path-containing patterns');
}
const findDirectory = run(['tool-find', 'nested', findFixture, '10']);
if (!findDirectory.split('\n').includes('src/nested/')) {
  throw new Error('tool-find smoke did not include matching directories with trailing slash');
}
fs.writeFileSync(path.join(findFixture, 'one.txt'), '');
fs.writeFileSync(path.join(findFixture, 'two.txt'), '');
fs.writeFileSync(path.join(findFixture, 'three.txt'), '');
const findLimit = run(['tool-find', '*.txt', findFixture, '2']);
if (!findLimit.includes('[2 results limit reached. Use limit=4 for more, or refine pattern]')) {
  throw new Error('tool-find smoke did not report upstream-style result limit notice');
}
const findLargeFixture = 'zig-out/pi-zig-find-large-fixture';
fs.rmSync(findLargeFixture, { recursive: true, force: true });
fs.mkdirSync(path.join(findLargeFixture, 'very-long-directory-name-for-byte-truncation'), { recursive: true });
for (let index = 0; index < 760; index += 1) {
  fs.writeFileSync(
    path.join(
      findLargeFixture,
      'very-long-directory-name-for-byte-truncation',
      `entry-${String(index).padStart(4, '0')}-find-byte-truncation-smoke.log`
    ),
    ''
  );
}
const findLarge = run(['tool-find', '*.log', findLargeFixture, '1000']);
if (!findLarge.includes('50.0KB limit reached')) {
  throw new Error('tool-find smoke did not report byte truncation notice');
}
const findIgnoreFixture = 'zig-out/pi-zig-find-ignore-fixture';
fs.rmSync(findIgnoreFixture, { recursive: true, force: true });
fs.mkdirSync(path.join(findIgnoreFixture, 'src/generated'), { recursive: true });
fs.mkdirSync(path.join(findIgnoreFixture, 'build'), { recursive: true });
fs.mkdirSync(path.join(findIgnoreFixture, 'nested'), { recursive: true });
fs.writeFileSync(
  path.join(findIgnoreFixture, '.gitignore'),
  ['# root ignore rules', '*.log', '!keep.log', '/root-only.txt', 'build/'].join('\n')
);
fs.writeFileSync(path.join(findIgnoreFixture, 'src/.gitignore'), ['*.tmp', '!keep.tmp', 'generated/'].join('\n'));
fs.writeFileSync(path.join(findIgnoreFixture, 'error.log'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'keep.log'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'root-only.txt'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'nested/root-only.txt'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'build/out.txt'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'src/local.tmp'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'src/keep.tmp'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'src/generated/drop.ts'), '');
fs.writeFileSync(path.join(findIgnoreFixture, 'src/visible.ts'), '');
const findIgnoreLogs = run(['tool-find', '*.log', findIgnoreFixture, '20']);
if (findIgnoreLogs.includes('error.log') || !findIgnoreLogs.split('\n').includes('keep.log')) {
  throw new Error('tool-find .gitignore smoke did not apply basename ignore and negation rules');
}
const findIgnoreTemps = run(['tool-find', '*.tmp', findIgnoreFixture, '20']);
if (findIgnoreTemps.includes('src/local.tmp') || !findIgnoreTemps.split('\n').includes('src/keep.tmp')) {
  throw new Error('tool-find .gitignore smoke did not apply nested ignore and negation rules');
}
const findIgnoreTexts = run(['tool-find', '*.txt', findIgnoreFixture, '20']);
const findIgnoreTextLines = findIgnoreTexts.split('\n');
if (
  findIgnoreTextLines.includes('root-only.txt') ||
  findIgnoreTextLines.includes('build/out.txt') ||
  !findIgnoreTextLines.includes('nested/root-only.txt')
) {
  throw new Error('tool-find .gitignore smoke did not apply rooted and directory ignore rules');
}
const findIgnoreTs = run(['tool-find', '*.ts', findIgnoreFixture, '20']);
if (findIgnoreTs.includes('src/generated/drop.ts') || !findIgnoreTs.split('\n').includes('src/visible.ts')) {
  throw new Error('tool-find .gitignore smoke did not skip ignored nested directories');
}

const writeOutput = run(['tool-write', 'zig-out/pi-zig-tool-write-smoke/nested/write.txt', 'pi-zig write smoke']);
if (!writeOutput.includes('Successfully wrote 18 bytes to zig-out/pi-zig-tool-write-smoke/nested/write.txt')) {
  throw new Error('tool-write smoke did not report bytes written');
}
const written = run(['tool-read', 'zig-out/pi-zig-tool-write-smoke/nested/write.txt']);
if (written !== 'pi-zig write smoke') {
  throw new Error('tool-write smoke did not create parent directories and round-trip content');
}

run(['tool-write', 'zig-out/pi-zig-tool-edit-smoke.txt', 'alpha beta']);
const edit = run(['tool-edit', 'zig-out/pi-zig-tool-edit-smoke.txt', 'beta', 'gamma']);
if (!edit.includes('Successfully replaced 1 block(s)')) {
  throw new Error('tool-edit smoke did not report success');
}
const edited = run(['tool-read', 'zig-out/pi-zig-tool-edit-smoke.txt']);
if (edited !== 'alpha gamma') {
  throw new Error('tool-edit smoke did not update content');
}
const editMultiFixture = 'zig-out/pi-zig-tool-edit-multi-smoke.txt';
fs.writeFileSync(
  editMultiFixture,
  Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('alpha\r\nbeta\r\ngamma\r\n')])
);
const editMulti = run(['tool-edit', editMultiFixture, 'alpha\nbeta', 'one\ntwo', 'gamma', 'delta']);
if (!editMulti.includes('Successfully replaced 2 block(s)')) {
  throw new Error('tool-edit multi-edit smoke did not report two replacements');
}
const editMultiBytes = fs.readFileSync(editMultiFixture);
const hasBom = editMultiBytes[0] === 0xef && editMultiBytes[1] === 0xbb && editMultiBytes[2] === 0xbf;
if (!hasBom || editMultiBytes.subarray(3).toString('utf8') !== 'one\r\ntwo\r\ndelta\r\n') {
  throw new Error('tool-edit multi-edit smoke did not preserve BOM and CRLF line endings');
}
const editDuplicateFixture = 'zig-out/pi-zig-tool-edit-duplicate-smoke.txt';
fs.writeFileSync(editDuplicateFixture, 'repeat repeat');
runFail(['tool-edit', editDuplicateFixture, 'repeat', 'once']);
if (fs.readFileSync(editDuplicateFixture, 'utf8') !== 'repeat repeat') {
  throw new Error('tool-edit duplicate-target failure mutated the file');
}
const editOverlapFixture = 'zig-out/pi-zig-tool-edit-overlap-smoke.txt';
fs.writeFileSync(editOverlapFixture, 'abcdef');
runFail(['tool-edit', editOverlapFixture, 'abc', 'x', 'bcd', 'y']);
if (fs.readFileSync(editOverlapFixture, 'utf8') !== 'abcdef') {
  throw new Error('tool-edit overlap failure mutated the file');
}

const rpcProviderSessionFile = 'zig-out/pi-zig-rpc-provider-smoke.jsonl';
const rpcProviderAuthDir = path.resolve('zig-out/pi-zig-rpc-provider-auth');
fs.rmSync(rpcProviderSessionFile, { force: true });
fs.rmSync(rpcProviderAuthDir, { recursive: true, force: true });
const rpcFakeProvider = await startFakeProviderServer();
try {
  const rpcProviderEnv = {
    ...process.env,
    OPENAI_API_KEY: 'fake-provider-key',
    PI_ZIG_PROVIDER_BASE_URL: rpcFakeProvider.baseUrl,
    PI_CODING_AGENT_DIR: rpcProviderAuthDir
  };
  async function runRpcRetryAbortDelaySmoke() {
    const sessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-abort-delay-smoke.jsonl');
    fs.rmSync(sessionFile, { force: true });
    const child = spawn(bin, ['rpc', sessionFile], {
      env: rpcProviderEnv,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    let pending = '';
    const lines = [];
    const waiters = [];
    function failWaiters(error) {
      while (waiters.length > 0) {
        const waiter = waiters.pop();
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    }
    function resolveWaiters(line) {
      for (let index = 0; index < waiters.length;) {
        const waiter = waiters[index];
        if (waiter.predicate(line)) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timeout);
          waiter.resolve(line);
        } else {
          index += 1;
        }
      }
    }
    function waitForLine(predicate, timeoutMs = 2500) {
      const existing = lines.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const error = new Error(`timed out waiting for RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
          const index = waiters.findIndex((waiter) => waiter.reject === reject);
          if (index !== -1) waiters.splice(index, 1);
          reject(error);
        }, timeoutMs);
        waiters.push({ predicate, resolve, reject, timeout });
      });
    }
    function writeCommand(command) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        try {
          const line = JSON.parse(rawLine);
          lines.push(line);
          resolveWaiters(line);
        } catch (error) {
          failWaiters(new Error(`failed to parse RPC JSON line: ${rawLine}\n${error.message}`));
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exitPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error(`rpc retry abort delay smoke timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, 7000);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(`rpc retry abort delay smoke exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          return;
        }
        resolve();
      });
    });

    writeCommand({ id: 'rpc-retry-abort-delay-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    await waitForLine((line) => line.id === 'rpc-retry-abort-delay-model' && line.success === true);
    writeCommand({ id: 'rpc-retry-abort-delay-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 1000, maxDelayMs: 1000 });
    await waitForLine((line) => line.id === 'rpc-retry-abort-delay-enable' && line.success === true);
    writeCommand({ id: 'rpc-retry-abort-delay-prompt', type: 'prompt', message: 'rpc retry abort delay' });
    const retryStart = await waitForLine((line) => line.type === 'auto_retry_start' && line.attempt === 1);
    writeCommand({ id: 'rpc-retry-abort-delay-abort', type: 'abort_retry' });
    const abortResponse = await waitForLine((line) => line.id === 'rpc-retry-abort-delay-abort');
    const retryEnd = await waitForLine((line) => line.type === 'auto_retry_end' && line.success === false);
    writeCommand({ id: 'rpc-retry-abort-delay-state', type: 'get_state' });
    const state = await waitForLine((line) => line.id === 'rpc-retry-abort-delay-state');
    child.stdin.end();
    await exitPromise;

    const summary = lines
      .filter((line) => ['agent_end', 'auto_retry_start', 'auto_retry_end'].includes(line.type))
      .map((line) => {
        if (line.type === 'agent_end') return `agent_end:${line.willRetry}`;
        if (line.type === 'auto_retry_start') return `auto_retry_start:${line.attempt}:${line.maxAttempts}:${line.delayMs}:${line.errorMessage}`;
        return `auto_retry_end:${line.success}:${line.attempt}:${line.finalError}`;
      });
    if (
      retryStart.maxAttempts !== 2 ||
      retryStart.delayMs !== 1000 ||
      retryStart.errorMessage !== 'ProviderRequestFailed' ||
      !abortResponse.success ||
      retryEnd.finalError !== 'Retry cancelled' ||
      state.data?.autoRetryEnabled !== true ||
      state.data?.autoRetryMaxAttempts !== 2 ||
      state.data?.autoRetryBaseDelayMs !== 1000 ||
      state.data?.autoRetryMaxDelayMs !== 1000 ||
      state.data?.lastRetryAttempts !== 1 ||
      state.data?.lastRetryDelayMs !== 1000 ||
      state.data?.isRetrying !== false ||
      lines.some((line) => line.type === 'auto_retry_start' && line.attempt === 2) ||
      lines.some((line) => line.type === 'auto_retry_end' && line.success === true) ||
      stdout.includes('rpc retry abort delay unexpectedly recovered') ||
      JSON.stringify(summary) !== JSON.stringify([
        'agent_end:true',
        'auto_retry_start:1:2:1000:ProviderRequestFailed',
        'auto_retry_end:false:1:Retry cancelled'
      ])
    ) {
      throw new Error(`rpc retry abort delay smoke did not cancel retry sleep\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
  }

  async function runRpcProviderAbortInFlightSmoke() {
    const sessionFile = path.resolve('zig-out/pi-zig-rpc-provider-abort-in-flight-smoke.jsonl');
    const markerFile = path.resolve('zig-out/pi-zig-rpc-provider-abort-in-flight.started');
    fs.rmSync(sessionFile, { force: true });
    fs.rmSync(markerFile, { force: true });
    const child = spawn(bin, ['rpc', sessionFile], {
      env: rpcProviderEnv,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    let pending = '';
    const lines = [];
    const waiters = [];
    function failWaiters(error) {
      while (waiters.length > 0) {
        const waiter = waiters.pop();
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    }
    function resolveWaiters(line) {
      for (let index = 0; index < waiters.length;) {
        const waiter = waiters[index];
        if (waiter.predicate(line)) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timeout);
          waiter.resolve(line);
        } else {
          index += 1;
        }
      }
    }
    function waitForLine(predicate, timeoutMs = 2500) {
      const existing = lines.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const error = new Error(`timed out waiting for RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
          const index = waiters.findIndex((waiter) => waiter.reject === reject);
          if (index !== -1) waiters.splice(index, 1);
          reject(error);
        }, timeoutMs);
        waiters.push({ predicate, resolve, reject, timeout });
      });
    }
    function waitForFile(file, timeoutMs = 1000) {
      return new Promise((resolve, reject) => {
        const started = Date.now();
        const interval = setInterval(() => {
          if (fs.existsSync(file)) {
            clearInterval(interval);
            resolve();
            return;
          }
          if (Date.now() - started > timeoutMs) {
            clearInterval(interval);
            reject(new Error(`timed out waiting for ${file}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          }
        }, 25);
      });
    }
    function writeCommand(command) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        try {
          const line = JSON.parse(rawLine);
          lines.push(line);
          resolveWaiters(line);
        } catch (error) {
          failWaiters(new Error(`failed to parse RPC JSON line: ${rawLine}\n${error.message}`));
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exitPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error(`rpc provider abort in-flight smoke timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, 7000);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(`rpc provider abort in-flight smoke exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          return;
        }
        resolve();
      });
    });

    writeCommand({ id: 'rpc-provider-abort-in-flight-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    await waitForLine((line) => line.id === 'rpc-provider-abort-in-flight-model' && line.success === true);
    writeCommand({ id: 'rpc-provider-abort-in-flight-prompt', type: 'prompt', message: 'rpc provider abort in flight' });
    await waitForFile(markerFile);
    writeCommand({ id: 'rpc-provider-abort-in-flight-abort', type: 'abort' });
    const abortResponse = await waitForLine((line) => line.id === 'rpc-provider-abort-in-flight-abort', 700);
    const promptResponse = await waitForLine((line) => line.id === 'rpc-provider-abort-in-flight-prompt', 2500);
    writeCommand({ id: 'rpc-provider-abort-in-flight-messages', type: 'get_messages' });
    const messagesResponse = await waitForLine((line) => line.id === 'rpc-provider-abort-in-flight-messages', 2500);
    child.stdin.end();
    await exitPromise;
    const sessionEntries = fs.readFileSync(sessionFile, 'utf8')
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    const persistedAssistant = sessionEntries
      .filter((entry) => entry.type === 'message' && entry.message?.role === 'assistant')
      .at(-1)?.message;
    const exposedAssistant = messagesResponse?.data?.messages
      ?.filter((message) => message.role === 'assistant')
      ?.at(-1);
    const abortLifecycle = lines
      .filter((line) => ['message_start', 'message_end', 'turn_end', 'agent_end'].includes(line.type))
      .map((line) => {
        if (line.type === 'agent_end') return `agent_end:${line.messages?.[0]?.stopReason}`;
        return `${line.type}:${line.message?.stopReason}`;
      });

    if (
      !abortResponse?.success ||
      promptResponse?.success !== false ||
      promptResponse?.error !== 'AgentAborted' ||
      exposedAssistant?.stopReason !== 'aborted' ||
      exposedAssistant?.errorMessage !== 'Request was aborted' ||
      persistedAssistant?.stopReason !== 'aborted' ||
      persistedAssistant?.errorMessage !== 'Request was aborted' ||
      JSON.stringify(abortLifecycle) !== JSON.stringify([
        'message_start:aborted',
        'message_end:aborted',
        'turn_end:aborted',
        'agent_end:aborted'
      ]) ||
      stdout.includes('rpc provider abort unexpectedly completed')
    ) {
      throw new Error(`rpc provider abort in-flight smoke did not cancel the active prompt\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
  }

  async function runRpcProviderActiveExtensionQueueSmoke(kind, viaPrompt = false) {
    const isFollow = kind === 'follow';
    const rpcCommand = viaPrompt ? 'prompt' : isFollow ? 'follow_up' : 'steer';
    const modeLabel = viaPrompt ? 'prompt-command' : 'queue';
    const sessionFile = path.resolve(`zig-out/pi-zig-rpc-provider-extension-active-${kind}-${modeLabel}-smoke.jsonl`);
    const markerFile = path.resolve(`zig-out/pi-zig-rpc-provider-extension-active-${kind}.started`);
    const releaseFile = path.resolve(`zig-out/pi-zig-rpc-provider-extension-active-${kind}.release`);
    fs.rmSync(sessionFile, { force: true });
    fs.rmSync(markerFile, { force: true });
    fs.rmSync(releaseFile, { force: true });
    const child = spawn(
      bin,
      ['--mode', 'rpc', '--session', sessionFile, '--extension', 'extensions/command-exec.mjs'],
      {
        cwd: commandsFixtureRoot,
        env: { ...rpcProviderEnv, HOME: commandsFixtureHome },
        stdio: ['pipe', 'pipe', 'pipe']
      }
    );
    let stdout = '';
    let stderr = '';
    let pending = '';
    const lines = [];
    const waiters = [];
    function failWaiters(error) {
      while (waiters.length > 0) {
        const waiter = waiters.shift();
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    }
    function resolveWaiters(line) {
      for (let index = 0; index < waiters.length;) {
        const waiter = waiters[index];
        if (waiter.predicate(line)) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timeout);
          waiter.resolve(line);
        } else {
          index += 1;
        }
      }
    }
    function waitForLine(predicate, timeoutMs = 4000) {
      const existing = lines.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const error = new Error(`timed out waiting for active extension ${kind} ${modeLabel} RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
          const index = waiters.findIndex((waiter) => waiter.reject === reject);
          if (index !== -1) waiters.splice(index, 1);
          reject(error);
        }, timeoutMs);
        waiters.push({ predicate, resolve, reject, timeout });
      });
    }
    function waitForFile(file, timeoutMs = 2500) {
      return new Promise((resolve, reject) => {
        const started = Date.now();
        const interval = setInterval(() => {
          if (fs.existsSync(file)) {
            clearInterval(interval);
            resolve();
            return;
          }
          if (Date.now() - started > timeoutMs) {
            clearInterval(interval);
            reject(new Error(`timed out waiting for ${file}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          }
        }, 25);
      });
    }
    function writeCommand(command) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        try {
          const line = JSON.parse(rawLine);
          lines.push(line);
          resolveWaiters(line);
        } catch (error) {
          failWaiters(new Error(`failed to parse active extension ${kind} ${modeLabel} RPC JSON line: ${rawLine}\n${error.message}`));
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exitPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error(`active extension ${kind} ${modeLabel} smoke timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, 9000);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(`active extension ${kind} ${modeLabel} smoke exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          return;
        }
        resolve();
      });
    });

    writeCommand({ id: `rpc-active-${kind}-${modeLabel}-model`, type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-model` && line.success === true);
    writeCommand({ id: `rpc-active-${kind}-${modeLabel}-prompt`, type: 'prompt', message: `rpc active extension ${kind} start` });
    await waitForFile(markerFile);
    writeCommand({
      id: `rpc-active-${kind}-${modeLabel}-user-command`,
      type: rpcCommand,
      message: isFollow
        ? '/send-user-follow-active /write-marker active raw follow'
        : '/send-user-steer-active /write-marker active raw steer'
    });
    const userCommandResponse = await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-user-command`, 1000);
    writeCommand({
      id: `rpc-active-${kind}-${modeLabel}-custom-command`,
      type: rpcCommand,
      message: isFollow
        ? '/send-custom-follow-active rpc active custom follow'
        : '/send-custom-steer-active rpc active custom steer'
    });
    const customCommandResponse = await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-custom-command`, 1000);
    fs.writeFileSync(releaseFile, 'release');
    const promptResponse = await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-prompt`, 5000);
    writeCommand({ id: `rpc-active-${kind}-${modeLabel}-messages`, type: 'get_messages' });
    const messagesResponse = await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-messages`, 2500);
    writeCommand({ id: `rpc-active-${kind}-${modeLabel}-state`, type: 'get_state' });
    const stateResponse = await waitForLine((line) => line.id === `rpc-active-${kind}-${modeLabel}-state`, 2500);
    child.stdin.end();
    await exitPromise;

    const messages = messagesResponse?.data?.messages ?? [];
    const assistantTexts = messages.filter((message) => message.role === 'assistant').map((message) => message.content);
    const rawUserText = isFollow ? '/write-marker active raw follow' : '/write-marker active raw steer';
    const customType = isFollow ? 'active-follow-extension' : 'active-steer-extension';
    const customText = isFollow ? 'rpc active custom follow' : 'rpc active custom steer';
    const sessionText = fs.readFileSync(sessionFile, 'utf8');
    const steerBaseIndex = assistantTexts.indexOf('rpc active extension steer base complete');
    const followBaseIndex = assistantTexts.indexOf('rpc active extension follow base complete');
    const followObservedIndex = assistantTexts.indexOf('rpc active extension follow observed');
    if (
      !userCommandResponse?.success ||
      !customCommandResponse?.success ||
      customCommandResponse?.data?.pendingMessageCount !== 2 ||
      customCommandResponse?.data?.steeringCount !== (isFollow ? 0 : 2) ||
      customCommandResponse?.data?.followUpCount !== (isFollow ? 2 : 0) ||
      promptResponse?.data?.text !== `rpc active extension ${kind} observed` ||
      stateResponse?.data?.pendingMessageCount !== 0 ||
      stateResponse?.data?.pendingSteeringCount !== 0 ||
      stateResponse?.data?.pendingFollowUpCount !== 0 ||
      !messages.some((message) => message.role === 'user' && message.content === rawUserText) ||
      !messages.some((message) => message.role === 'custom' && message.customType === customType && message.content === customText && message.display === true) ||
      messages.some((message) => typeof message.content === 'string' && message.content.includes(`/send-user-${isFollow ? 'follow' : 'steer'}-active`)) ||
      messages.some((message) => typeof message.content === 'string' && message.content.includes(`/send-custom-${isFollow ? 'follow' : 'steer'}-active`)) ||
      !sessionText.includes('"type":"custom_message"') ||
      !sessionText.includes(`"customType":"${customType}"`) ||
      (!isFollow && steerBaseIndex !== -1) ||
      (isFollow && (followBaseIndex === -1 || followObservedIndex === -1 || followBaseIndex > followObservedIndex))
    ) {
      throw new Error(`active extension ${kind} ${modeLabel} smoke failed\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
  }

  async function runRpcProviderPromptStreamingBehaviorSmoke(kind) {
    const isFollow = kind === 'follow';
    const sessionFile = path.resolve(`zig-out/pi-zig-rpc-provider-prompt-streaming-${kind}-smoke.jsonl`);
    const markerFile = path.resolve(`zig-out/pi-zig-rpc-provider-prompt-streaming-${kind}.started`);
    const releaseFile = path.resolve(`zig-out/pi-zig-rpc-provider-prompt-streaming-${kind}.release`);
    fs.rmSync(sessionFile, { force: true });
    fs.rmSync(markerFile, { force: true });
    fs.rmSync(releaseFile, { force: true });
    const child = spawn(bin, ['--mode', 'rpc', '--session', sessionFile], {
      env: rpcProviderEnv,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    let pending = '';
    const lines = [];
    const waiters = [];
    function failWaiters(error) {
      while (waiters.length > 0) {
        const waiter = waiters.shift();
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    }
    function resolveWaiters(line) {
      for (let index = 0; index < waiters.length;) {
        const waiter = waiters[index];
        if (waiter.predicate(line)) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timeout);
          waiter.resolve(line);
        } else {
          index += 1;
        }
      }
    }
    function waitForLine(predicate, timeoutMs = 4000) {
      const existing = lines.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const error = new Error(`timed out waiting for prompt streaming ${kind} RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
          const index = waiters.findIndex((waiter) => waiter.reject === reject);
          if (index !== -1) waiters.splice(index, 1);
          reject(error);
        }, timeoutMs);
        waiters.push({ predicate, resolve, reject, timeout });
      });
    }
    function waitForFile(file, timeoutMs = 2500) {
      return new Promise((resolve, reject) => {
        const started = Date.now();
        const interval = setInterval(() => {
          if (fs.existsSync(file)) {
            clearInterval(interval);
            resolve();
            return;
          }
          if (Date.now() - started > timeoutMs) {
            clearInterval(interval);
            reject(new Error(`timed out waiting for ${file}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          }
        }, 25);
      });
    }
    function writeCommand(command) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        try {
          const line = JSON.parse(rawLine);
          lines.push(line);
          resolveWaiters(line);
        } catch (error) {
          failWaiters(new Error(`failed to parse prompt streaming ${kind} RPC JSON line: ${rawLine}\n${error.message}`));
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exitPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error(`prompt streaming ${kind} smoke timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, 9000);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(`prompt streaming ${kind} smoke exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          return;
        }
        resolve();
      });
    });

    writeCommand({ id: `rpc-prompt-streaming-${kind}-model`, type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-model` && line.success === true);
    writeCommand({ id: `rpc-prompt-streaming-${kind}-start`, type: 'prompt', message: `rpc active prompt streaming ${kind} start` });
    await waitForFile(markerFile);
    writeCommand({
      id: `rpc-prompt-streaming-${kind}-missing`,
      type: 'prompt',
      message: `rpc active prompt streaming ${kind} missing behavior`
    });
    const missingResponse = await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-missing`, 1000);
    let truthyFallbackResponse = null;
    if (!isFollow) {
      writeCommand({
        id: `rpc-prompt-streaming-${kind}-truthy-fallback`,
        type: 'prompt',
        message: `rpc active prompt streaming ${kind} truthy fallback`,
        streamingBehavior: 'later'
      });
      truthyFallbackResponse = await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-truthy-fallback`, 1000);
    }
    writeCommand({
      id: `rpc-prompt-streaming-${kind}-queued`,
      type: 'prompt',
      message: `rpc active prompt streaming ${kind} queued`,
      streamingBehavior: isFollow ? 'followUp' : 'steer'
    });
    const queuedResponse = await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-queued`, 1000);
    fs.writeFileSync(releaseFile, 'release');
    const promptResponse = await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-start`, 5000);
    writeCommand({ id: `rpc-prompt-streaming-${kind}-messages`, type: 'get_messages' });
    const messagesResponse = await waitForLine((line) => line.id === `rpc-prompt-streaming-${kind}-messages`, 2500);
    child.stdin.end();
    await exitPromise;

    const messages = messagesResponse?.data?.messages ?? [];
    const assistantTexts = messages.filter((message) => message.role === 'assistant').map((message) => message.content);
    const baseIndex = assistantTexts.indexOf(`rpc active prompt streaming ${kind} base complete`);
    const observedIndex = assistantTexts.indexOf(`rpc active prompt streaming ${kind} observed`);
    if (
      missingResponse?.success !== false ||
      !String(missingResponse?.error ?? '').includes('streamingBehavior') ||
      (!isFollow && (!truthyFallbackResponse?.success ||
        truthyFallbackResponse?.data?.pendingMessageCount !== 1 ||
        truthyFallbackResponse?.data?.steeringCount !== 1 ||
        truthyFallbackResponse?.data?.followUpCount !== 0)) ||
      !queuedResponse?.success ||
      queuedResponse?.data?.pendingMessageCount !== (isFollow ? 1 : 2) ||
      queuedResponse?.data?.steeringCount !== (isFollow ? 0 : 2) ||
      queuedResponse?.data?.followUpCount !== (isFollow ? 1 : 0) ||
      promptResponse?.data?.text !== `rpc active prompt streaming ${kind} observed` ||
      (!isFollow && !messages.some((message) => message.role === 'user' && message.content === `rpc active prompt streaming ${kind} truthy fallback`)) ||
      !messages.some((message) => message.role === 'user' && message.content === `rpc active prompt streaming ${kind} queued`) ||
      (!isFollow && baseIndex !== -1) ||
      (isFollow && (baseIndex === -1 || observedIndex === -1 || baseIndex > observedIndex))
    ) {
      throw new Error(`prompt streaming ${kind} smoke failed\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
  }

  async function runRpcProviderActiveResourcePromptSmoke(kind) {
    const isFollow = kind === 'follow';
    const sessionFile = path.resolve(`zig-out/pi-zig-rpc-provider-active-resource-${kind}-smoke.jsonl`);
    const markerFile = path.resolve(`zig-out/pi-zig-rpc-provider-active-resource-${kind}.started`);
    const releaseFile = path.resolve(`zig-out/pi-zig-rpc-provider-active-resource-${kind}.release`);
    fs.rmSync(sessionFile, { force: true });
    fs.rmSync(markerFile, { force: true });
    fs.rmSync(releaseFile, { force: true });
    const child = spawn(bin, ['--mode', 'rpc', '--session', sessionFile], {
      cwd: commandsFixtureRoot,
      env: { ...rpcProviderEnv, HOME: commandsFixtureHome },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    let pending = '';
    const lines = [];
    const waiters = [];
    function failWaiters(error) {
      while (waiters.length > 0) {
        const waiter = waiters.shift();
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    }
    function resolveWaiters(line) {
      for (let index = 0; index < waiters.length;) {
        const waiter = waiters[index];
        if (waiter.predicate(line)) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timeout);
          waiter.resolve(line);
        } else {
          index += 1;
        }
      }
    }
    function waitForLine(predicate, timeoutMs = 4000) {
      const existing = lines.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const error = new Error(`timed out waiting for active resource ${kind} RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`);
          const index = waiters.findIndex((waiter) => waiter.reject === reject);
          if (index !== -1) waiters.splice(index, 1);
          reject(error);
        }, timeoutMs);
        waiters.push({ predicate, resolve, reject, timeout });
      });
    }
    function waitForFile(file, timeoutMs = 2500) {
      return new Promise((resolve, reject) => {
        const started = Date.now();
        const interval = setInterval(() => {
          if (fs.existsSync(file)) {
            clearInterval(interval);
            resolve();
            return;
          }
          if (Date.now() - started > timeoutMs) {
            clearInterval(interval);
            reject(new Error(`timed out waiting for ${file}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          }
        }, 25);
      });
    }
    function writeCommand(command) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        try {
          const line = JSON.parse(rawLine);
          lines.push(line);
          resolveWaiters(line);
        } catch (error) {
          failWaiters(new Error(`failed to parse active resource ${kind} RPC JSON line: ${rawLine}\n${error.message}`));
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exitPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error(`active resource ${kind} smoke timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, 9000);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(`active resource ${kind} smoke exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
          return;
        }
        resolve();
      });
    });

    writeCommand({ id: `rpc-active-resource-${kind}-model`, type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    await waitForLine((line) => line.id === `rpc-active-resource-${kind}-model` && line.success === true);
    writeCommand({ id: `rpc-active-resource-${kind}-start`, type: 'prompt', message: `rpc active slash resource ${kind} start` });
    await waitForFile(markerFile);
    writeCommand({
      id: `rpc-active-resource-${kind}-queued`,
      type: 'prompt',
      message: '/resource-check alpha "beta gamma" delta',
      streamingBehavior: isFollow ? 'followUp' : 'steer'
    });
    const queuedResponse = await waitForLine((line) => line.id === `rpc-active-resource-${kind}-queued`, 1000);
    fs.writeFileSync(releaseFile, 'release');
    const promptResponse = await waitForLine((line) => line.id === `rpc-active-resource-${kind}-start`, 5000);
    writeCommand({ id: `rpc-active-resource-${kind}-messages`, type: 'get_messages' });
    const messagesResponse = await waitForLine((line) => line.id === `rpc-active-resource-${kind}-messages`, 2500);
    child.stdin.end();
    await exitPromise;

    const messages = messagesResponse?.data?.messages ?? [];
    const assistantTexts = messages.filter((message) => message.role === 'assistant').map((message) => message.content);
    const baseIndex = assistantTexts.indexOf(`rpc active slash resource ${kind} base complete`);
    const observedIndex = assistantTexts.indexOf(`rpc active slash resource ${kind} observed`);
    if (
      !queuedResponse?.success ||
      queuedResponse?.data?.pendingMessageCount !== 1 ||
      queuedResponse?.data?.steeringCount !== (isFollow ? 0 : 1) ||
      queuedResponse?.data?.followUpCount !== (isFollow ? 1 : 0) ||
      promptResponse?.data?.text !== `rpc active slash resource ${kind} observed` ||
      !messages.some((message) => message.role === 'user' && message.content === 'rpc slash prompt template expansion: first=alpha rest=beta gamma delta all=alpha "beta gamma" delta') ||
      messages.some((message) => typeof message.content === 'string' && message.content.includes('/resource-check')) ||
      (!isFollow && baseIndex !== -1) ||
      (isFollow && (baseIndex === -1 || observedIndex === -1 || baseIndex > observedIndex))
    ) {
      throw new Error(`active resource ${kind} smoke failed\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
  }

  const rpcExtensionHookFixture = path.resolve('zig-out/pi-zig-rpc-extension-hook-fixture');
  fs.rmSync(rpcExtensionHookFixture, { recursive: true, force: true });
  fs.mkdirSync(rpcExtensionHookFixture, { recursive: true });
  const rpcExtensionHookPath = path.join(rpcExtensionHookFixture, 'hook.mjs');
  fs.writeFileSync(rpcExtensionHookPath, `
export default function(pi) {
  pi.on("tool_call", (event) => {
    if (event.toolName === "bash" && event.input.command === "printf extension-original") {
      event.input.command = "printf extension-rewritten-ok";
    }
  });
  pi.on("tool_result", (event) => {
    const text = Array.isArray(event.content)
      ? event.content.filter((part) => part?.type === "text").map((part) => part.text ?? "").join("\\n")
      : "";
    if (event.toolName === "bash" && text.trim() === "extension-rewritten-ok") {
      return { content: [{ type: "text", text: "extension-result-patched" }], isError: false };
    }
  });
}
`);
  const rpcExtensionToolPath = path.join(rpcExtensionHookFixture, 'tool.mjs');
  fs.writeFileSync(rpcExtensionToolPath, `
export default function(pi) {
  pi.registerTool({
    name: "ext_echo",
    label: "Extension Echo",
    description: "Echo a value through an explicit extension tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId, params) => ({
      content: [{ type: "text", text: "ext-echo: " + params.value }],
      isError: false
    })
  });
}
`);
  const rpcExtensionFlagToolPath = path.join(rpcExtensionHookFixture, 'flag-tool.mjs');
  fs.writeFileSync(rpcExtensionFlagToolPath, `
export default function(pi) {
  pi.registerFlag("plan", { default: "default-plan" });
  pi.registerFlag("debug-flag", { default: false });
  pi.registerTool({
    name: "ext_flag_echo",
    label: "Extension Flag Echo",
    description: "Echo values from extension flags",
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false
    },
    execute: async () => ({
      content: [{
        type: "text",
        text: "ext-flag: plan=" + String(pi.getFlag("plan")) + ";debug=" + String(pi.getFlag("debug-flag")) + ";missing=" + String(pi.getFlag("missing"))
      }],
      isError: false
    })
  });
}
`);
  const rpcExtensionPermissionGatePath = path.join(rpcExtensionHookFixture, 'permission-gate.mjs');
  fs.writeFileSync(rpcExtensionPermissionGatePath, `
export default function(pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash" && event.input.command === "printf should-not-run") {
      const allowed = await ctx.ui.confirm("Run bash command?", event.input.command);
      if (!allowed) {
        return { block: true, reason: "blocked by headless permission gate" };
      }
    }
  });
}
`);
  const rpcExtensionBashOverridePath = path.join(rpcExtensionHookFixture, 'bash-override.mjs');
  fs.writeFileSync(rpcExtensionBashOverridePath, `
export default function(pi) {
  pi.registerTool({
    name: "bash",
    label: "Extension Bash Override",
    description: "Extension override for the built-in bash tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId, params) => ({
      content: [{ type: "text", text: "ext-bash: " + params.value }],
      isError: false
    })
  });
}
`);
  const rpcExtensionTsHelperPath = path.join(rpcExtensionHookFixture, 'helper.ts');
  fs.writeFileSync(rpcExtensionTsHelperPath, `
export const prefix: string = "ext-ts-echo";
`);
  const rpcExtensionTsToolPath = path.join(rpcExtensionHookFixture, 'tool.ts');
  fs.writeFileSync(rpcExtensionTsToolPath, `
import { prefix } from "./helper.ts";

type Params = { value: string };

export default function(pi: any): void {
  pi.registerTool({
    name: "ext_ts_echo",
    label: "Extension TS Echo",
    description: "Echo a value through a TypeScript extension tool",
    parameters: {
      type: "object",
      properties: { value: { type: "string" } },
      required: ["value"],
      additionalProperties: false
    },
    execute: async (_toolCallId: string, params: Params) => ({
      content: [{ type: "text", text: prefix + ": " + params.value }],
      isError: false
    })
  });
}
`);
  const rpcExtensionCommandTriggerPath = path.join(rpcExtensionHookFixture, 'command-trigger.mjs');
  fs.writeFileSync(rpcExtensionCommandTriggerPath, `
export default function(pi) {
  pi.registerCommand("trigger-custom", {
    description: "Trigger a provider turn from a custom message",
    handler: async (args) => {
      await pi.sendMessage({ customType: "trigger-extension", content: args, display: true }, { triggerTurn: true });
    }
  });
}
`);
  const rpcDiscoveredExtensionProject = path.resolve('zig-out/pi-zig-rpc-discovered-extension-project');
  fs.rmSync(rpcDiscoveredExtensionProject, { recursive: true, force: true });
  fs.mkdirSync(path.join(rpcDiscoveredExtensionProject, '.pi/extensions'), { recursive: true });
  fs.copyFileSync(rpcExtensionHookPath, path.join(rpcDiscoveredExtensionProject, '.pi/extensions/hook.mjs'));
  fs.copyFileSync(rpcExtensionToolPath, path.join(rpcDiscoveredExtensionProject, '.pi/extensions/tool.mjs'));
  fs.copyFileSync(rpcExtensionTsHelperPath, path.join(rpcDiscoveredExtensionProject, '.pi/extensions/helper.ts'));
  fs.copyFileSync(rpcExtensionTsToolPath, path.join(rpcDiscoveredExtensionProject, '.pi/extensions/tool.ts'));
  const rpcProviderContextFixture = path.resolve('zig-out/pi-zig-rpc-provider-context-fixture');
  const rpcProviderContextCwd = path.join(rpcProviderContextFixture, 'project');
  const rpcProviderContextSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-context-smoke.jsonl');
  fs.rmSync(rpcProviderContextFixture, { recursive: true, force: true });
  fs.rmSync(rpcProviderContextSessionFile, { force: true });
  fs.mkdirSync(path.join(rpcProviderContextCwd, '.pi'), { recursive: true });
  fs.writeFileSync(path.join(rpcProviderContextCwd, 'AGENTS.md'), 'rpc provider project context sentinel');
  fs.writeFileSync(path.join(rpcProviderContextCwd, '.pi', 'APPEND_SYSTEM.md'), 'rpc provider append sentinel');
  const rpcProviderContextOutput = run(
    ['rpc', rpcProviderContextSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-context-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-context-prompt', type: 'prompt', message: 'hello rpc provider context' }),
      ''
    ].join('\n'),
    {
      cwd: rpcProviderContextCwd,
      env: rpcProviderEnv
    }
  );
  const rpcProviderContextResponses = rpcProviderContextOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderContextPrompt = rpcProviderContextResponses.find((response) => response.id === 'rpc-provider-context-prompt');
  if (
    !rpcProviderContextPrompt?.success ||
    !rpcProviderContextPrompt?.data?.text?.includes('mock provider response for gpt-4o: hello rpc provider context') ||
    !rpcProviderContextPrompt?.data?.text?.includes('Available tools:') ||
    !rpcProviderContextPrompt?.data?.text?.includes('read: Read file contents') ||
    !rpcProviderContextPrompt?.data?.text?.includes('rpc provider append sentinel') ||
    !rpcProviderContextPrompt?.data?.text?.includes('rpc provider project context sentinel')
  ) {
    throw new Error('rpc provider prompt smoke did not build a runtime system prompt with context and tool metadata');
  }

  const rpcProviderResourceExpansionSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-resource-expansion-smoke.jsonl');
  fs.rmSync(rpcProviderResourceExpansionSessionFile, { force: true });
  const expectedPromptExpansion = 'rpc slash prompt template expansion: first=alpha rest=beta gamma delta all=alpha "beta gamma" delta';
  const expectedSkillExpansion = [
    '<skill name="resource-skill" location=".pi/skills/resource-skill/SKILL.md">',
    'References are relative to .pi/skills/resource-skill.',
    '',
    'rpc slash skill expansion body',
    '</skill>',
    '',
    'Focus on loaded instructions'
  ].join('\n');
  const { lines: rpcProviderResourceExpansionResponses } = await runRpcSequential(
    ['--mode', 'rpc', '--session', rpcProviderResourceExpansionSessionFile],
    [
      { id: 'rpc-resource-expansion-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' },
      { id: 'rpc-resource-expansion-prompt-template', type: 'prompt', message: '/resource-check alpha "beta gamma" delta' },
      { id: 'rpc-resource-expansion-skill', type: 'prompt', message: '/skill:resource-skill Focus on loaded instructions' },
      { id: 'rpc-resource-expansion-messages', type: 'get_messages' }
    ],
    { cwd: commandsFixtureRoot, env: { ...rpcProviderEnv, HOME: commandsFixtureHome } }
  );
  const rpcProviderResourceExpansionPrompt = rpcProviderResourceExpansionResponses.find(
    (response) => response.id === 'rpc-resource-expansion-prompt-template'
  );
  const rpcProviderResourceExpansionSkill = rpcProviderResourceExpansionResponses.find(
    (response) => response.id === 'rpc-resource-expansion-skill'
  );
  const rpcProviderResourceExpansionMessages = rpcProviderResourceExpansionResponses.find(
    (response) => response.id === 'rpc-resource-expansion-messages'
  );
  const rpcResourceUserMessages = rpcProviderResourceExpansionMessages?.data?.messages
    ?.filter((message) => message.role === 'user')
    ?.map((message) => message.content) ?? [];
  if (
    !rpcProviderResourceExpansionPrompt?.success ||
    rpcProviderResourceExpansionPrompt?.data?.text !== 'rpc slash prompt template expansion observed' ||
    !rpcProviderResourceExpansionSkill?.success ||
    rpcProviderResourceExpansionSkill?.data?.text !== 'rpc slash skill expansion observed' ||
    !rpcResourceUserMessages.includes(expectedPromptExpansion) ||
    !rpcResourceUserMessages.includes(expectedSkillExpansion) ||
    rpcResourceUserMessages.some((content) =>
      typeof content === 'string' &&
      (content.includes('/resource-check') || content.includes('/skill:resource-skill'))
    )
  ) {
    throw new Error('rpc provider slash resource expansion smoke did not expand prompt templates and skills before provider execution');
  }

  const rpcProviderQueuedResourceSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-queued-resource-expansion-smoke.jsonl');
  fs.rmSync(rpcProviderQueuedResourceSessionFile, { force: true });
  const { lines: rpcProviderQueuedResourceResponses } = await runRpcSequential(
    ['rpc', rpcProviderQueuedResourceSessionFile],
    [
      { id: 'rpc-queued-resource-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' },
      { id: 'rpc-queued-resource-steer', type: 'steer', message: '/resource-check alpha "beta gamma" delta' },
      { id: 'rpc-queued-resource-steer-prompt', type: 'prompt', message: 'rpc slash resource steer start' },
      { id: 'rpc-queued-resource-follow', type: 'follow_up', message: '/resource-check alpha "beta gamma" delta' },
      { id: 'rpc-queued-resource-follow-prompt', type: 'prompt', message: 'rpc slash resource follow start' },
      { id: 'rpc-queued-resource-messages', type: 'get_messages' }
    ],
    { cwd: commandsFixtureRoot, env: { ...rpcProviderEnv, HOME: commandsFixtureHome } }
  );
  const rpcProviderQueuedResourceSteer = rpcProviderQueuedResourceResponses.find((response) => response.id === 'rpc-queued-resource-steer');
  const rpcProviderQueuedResourceSteerPrompt = rpcProviderQueuedResourceResponses.find((response) => response.id === 'rpc-queued-resource-steer-prompt');
  const rpcProviderQueuedResourceFollow = rpcProviderQueuedResourceResponses.find((response) => response.id === 'rpc-queued-resource-follow');
  const rpcProviderQueuedResourceFollowPrompt = rpcProviderQueuedResourceResponses.find((response) => response.id === 'rpc-queued-resource-follow-prompt');
  const rpcProviderQueuedResourceMessages = rpcProviderQueuedResourceResponses.find((response) => response.id === 'rpc-queued-resource-messages');
  const rpcQueuedResourceUserMessages = rpcProviderQueuedResourceMessages?.data?.messages
    ?.filter((message) => message.role === 'user')
    ?.map((message) => message.content) ?? [];
  if (
    !rpcProviderQueuedResourceSteer?.success ||
    rpcProviderQueuedResourceSteerPrompt?.data?.text !== 'rpc slash prompt template expansion observed' ||
    !rpcProviderQueuedResourceFollow?.success ||
    rpcProviderQueuedResourceFollowPrompt?.data?.text !== 'rpc slash prompt template expansion observed' ||
    JSON.stringify(rpcQueuedResourceUserMessages) !== JSON.stringify([
      'rpc slash resource steer start',
      expectedPromptExpansion,
      'rpc slash resource follow start',
      expectedPromptExpansion
    ])
  ) {
    throw new Error('rpc provider queued slash resource expansion smoke did not expand direct steer/follow_up resources before queue drain');
  }

  const rpcProviderImageSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-image-smoke.jsonl');
  fs.rmSync(rpcProviderImageSessionFile, { force: true });
  const rpcProviderImageOutput = run(
    ['rpc', rpcProviderImageSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-image-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({
        id: 'rpc-provider-image-prompt',
        type: 'prompt',
        message: 'image input rpc',
        images: [{ type: 'image', data: 'aW1hZ2Utc21va2U=', mimeType: 'image/png' }]
      }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderImageResponses = rpcProviderImageOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderImagePrompt = rpcProviderImageResponses.find((response) => response.id === 'rpc-provider-image-prompt');
  if (!rpcProviderImagePrompt?.success || rpcProviderImagePrompt?.data?.text !== 'image rpc observed') {
    throw new Error('rpc provider prompt smoke did not send image content parts');
  }
  const rpcProviderImageJsonl = fs.readFileSync(rpcProviderImageSessionFile, 'utf8');
  if (
    !rpcProviderImageJsonl.includes('"content":[{"type":"text","text":"image input rpc"},{"type":"image","data":"aW1hZ2Utc21va2U="') ||
    !rpcProviderImageJsonl.includes('"mimeType":"image/png"')
  ) {
    throw new Error('rpc provider image smoke did not persist image content in durable JSONL');
  }
  const rpcProviderImageReplayOutput = run(
    ['rpc', rpcProviderImageSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-image-replay-prompt', type: 'prompt', message: 'rpc image history replay' }),
      JSON.stringify({ id: 'rpc-provider-image-replay-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderImageReplayResponses = rpcProviderImageReplayOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderImageReplayPrompt = rpcProviderImageReplayResponses.find((response) => response.id === 'rpc-provider-image-replay-prompt');
  if (!rpcProviderImageReplayPrompt?.success || rpcProviderImageReplayPrompt?.data?.text !== 'rpc image history observed') {
    throw new Error('rpc provider prompt smoke did not replay persisted image content parts');
  }
  const rpcProviderImageReplayMessages = rpcProviderImageReplayResponses.find((response) => response.id === 'rpc-provider-image-replay-messages');
  const rpcProviderImageReplayUser = rpcProviderImageReplayMessages?.data?.messages?.find((message) => message.role === 'user' && message.content === 'image input rpc');
  if (
    rpcProviderImageReplayUser?.images?.[0]?.type !== 'image' ||
    rpcProviderImageReplayUser?.images?.[0]?.data !== 'aW1hZ2Utc21va2U=' ||
    rpcProviderImageReplayUser?.images?.[0]?.mimeType !== 'image/png'
  ) {
    throw new Error('rpc get_messages smoke did not expose persisted user image content');
  }

  const rpcProviderCommandImageSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-command-image-smoke.jsonl');
  fs.rmSync(rpcProviderCommandImageSessionFile, { force: true });
  const rpcProviderCommandImageOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderCommandImageSessionFile, '--extension', 'extensions/command-exec.mjs'],
    [
      JSON.stringify({ id: 'rpc-provider-command-image-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-command-image-prompt', type: 'prompt', message: '/send-user-image-message rpc command image user' }),
      JSON.stringify({ id: 'rpc-provider-command-image-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { cwd: commandsFixtureRoot, env: { ...rpcProviderEnv, HOME: commandsFixtureHome } }
  );
  const rpcProviderCommandImageResponses = rpcProviderCommandImageOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderCommandImagePrompt = rpcProviderCommandImageResponses.find((response) => response.id === 'rpc-provider-command-image-prompt');
  const rpcProviderCommandImageMessages = rpcProviderCommandImageResponses.find((response) => response.id === 'rpc-provider-command-image-messages');
  const rpcProviderCommandImageUser = rpcProviderCommandImageMessages?.data?.messages?.find((message) => message.role === 'user' && message.content === 'rpc command image user');
  if (
    !rpcProviderCommandImagePrompt?.success ||
    rpcProviderCommandImagePrompt?.data?.text !== 'rpc command image user observed' ||
    rpcProviderCommandImageUser?.images?.[0]?.data !== 'aW1hZ2Utc21va2U=' ||
    rpcProviderCommandImageUser?.images?.[0]?.mimeType !== 'image/png'
  ) {
    throw new Error('rpc provider extension command sendUserMessage image smoke did not forward image content to provider');
  }

  const rpcProviderQueuedImageSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-queued-image-smoke.jsonl');
  fs.rmSync(rpcProviderQueuedImageSessionFile, { force: true });
  const rpcProviderQueuedImageOutput = run(
    ['rpc', rpcProviderQueuedImageSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-queued-image-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-queued-image-steer-mode', type: 'set_steering_mode', mode: 'one-at-a-time' }),
      JSON.stringify({
        id: 'rpc-provider-queued-image-steer',
        type: 'steer',
        message: 'rpc steer image one',
        images: [{ type: 'image', data: 'aW1hZ2Utc21va2U=', mimeType: 'image/png' }]
      }),
      JSON.stringify({
        id: 'rpc-provider-queued-image-prompt',
        type: 'prompt',
        message: 'rpc prompt image before steer',
        images: [{ type: 'image', data: 'aW1hZ2Utc21va2U=', mimeType: 'image/png' }]
      }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderQueuedImageResponses = rpcProviderQueuedImageOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderQueuedImagePrompt = rpcProviderQueuedImageResponses.find((response) => response.id === 'rpc-provider-queued-image-prompt');
  if (!rpcProviderQueuedImagePrompt?.success || rpcProviderQueuedImagePrompt?.data?.text !== 'rpc queued steer image observed') {
    throw new Error('rpc provider prompt smoke did not send queued steer image content parts');
  }

  const rpcProviderFollowImageSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-follow-image-smoke.jsonl');
  fs.rmSync(rpcProviderFollowImageSessionFile, { force: true });
  const rpcProviderFollowImageOutput = run(
    ['rpc', rpcProviderFollowImageSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-follow-image-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-follow-image-mode', type: 'set_follow_up_mode', mode: 'all' }),
      JSON.stringify({
        id: 'rpc-provider-follow-image-one',
        type: 'follow_up',
        message: 'rpc follow image one',
        images: [{ type: 'image', data: 'aW1hZ2Utc21va2U=', mimeType: 'image/png' }]
      }),
      JSON.stringify({
        id: 'rpc-provider-follow-image-two',
        type: 'follow_up',
        message: 'rpc follow image two',
        images: [{ type: 'image', data: 'aW1hZ2Utc21va2U=', mimeType: 'image/png' }]
      }),
      JSON.stringify({ id: 'rpc-provider-follow-image-prompt', type: 'prompt', message: 'rpc follow image start' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderFollowImageResponses = rpcProviderFollowImageOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderFollowImagePrompt = rpcProviderFollowImageResponses.find((response) => response.id === 'rpc-provider-follow-image-prompt');
  if (!rpcProviderFollowImagePrompt?.success || rpcProviderFollowImagePrompt?.data?.text !== 'rpc queued follow image observed') {
    throw new Error('rpc provider prompt smoke did not send queued follow_up image content parts');
  }

  const rpcProviderHistorySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-history-smoke.jsonl');
  fs.rmSync(rpcProviderHistorySessionFile, { force: true });
  const rpcProviderHistoryRun = await runRpcSequential(
    ['rpc', rpcProviderHistorySessionFile],
    [
      { id: 'rpc-provider-history-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' },
      { id: 'rpc-provider-history-first', type: 'prompt', message: 'first rpc history' },
      { id: 'rpc-provider-history-second', type: 'prompt', message: 'second rpc history' },
      { id: 'rpc-provider-history-messages', type: 'get_messages' }
    ],
    { env: rpcProviderEnv }
  );
  const rpcProviderHistoryResponses = rpcProviderHistoryRun.lines;
  const rpcProviderHistorySecond = rpcProviderHistoryResponses.find((response) => response.id === 'rpc-provider-history-second');
  if (!rpcProviderHistorySecond?.success || rpcProviderHistorySecond?.data?.text !== 'rpc history observed') {
    throw new Error('rpc provider prompt smoke did not send prior user/assistant history to the provider');
  }
  const rpcProviderHistoryMessages = rpcProviderHistoryResponses.find((response) => response.id === 'rpc-provider-history-messages');
  if (
    rpcProviderHistoryMessages?.data?.messages?.filter((message) => message.role === 'user').length !== 2 ||
    rpcProviderHistoryMessages?.data?.messages?.filter((message) => message.role === 'assistant').length !== 2
  ) {
    throw new Error('rpc provider history smoke did not persist both user/assistant turns');
  }

  const rpcProviderBashHistorySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-bash-history-smoke.jsonl');
  fs.rmSync(rpcProviderBashHistorySessionFile, { force: true });
  const rpcProviderBashHistoryOutput = run(
    ['rpc', rpcProviderBashHistorySessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-bash-history-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-bash-history-bash', type: 'bash', command: 'printf rpc-history-bash' }),
      JSON.stringify({ id: 'rpc-provider-bash-history-prompt', type: 'prompt', message: 'rpc bash history check' }),
      JSON.stringify({ id: 'rpc-provider-truncated-bash-history-bash', type: 'bash', command: "node -e \"for (let i = 0; i < 2105; i++) console.log('rpc-truncated-history-line-' + String(i).padStart(4, '0'))\"" }),
      JSON.stringify({ id: 'rpc-provider-truncated-bash-history-prompt', type: 'prompt', message: 'rpc truncated bash history check' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderBashHistoryResponses = rpcProviderBashHistoryOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderBashHistoryPrompt = rpcProviderBashHistoryResponses.find((response) => response.id === 'rpc-provider-bash-history-prompt');
  if (!rpcProviderBashHistoryPrompt?.success || rpcProviderBashHistoryPrompt?.data?.text !== 'rpc bash history observed') {
    throw new Error('rpc provider prompt smoke did not send prior bashExecution history to the provider');
  }
  const rpcProviderTruncatedBashHistoryPrompt = rpcProviderBashHistoryResponses.find(
    (response) => response.id === 'rpc-provider-truncated-bash-history-prompt'
  );
  if (
    !rpcProviderTruncatedBashHistoryPrompt?.success ||
    rpcProviderTruncatedBashHistoryPrompt?.data?.text !== 'rpc truncated bash history observed'
  ) {
    throw new Error('rpc provider prompt smoke did not send truncated bashExecution full-output path history to the provider');
  }

  const rpcProviderQueueSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-queue-smoke.jsonl');
  fs.rmSync(rpcProviderQueueSessionFile, { force: true });
  const rpcProviderQueueOutput = run(
    ['rpc', rpcProviderQueueSessionFile],
    [
      JSON.stringify({ id: 'rpc-queue-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-queue-steer-mode', type: 'set_steering_mode', mode: 'one-at-a-time' }),
      JSON.stringify({ id: 'rpc-queue-steer-one', type: 'steer', message: 'rpc steer one' }),
      JSON.stringify({ id: 'rpc-queue-steer-two', type: 'steer', message: 'rpc steer two' }),
      JSON.stringify({ id: 'rpc-queue-before', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-queue-prompt', type: 'prompt', message: 'rpc steer start' }),
      JSON.stringify({ id: 'rpc-queue-after', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-queue-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderQueueResponses = rpcProviderQueueOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderQueueBefore = rpcProviderQueueResponses.find((response) => response.id === 'rpc-queue-before');
  const rpcProviderQueuePrompt = rpcProviderQueueResponses.find((response) => response.id === 'rpc-queue-prompt');
  const rpcProviderQueueAfter = rpcProviderQueueResponses.find((response) => response.id === 'rpc-queue-after');
  const rpcProviderQueueMessages = rpcProviderQueueResponses.find((response) => response.id === 'rpc-queue-messages');
  if (
    rpcProviderQueueBefore?.data?.pendingMessageCount !== 2 ||
    rpcProviderQueueBefore?.data?.pendingSteeringCount !== 2 ||
    rpcProviderQueuePrompt?.data?.text !== 'handled rpc steer two' ||
    rpcProviderQueueAfter?.data?.pendingMessageCount !== 0
  ) {
    throw new Error('rpc provider queue smoke did not drain one-at-a-time steering messages');
  }
  const rpcQueueUserTexts = rpcProviderQueueMessages?.data?.messages?.filter((message) => message.role === 'user').map((message) => message.content);
  const rpcQueueAssistantTexts = rpcProviderQueueMessages?.data?.messages?.filter((message) => message.role === 'assistant').map((message) => message.content);
  if (
    JSON.stringify(rpcQueueUserTexts) !== JSON.stringify(['rpc steer start', 'rpc steer one', 'rpc steer two']) ||
    JSON.stringify(rpcQueueAssistantTexts) !== JSON.stringify(['handled rpc steer one', 'handled rpc steer two'])
  ) {
    throw new Error('rpc provider queue smoke did not preserve queued steering message order');
  }

  const rpcProviderFollowSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-follow-queue-smoke.jsonl');
  fs.rmSync(rpcProviderFollowSessionFile, { force: true });
  const rpcProviderFollowOutput = run(
    ['rpc', rpcProviderFollowSessionFile],
    [
      JSON.stringify({ id: 'rpc-follow-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-follow-mode', type: 'set_follow_up_mode', mode: 'all' }),
      JSON.stringify({ id: 'rpc-follow-one', type: 'follow_up', message: 'rpc follow one' }),
      JSON.stringify({ id: 'rpc-follow-two', type: 'follow_up', message: 'rpc follow two' }),
      JSON.stringify({ id: 'rpc-follow-before', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-follow-prompt', type: 'prompt', message: 'rpc follow start' }),
      JSON.stringify({ id: 'rpc-follow-after', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-follow-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderFollowResponses = rpcProviderFollowOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderFollowBefore = rpcProviderFollowResponses.find((response) => response.id === 'rpc-follow-before');
  const rpcProviderFollowPrompt = rpcProviderFollowResponses.find((response) => response.id === 'rpc-follow-prompt');
  const rpcProviderFollowAfter = rpcProviderFollowResponses.find((response) => response.id === 'rpc-follow-after');
  const rpcProviderFollowMessages = rpcProviderFollowResponses.find((response) => response.id === 'rpc-follow-messages');
  if (
    rpcProviderFollowBefore?.data?.pendingMessageCount !== 2 ||
    rpcProviderFollowBefore?.data?.pendingFollowUpCount !== 2 ||
    rpcProviderFollowPrompt?.data?.text !== 'batched rpc follow response' ||
    rpcProviderFollowAfter?.data?.pendingMessageCount !== 0
  ) {
    throw new Error('rpc provider queue smoke did not drain all-mode follow-up messages');
  }
  const rpcFollowUserTexts = rpcProviderFollowMessages?.data?.messages?.filter((message) => message.role === 'user').map((message) => message.content);
  const rpcFollowAssistantTexts = rpcProviderFollowMessages?.data?.messages?.filter((message) => message.role === 'assistant').map((message) => message.content);
  if (
    JSON.stringify(rpcFollowUserTexts) !== JSON.stringify(['rpc follow start', 'rpc follow one', 'rpc follow two']) ||
    JSON.stringify(rpcFollowAssistantTexts) !== JSON.stringify(['rpc follow base complete', 'batched rpc follow response'])
  ) {
    throw new Error('rpc provider queue smoke did not preserve queued follow-up batch order');
  }

  const rpcProviderRetrySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-smoke.jsonl');
  fs.rmSync(rpcProviderRetrySessionFile, { force: true });
  const rpcProviderRetryOutput = run(
    ['rpc', rpcProviderRetrySessionFile],
    [
      JSON.stringify({ id: 'rpc-retry-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-retry-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0, maxDelayMs: 5 }),
      JSON.stringify({ id: 'rpc-retry-prompt', type: 'prompt', message: 'rpc retry transient' }),
      JSON.stringify({ id: 'rpc-retry-state', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-retry-abort', type: 'abort_retry' }),
      JSON.stringify({ id: 'rpc-retry-after-abort', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-retry-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderRetryResponses = rpcProviderRetryOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderRetryPrompt = rpcProviderRetryResponses.find((response) => response.id === 'rpc-retry-prompt');
  const rpcProviderRetryState = rpcProviderRetryResponses.find((response) => response.id === 'rpc-retry-state');
  const rpcProviderRetryAfterAbort = rpcProviderRetryResponses.find((response) => response.id === 'rpc-retry-after-abort');
  const rpcProviderRetryMessages = rpcProviderRetryResponses.find((response) => response.id === 'rpc-retry-messages');
  const rpcProviderRetryEventSummary = rpcProviderRetryResponses
    .filter((response) => ['agent_end', 'auto_retry_start', 'auto_retry_end'].includes(response.type))
    .map((response) => {
      if (response.type === 'agent_end') return `agent_end:${response.willRetry}`;
      if (response.type === 'auto_retry_start') {
        return `auto_retry_start:${response.attempt}:${response.maxAttempts}:${response.delayMs}:${response.errorMessage}`;
      }
      return `auto_retry_end:${response.success}:${response.attempt}`;
    });
  if (
    !rpcProviderRetryPrompt?.success ||
    rpcProviderRetryPrompt?.data?.text !== 'rpc retry recovered' ||
    rpcProviderRetryPrompt?.data?.retry?.attempts !== 1 ||
    rpcProviderRetryPrompt?.data?.retry?.maxAttempts !== 2 ||
    rpcProviderRetryPrompt?.data?.retry?.totalDelayMs !== 0 ||
    rpcProviderRetryState?.data?.lastRetryAttempts !== 1 ||
    rpcProviderRetryState?.data?.autoRetryMaxAttempts !== 2 ||
    rpcProviderRetryState?.data?.autoRetryBaseDelayMs !== 0 ||
    rpcProviderRetryState?.data?.autoRetryMaxDelayMs !== 5 ||
    rpcProviderRetryAfterAbort?.data?.autoRetryEnabled !== true ||
    rpcProviderRetryAfterAbort?.data?.lastRetryAttempts !== 1 ||
    rpcProviderRetryAfterAbort?.data?.lastRetryDelayMs !== 0 ||
    rpcProviderRetryMessages?.data?.messages?.filter((message) => message.role === 'user').length !== 1 ||
    rpcProviderRetryMessages?.data?.messages?.filter((message) => message.role === 'assistant').length !== 1 ||
    JSON.stringify(rpcProviderRetryEventSummary) !== JSON.stringify([
      'agent_end:true',
      'auto_retry_start:1:2:0:ProviderRequestFailed',
      'auto_retry_end:true:1',
      'agent_end:false'
    ])
  ) {
    throw new Error('rpc provider retry smoke did not recover from a transient provider failure');
  }

  const rpcProviderRetryBodySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-body-smoke.jsonl');
  fs.rmSync(rpcProviderRetryBodySessionFile, { force: true });
  const rpcProviderRetryBodyOutput = run(
    ['rpc', rpcProviderRetryBodySessionFile],
    [
      JSON.stringify({ id: 'rpc-retry-body-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-retry-body-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0, maxDelayMs: 5 }),
      JSON.stringify({ id: 'rpc-retry-body-prompt', type: 'prompt', message: 'rpc retry body overloaded' }),
      JSON.stringify({ id: 'rpc-retry-body-state', type: 'get_state' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderRetryBodyResponses = rpcProviderRetryBodyOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderRetryBodyPrompt = rpcProviderRetryBodyResponses.find((response) => response.id === 'rpc-retry-body-prompt');
  const rpcProviderRetryBodyState = rpcProviderRetryBodyResponses.find((response) => response.id === 'rpc-retry-body-state');
  const rpcProviderRetryBodyEventSummary = rpcProviderRetryBodyResponses
    .filter((response) => ['agent_end', 'auto_retry_start', 'auto_retry_end'].includes(response.type))
    .map((response) => {
      if (response.type === 'agent_end') return `agent_end:${response.willRetry}`;
      if (response.type === 'auto_retry_start') return `auto_retry_start:${response.attempt}:${response.maxAttempts}:${response.delayMs}:${response.errorMessage}`;
      return `auto_retry_end:${response.success}:${response.attempt}`;
    });
  if (
    !rpcProviderRetryBodyPrompt?.success ||
    rpcProviderRetryBodyPrompt?.data?.text !== 'rpc retry body overloaded recovered' ||
    rpcProviderRetryBodyPrompt?.data?.retry?.attempts !== 1 ||
    rpcProviderRetryBodyState?.data?.lastRetryAttempts !== 1 ||
    JSON.stringify(rpcProviderRetryBodyEventSummary) !== JSON.stringify([
      'agent_end:true',
      'auto_retry_start:1:2:0:ProviderRequestFailed',
      'auto_retry_end:true:1',
      'agent_end:false'
    ])
  ) {
    throw new Error('rpc provider retry body-text smoke did not recover from retryable provider error text');
  }

  const rpcProviderRetryExhaustedSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-exhausted-smoke.jsonl');
  fs.rmSync(rpcProviderRetryExhaustedSessionFile, { force: true });
  const rpcProviderRetryExhaustedOutput = run(
    ['rpc', rpcProviderRetryExhaustedSessionFile],
    [
      JSON.stringify({ id: 'rpc-retry-exhausted-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-retry-exhausted-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0, maxDelayMs: 5 }),
      JSON.stringify({ id: 'rpc-retry-exhausted-prompt', type: 'prompt', message: 'rpc retry exhausted' }),
      JSON.stringify({ id: 'rpc-retry-exhausted-state', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-retry-exhausted-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderRetryExhaustedResponses = rpcProviderRetryExhaustedOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderRetryExhaustedPrompt = rpcProviderRetryExhaustedResponses.find((response) => response.id === 'rpc-retry-exhausted-prompt');
  const rpcProviderRetryExhaustedState = rpcProviderRetryExhaustedResponses.find((response) => response.id === 'rpc-retry-exhausted-state');
  const rpcProviderRetryExhaustedMessages = rpcProviderRetryExhaustedResponses.find((response) => response.id === 'rpc-retry-exhausted-messages');
  const rpcProviderRetryExhaustedEventSummary = rpcProviderRetryExhaustedResponses
    .filter((response) => (response.type === 'agent_end' && 'willRetry' in response) || response.type === 'auto_retry_start' || response.type === 'auto_retry_end')
    .map((response) => {
      if (response.type === 'agent_end') return `agent_end:${response.willRetry}`;
      if (response.type === 'auto_retry_start') return `auto_retry_start:${response.attempt}:${response.maxAttempts}`;
      return `auto_retry_end:${response.success}:${response.attempt}:${response.finalError}`;
    });
  const rpcProviderRetryExhaustedLifecycle = rpcProviderRetryExhaustedResponses
    .filter((response) => ['message_start', 'message_end', 'turn_end', 'agent_end'].includes(response.type) && !('willRetry' in response))
    .map((response) => {
      if (response.type === 'agent_end') return `agent_end:${response.messages?.[0]?.stopReason}:${response.messages?.[0]?.errorMessage}`;
      return `${response.type}:${response.message?.stopReason}:${response.message?.errorMessage}`;
    });
  const rpcProviderRetryExhaustedAssistant = rpcProviderRetryExhaustedMessages?.data?.messages
    ?.filter((message) => message.role === 'assistant')
    ?.at(-1);
  if (
    rpcProviderRetryExhaustedPrompt?.success !== false ||
    rpcProviderRetryExhaustedPrompt?.error !== 'ProviderRequestFailed' ||
    rpcProviderRetryExhaustedState?.data?.lastRetryAttempts !== 2 ||
    rpcProviderRetryExhaustedAssistant?.stopReason !== 'error' ||
    rpcProviderRetryExhaustedAssistant?.errorMessage !== 'ProviderRequestFailed' ||
    JSON.stringify(rpcProviderRetryExhaustedEventSummary) !== JSON.stringify([
      'agent_end:true',
      'auto_retry_start:1:2',
      'agent_end:true',
      'auto_retry_start:2:2',
      'agent_end:false',
      'auto_retry_end:false:2:ProviderRequestFailed'
    ]) ||
    JSON.stringify(rpcProviderRetryExhaustedLifecycle) !== JSON.stringify([
      'message_start:error:ProviderRequestFailed',
      'message_end:error:ProviderRequestFailed',
      'turn_end:error:ProviderRequestFailed',
      'agent_end:error:ProviderRequestFailed'
    ])
  ) {
    throw new Error('rpc provider retry exhaustion smoke did not emit upstream-shaped retry events');
  }

  const rpcProviderRetryContextSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-context-overflow-smoke.jsonl');
  fs.rmSync(rpcProviderRetryContextSessionFile, { force: true });
  const rpcProviderRetryContextOutput = run(
    ['rpc', rpcProviderRetryContextSessionFile],
    [
      JSON.stringify({ id: 'rpc-retry-context-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-retry-context-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0, maxDelayMs: 5 }),
      JSON.stringify({ id: 'rpc-retry-context-prompt', type: 'prompt', message: 'rpc retry context overflow' }),
      JSON.stringify({ id: 'rpc-retry-context-state', type: 'get_state' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderRetryContextResponses = rpcProviderRetryContextOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderRetryContextPrompt = rpcProviderRetryContextResponses.find((response) => response.id === 'rpc-retry-context-prompt');
  const rpcProviderRetryContextState = rpcProviderRetryContextResponses.find((response) => response.id === 'rpc-retry-context-state');
  if (
    rpcProviderRetryContextPrompt?.success !== false ||
    rpcProviderRetryContextPrompt?.error !== 'ProviderClientError' ||
    rpcProviderRetryContextState?.data?.lastRetryAttempts !== 0 ||
    rpcProviderRetryContextResponses.some((response) => response.type === 'auto_retry_start' || response.type === 'auto_retry_end') ||
    JSON.stringify(rpcProviderRetryContextResponses).includes('context overflow was retried')
  ) {
    throw new Error('rpc provider retry context-overflow smoke retried a compaction-class error');
  }

  const rpcProviderRetryClientErrorSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-retry-client-error-smoke.jsonl');
  fs.rmSync(rpcProviderRetryClientErrorSessionFile, { force: true });
  const rpcProviderRetryClientErrorOutput = run(
    ['rpc', rpcProviderRetryClientErrorSessionFile],
    [
      JSON.stringify({ id: 'rpc-retry-client-error-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-retry-client-error-enable', type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0, maxDelayMs: 5 }),
      JSON.stringify({ id: 'rpc-retry-client-error-prompt', type: 'prompt', message: 'rpc retry client error' }),
      JSON.stringify({ id: 'rpc-retry-client-error-state', type: 'get_state' }),
      JSON.stringify({ id: 'rpc-retry-client-error-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderRetryClientErrorResponses = rpcProviderRetryClientErrorOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderRetryClientErrorPrompt = rpcProviderRetryClientErrorResponses.find((response) => response.id === 'rpc-retry-client-error-prompt');
  const rpcProviderRetryClientErrorState = rpcProviderRetryClientErrorResponses.find((response) => response.id === 'rpc-retry-client-error-state');
  const rpcProviderRetryClientErrorMessages = rpcProviderRetryClientErrorResponses.find((response) => response.id === 'rpc-retry-client-error-messages');
  const rpcProviderRetryClientErrorAssistant = rpcProviderRetryClientErrorMessages?.data?.messages
    ?.filter((message) => message.role === 'assistant')
    ?.at(-1);
  if (
    rpcProviderRetryClientErrorPrompt?.success !== false ||
    rpcProviderRetryClientErrorPrompt?.error !== 'ProviderClientError' ||
    rpcProviderRetryClientErrorState?.data?.lastRetryAttempts !== 0 ||
    rpcProviderRetryClientErrorAssistant?.stopReason !== 'error' ||
    rpcProviderRetryClientErrorAssistant?.errorMessage !== 'ProviderClientError' ||
    rpcProviderRetryClientErrorResponses.some((response) => response.type === 'auto_retry_start' || response.type === 'auto_retry_end') ||
    JSON.stringify(rpcProviderRetryClientErrorResponses).includes('client error was retried')
  ) {
    throw new Error('rpc provider retry classifier smoke retried a non-transient client error');
  }

  await runRpcRetryAbortDelaySmoke();
  await runRpcProviderAbortInFlightSmoke();
  await runRpcProviderPromptStreamingBehaviorSmoke('steer');
  await runRpcProviderPromptStreamingBehaviorSmoke('follow');
  await runRpcProviderActiveResourcePromptSmoke('steer');
  await runRpcProviderActiveResourcePromptSmoke('follow');
  await runRpcProviderActiveExtensionQueueSmoke('steer', true);
  await runRpcProviderActiveExtensionQueueSmoke('follow', true);

  const rpcProviderOutput = run(
    ['rpc', rpcProviderSessionFile],
    [
      JSON.stringify({ id: 'rpc-provider-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-provider-prompt', type: 'prompt', message: 'please run the tool loop' }),
      JSON.stringify({ id: 'rpc-provider-last', type: 'get_last_assistant_text' }),
      JSON.stringify({ id: 'rpc-provider-messages', type: 'get_messages' }),
      JSON.stringify({ id: 'rpc-provider-stats', type: 'get_session_stats' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderResponses = rpcProviderOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderPrompt = rpcProviderResponses.find((response) => response.id === 'rpc-provider-prompt');
  if (
    !rpcProviderPrompt?.success ||
    !rpcProviderPrompt?.data?.text?.includes('tool loop complete: tool-loop-ok') ||
    rpcProviderPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_tool_loop_1' ||
    rpcProviderPrompt?.data?.toolResults?.[0]?.toolName !== 'bash' ||
    !rpcProviderPrompt?.data?.toolResults?.[0]?.content?.includes('tool-loop-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not execute the provider-backed tool loop');
  }
  const rpcProviderLast = rpcProviderResponses.find((response) => response.id === 'rpc-provider-last');
  if (!rpcProviderLast?.data?.text?.includes('tool loop complete: tool-loop-ok')) {
    throw new Error('rpc get_last_assistant_text smoke did not return provider-backed assistant text');
  }
  const rpcProviderMessages = rpcProviderResponses.find((response) => response.id === 'rpc-provider-messages');
  if (
    rpcProviderMessages?.data?.messages?.[0]?.role !== 'user' ||
    rpcProviderMessages?.data?.messages?.[1]?.role !== 'assistant' ||
    rpcProviderMessages?.data?.messages?.[1]?.toolCalls?.[0]?.id !== 'call_tool_loop_1' ||
    rpcProviderMessages?.data?.messages?.[1]?.toolCalls?.[0]?.name !== 'bash' ||
    rpcProviderMessages?.data?.messages?.[2]?.role !== 'tool' ||
    rpcProviderMessages?.data?.messages?.[2]?.toolCallId !== 'call_tool_loop_1' ||
    !rpcProviderMessages?.data?.messages?.[2]?.content?.includes('tool-loop-ok') ||
    rpcProviderMessages?.data?.messages?.[3]?.role !== 'assistant' ||
    !rpcProviderMessages?.data?.messages?.[3]?.content?.includes('tool loop complete: tool-loop-ok')
  ) {
    throw new Error('rpc get_messages smoke did not include provider-backed user/assistant-tool/tool/assistant turns');
  }
  const rpcProviderStats = rpcProviderResponses.find((response) => response.id === 'rpc-provider-stats');
  if (
    rpcProviderStats?.data?.userMessages !== 1 ||
    rpcProviderStats?.data?.assistantMessages !== 2 ||
    rpcProviderStats?.data?.toolCalls !== 1 ||
    rpcProviderStats?.data?.toolResults !== 1 ||
    rpcProviderStats?.data?.totalMessages !== 4
  ) {
    throw new Error('rpc provider session stats did not count user/assistant-tool/tool/assistant turns');
  }
  const rpcProviderJsonl = fs.readFileSync(rpcProviderSessionFile, 'utf8');
  if (
    !rpcProviderJsonl.includes('"provider":"openai"') ||
    !rpcProviderJsonl.includes('"modelId":"gpt-4o"') ||
    !rpcProviderJsonl.includes('"type":"toolCall"') ||
    !rpcProviderJsonl.includes('"id":"call_tool_loop_1"') ||
    !rpcProviderJsonl.includes('"role":"tool"') ||
    !rpcProviderJsonl.includes('"toolCallId":"call_tool_loop_1"') ||
    !rpcProviderJsonl.includes('"tool-loop-ok"') ||
    !rpcProviderJsonl.includes('"role":"assistant"')
  ) {
    throw new Error('rpc provider durable JSONL did not persist provider-backed assistant tool-call and tool result messages');
  }

  const rpcProviderToolHistorySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-tool-history-smoke.jsonl');
  fs.rmSync(rpcProviderToolHistorySessionFile, { force: true });
  const rpcProviderToolHistoryRun = await runRpcSequential(
    ['rpc', rpcProviderToolHistorySessionFile],
    [
      { id: 'rpc-tool-history-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' },
      { id: 'rpc-tool-history-first', type: 'prompt', message: 'please run the tool loop' },
      { id: 'rpc-tool-history-check', type: 'prompt', message: 'rpc tool history check' }
    ],
    { env: rpcProviderEnv }
  );
  const rpcProviderToolHistoryResponses = rpcProviderToolHistoryRun.lines;
  const rpcProviderToolHistoryCheck = rpcProviderToolHistoryResponses.find((response) => response.id === 'rpc-tool-history-check');
  if (!rpcProviderToolHistoryCheck?.success || rpcProviderToolHistoryCheck?.data?.text !== 'rpc tool history observed') {
    throw new Error('rpc provider prompt smoke did not send prior assistant tool-call and tool result history to the provider');
  }

  const rpcProviderExtensionHookSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-hook-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionHookSessionFile, { force: true });
  const rpcProviderExtensionHookOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionHookSessionFile, '--extension', rpcExtensionHookPath],
    [
      JSON.stringify({ id: 'rpc-extension-hook-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-hook-prompt', type: 'prompt', message: 'rpc extension hook events' }),
      JSON.stringify({ id: 'rpc-extension-hook-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionHookResponses = rpcProviderExtensionHookOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionHookPrompt = rpcProviderExtensionHookResponses.find((response) => response.id === 'rpc-extension-hook-prompt');
  const rpcProviderExtensionHookMessages = rpcProviderExtensionHookResponses.find((response) => response.id === 'rpc-extension-hook-messages');
  if (
    !rpcProviderExtensionHookPrompt?.success ||
    rpcProviderExtensionHookPrompt?.data?.text !== 'rpc extension hook complete: extension-result-patched' ||
    rpcProviderExtensionHookPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_hook_1' ||
    rpcProviderExtensionHookPrompt?.data?.toolResults?.[0]?.content !== 'extension-result-patched' ||
    !rpcProviderExtensionHookMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_hook_1' && message.content === 'extension-result-patched')
  ) {
    throw new Error('rpc provider prompt smoke did not bind explicit extension tool_call/tool_result hooks');
  }

  const rpcProviderExtensionToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-tool-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionToolSessionFile, { force: true });
  const rpcProviderExtensionToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionToolSessionFile, '--extension', rpcExtensionToolPath],
    [
      JSON.stringify({ id: 'rpc-extension-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-tool-prompt', type: 'prompt', message: 'rpc extension registered tool' }),
      JSON.stringify({ id: 'rpc-extension-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionToolResponses = rpcProviderExtensionToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionToolPrompt = rpcProviderExtensionToolResponses.find((response) => response.id === 'rpc-extension-tool-prompt');
  const rpcProviderExtensionToolMessages = rpcProviderExtensionToolResponses.find((response) => response.id === 'rpc-extension-tool-messages');
  if (
    !rpcProviderExtensionToolPrompt?.success ||
    rpcProviderExtensionToolPrompt?.data?.text !== 'rpc extension tool complete: ext-echo: rpc-registered-ok' ||
    rpcProviderExtensionToolPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_tool_1' ||
    rpcProviderExtensionToolPrompt?.data?.toolResults?.[0]?.toolName !== 'ext_echo' ||
    rpcProviderExtensionToolPrompt?.data?.toolResults?.[0]?.content !== 'ext-echo: rpc-registered-ok' ||
    !rpcProviderExtensionToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_tool_1' && message.toolName === 'ext_echo' && message.content === 'ext-echo: rpc-registered-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not expose and execute an explicit registered extension tool');
  }

  const rpcProviderNextTurnCommandSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-next-turn-command-smoke.jsonl');
  fs.rmSync(rpcProviderNextTurnCommandSessionFile, { force: true });
  const rpcProviderNextTurnCommandOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderNextTurnCommandSessionFile, '--extension', 'extensions/command-exec.mjs'],
    [
      JSON.stringify({ id: 'rpc-extension-next-turn-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-next-turn-command', type: 'prompt', message: '/send-next-turn-rpc-provider rpc next-turn custom note' }),
      JSON.stringify({ id: 'rpc-extension-next-turn-prompt', type: 'prompt', message: 'rpc next-turn normal prompt' }),
      JSON.stringify({ id: 'rpc-extension-next-turn-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { cwd: commandsFixtureRoot, env: { ...rpcProviderEnv, HOME: commandsFixtureHome } }
  );
  const rpcProviderNextTurnCommandResponses = rpcProviderNextTurnCommandOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderNextTurnCommand = rpcProviderNextTurnCommandResponses.find((response) => response.id === 'rpc-extension-next-turn-command');
  const rpcProviderNextTurnPrompt = rpcProviderNextTurnCommandResponses.find((response) => response.id === 'rpc-extension-next-turn-prompt');
  const rpcProviderNextTurnMessages = rpcProviderNextTurnCommandResponses.find((response) => response.id === 'rpc-extension-next-turn-messages');
  const rpcProviderNextTurnSessionText = fs.readFileSync(rpcProviderNextTurnCommandSessionFile, 'utf8');
  if (
    !rpcProviderNextTurnCommand?.success ||
    !rpcProviderNextTurnPrompt?.success ||
    rpcProviderNextTurnPrompt?.data?.text !== 'rpc next-turn custom observed' ||
    !rpcProviderNextTurnMessages?.data?.messages?.some((message) =>
      message.role === 'custom' &&
      message.customType === 'next-turn-extension' &&
      message.content === 'rpc next-turn custom note' &&
      message.display === true
    ) ||
    rpcProviderNextTurnMessages?.data?.messages?.some((message) => message.content === '/send-next-turn-rpc-provider rpc next-turn custom note') ||
    !rpcProviderNextTurnSessionText.includes('"type":"custom_message"') ||
    !rpcProviderNextTurnSessionText.includes('"customType":"next-turn-extension"') ||
    rpcProviderNextTurnSessionText.includes('/send-next-turn-rpc-provider rpc next-turn custom note')
  ) {
    throw new Error('rpc provider extension command nextTurn custom message was not injected into the next prompt');
  }

  const rpcProviderExtensionFlagToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-flag-tool-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionFlagToolSessionFile, { force: true });
  const rpcProviderExtensionFlagToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionFlagToolSessionFile, '--extension', rpcExtensionFlagToolPath, '--plan', 'review', '--debug-flag'],
    [
      JSON.stringify({ id: 'rpc-extension-flag-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-flag-tool-prompt', type: 'prompt', message: 'rpc extension flag registered tool' }),
      JSON.stringify({ id: 'rpc-extension-flag-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionFlagToolResponses = rpcProviderExtensionFlagToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionFlagToolPrompt = rpcProviderExtensionFlagToolResponses.find((response) => response.id === 'rpc-extension-flag-tool-prompt');
  const rpcProviderExtensionFlagToolMessages = rpcProviderExtensionFlagToolResponses.find((response) => response.id === 'rpc-extension-flag-tool-messages');
  if (
    !rpcProviderExtensionFlagToolPrompt?.success ||
    rpcProviderExtensionFlagToolPrompt?.data?.text !== 'rpc extension flag tool complete: ext-flag: plan=review;debug=true;missing=undefined' ||
    rpcProviderExtensionFlagToolPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_flag_tool_1' ||
    rpcProviderExtensionFlagToolPrompt?.data?.toolResults?.[0]?.toolName !== 'ext_flag_echo' ||
    rpcProviderExtensionFlagToolPrompt?.data?.toolResults?.[0]?.content !== 'ext-flag: plan=review;debug=true;missing=undefined' ||
    !rpcProviderExtensionFlagToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_flag_tool_1' && message.toolName === 'ext_flag_echo' && message.content === 'ext-flag: plan=review;debug=true;missing=undefined')
  ) {
    throw new Error('rpc provider prompt smoke did not pass CLI extension flags to a registered extension tool');
  }

  const rpcProviderExtensionNoBuiltinToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-no-builtin-tool-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionNoBuiltinToolSessionFile, { force: true });
  const rpcProviderExtensionNoBuiltinToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionNoBuiltinToolSessionFile, '--no-builtin-tools', '--extension', rpcExtensionToolPath],
    [
      JSON.stringify({ id: 'rpc-extension-no-builtin-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-no-builtin-tool-prompt', type: 'prompt', message: 'rpc extension no builtin registered tool' }),
      JSON.stringify({ id: 'rpc-extension-no-builtin-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionNoBuiltinToolResponses = rpcProviderExtensionNoBuiltinToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionNoBuiltinToolPrompt = rpcProviderExtensionNoBuiltinToolResponses.find((response) => response.id === 'rpc-extension-no-builtin-tool-prompt');
  const rpcProviderExtensionNoBuiltinToolMessages = rpcProviderExtensionNoBuiltinToolResponses.find((response) => response.id === 'rpc-extension-no-builtin-tool-messages');
  if (
    !rpcProviderExtensionNoBuiltinToolPrompt?.success ||
    rpcProviderExtensionNoBuiltinToolPrompt?.data?.text !== 'rpc extension no builtin tool complete: ext-echo: rpc-no-builtin-ok' ||
    rpcProviderExtensionNoBuiltinToolPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_no_builtin_tool_1' ||
    rpcProviderExtensionNoBuiltinToolPrompt?.data?.toolResults?.[0]?.toolName !== 'ext_echo' ||
    rpcProviderExtensionNoBuiltinToolPrompt?.data?.toolResults?.[0]?.content !== 'ext-echo: rpc-no-builtin-ok' ||
    !rpcProviderExtensionNoBuiltinToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_no_builtin_tool_1' && message.toolName === 'ext_echo' && message.content === 'ext-echo: rpc-no-builtin-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not keep extension tools active under --no-builtin-tools');
  }

  const rpcProviderExtensionAllowlistToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-allowlist-tool-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionAllowlistToolSessionFile, { force: true });
  const rpcProviderExtensionAllowlistToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionAllowlistToolSessionFile, '--tools', 'ext_echo', '--extension', rpcExtensionToolPath],
    [
      JSON.stringify({ id: 'rpc-extension-allowlist-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-allowlist-tool-prompt', type: 'prompt', message: 'rpc extension allowlist registered tool' }),
      JSON.stringify({ id: 'rpc-extension-allowlist-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionAllowlistToolResponses = rpcProviderExtensionAllowlistToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionAllowlistToolPrompt = rpcProviderExtensionAllowlistToolResponses.find((response) => response.id === 'rpc-extension-allowlist-tool-prompt');
  const rpcProviderExtensionAllowlistToolMessages = rpcProviderExtensionAllowlistToolResponses.find((response) => response.id === 'rpc-extension-allowlist-tool-messages');
  if (
    !rpcProviderExtensionAllowlistToolPrompt?.success ||
    rpcProviderExtensionAllowlistToolPrompt?.data?.text !== 'rpc extension allowlist tool complete: ext-echo: rpc-allowlist-ok' ||
    rpcProviderExtensionAllowlistToolPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_allowlist_tool_1' ||
    rpcProviderExtensionAllowlistToolPrompt?.data?.toolResults?.[0]?.toolName !== 'ext_echo' ||
    rpcProviderExtensionAllowlistToolPrompt?.data?.toolResults?.[0]?.content !== 'ext-echo: rpc-allowlist-ok' ||
    !rpcProviderExtensionAllowlistToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_allowlist_tool_1' && message.toolName === 'ext_echo' && message.content === 'ext-echo: rpc-allowlist-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not allowlist an extension registered tool');
  }

  const rpcProviderExtensionPermissionGateSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-permission-gate-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionPermissionGateSessionFile, { force: true });
  const rpcProviderExtensionPermissionGateOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionPermissionGateSessionFile, '--extension', rpcExtensionPermissionGatePath],
    [
      JSON.stringify({ id: 'rpc-extension-permission-gate-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-permission-gate-prompt', type: 'prompt', message: 'rpc extension permission gate' }),
      JSON.stringify({ id: 'rpc-extension-permission-gate-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionPermissionGateResponses = rpcProviderExtensionPermissionGateOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionPermissionGatePrompt = rpcProviderExtensionPermissionGateResponses.find((response) => response.id === 'rpc-extension-permission-gate-prompt');
  const rpcProviderExtensionPermissionGateMessages = rpcProviderExtensionPermissionGateResponses.find((response) => response.id === 'rpc-extension-permission-gate-messages');
  if (
    !rpcProviderExtensionPermissionGatePrompt?.success ||
    rpcProviderExtensionPermissionGatePrompt?.data?.text !== 'rpc extension permission gate complete: blocked by headless permission gate' ||
    rpcProviderExtensionPermissionGatePrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_permission_gate_1' ||
    rpcProviderExtensionPermissionGatePrompt?.data?.toolResults?.[0]?.toolName !== 'bash' ||
    rpcProviderExtensionPermissionGatePrompt?.data?.toolResults?.[0]?.isError !== true ||
    rpcProviderExtensionPermissionGatePrompt?.data?.toolResults?.[0]?.content !== 'blocked by headless permission gate' ||
    rpcProviderExtensionPermissionGatePrompt?.data?.toolResults?.[0]?.content.includes('should-not-run') ||
    !rpcProviderExtensionPermissionGateMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_permission_gate_1' && message.toolName === 'bash' && message.content === 'blocked by headless permission gate')
  ) {
    throw new Error('rpc provider prompt smoke did not block a bash tool call through extension headless permission UI');
  }

  const rpcProviderExtensionBashOverrideSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-bash-override-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionBashOverrideSessionFile, { force: true });
  const rpcProviderExtensionBashOverrideOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionBashOverrideSessionFile, '--extension', rpcExtensionBashOverridePath],
    [
      JSON.stringify({ id: 'rpc-extension-bash-override-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-bash-override-prompt', type: 'prompt', message: 'rpc extension bash override tool' }),
      JSON.stringify({ id: 'rpc-extension-bash-override-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionBashOverrideResponses = rpcProviderExtensionBashOverrideOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionBashOverridePrompt = rpcProviderExtensionBashOverrideResponses.find((response) => response.id === 'rpc-extension-bash-override-prompt');
  const rpcProviderExtensionBashOverrideMessages = rpcProviderExtensionBashOverrideResponses.find((response) => response.id === 'rpc-extension-bash-override-messages');
  if (
    !rpcProviderExtensionBashOverridePrompt?.success ||
    rpcProviderExtensionBashOverridePrompt?.data?.text !== 'rpc extension bash override complete: ext-bash: rpc-override-ok' ||
    rpcProviderExtensionBashOverridePrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_bash_override_1' ||
    rpcProviderExtensionBashOverridePrompt?.data?.toolResults?.[0]?.toolName !== 'bash' ||
    JSON.parse(rpcProviderExtensionBashOverridePrompt?.data?.toolResults?.[0]?.arguments ?? '{}')?.value !== 'rpc-override-ok' ||
    rpcProviderExtensionBashOverridePrompt?.data?.toolResults?.[0]?.content !== 'ext-bash: rpc-override-ok' ||
    !rpcProviderExtensionBashOverrideMessages?.data?.messages?.some((message) => message.role === 'assistant' && message.toolCalls?.[0]?.name === 'bash') ||
    !rpcProviderExtensionBashOverrideMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_bash_override_1' && message.toolName === 'bash' && message.content === 'ext-bash: rpc-override-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not let a registered extension tool override built-in bash');
  }

  const rpcProviderExtensionTsToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-ts-tool-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionTsToolSessionFile, { force: true });
  const rpcProviderExtensionTsToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionTsToolSessionFile, '--extension', rpcExtensionTsToolPath],
    [
      JSON.stringify({ id: 'rpc-extension-ts-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-ts-tool-prompt', type: 'prompt', message: 'rpc extension typescript tool' }),
      JSON.stringify({ id: 'rpc-extension-ts-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionTsToolResponses = rpcProviderExtensionTsToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionTsToolPrompt = rpcProviderExtensionTsToolResponses.find((response) => response.id === 'rpc-extension-ts-tool-prompt');
  const rpcProviderExtensionTsToolMessages = rpcProviderExtensionTsToolResponses.find((response) => response.id === 'rpc-extension-ts-tool-messages');
  if (
    !rpcProviderExtensionTsToolPrompt?.success ||
    rpcProviderExtensionTsToolPrompt?.data?.text !== 'rpc extension ts tool complete: ext-ts-echo: rpc-ts-registered-ok' ||
    rpcProviderExtensionTsToolPrompt?.data?.toolResults?.[0]?.toolCallId !== 'call_rpc_extension_ts_tool_1' ||
    rpcProviderExtensionTsToolPrompt?.data?.toolResults?.[0]?.toolName !== 'ext_ts_echo' ||
    rpcProviderExtensionTsToolPrompt?.data?.toolResults?.[0]?.content !== 'ext-ts-echo: rpc-ts-registered-ok' ||
    !rpcProviderExtensionTsToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_ts_tool_1' && message.toolName === 'ext_ts_echo' && message.content === 'ext-ts-echo: rpc-ts-registered-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not expose and execute an explicit TypeScript registered extension tool');
  }

  const rpcProviderExtensionCommandTriggerSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-extension-command-trigger-smoke.jsonl');
  fs.rmSync(rpcProviderExtensionCommandTriggerSessionFile, { force: true });
  const rpcProviderExtensionCommandTriggerOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderExtensionCommandTriggerSessionFile, '--extension', rpcExtensionCommandTriggerPath],
    [
      JSON.stringify({ id: 'rpc-extension-command-trigger-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-extension-command-trigger-prompt', type: 'prompt', message: '/trigger-custom trigger custom provider' }),
      JSON.stringify({ id: 'rpc-extension-command-trigger-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderExtensionCommandTriggerResponses = rpcProviderExtensionCommandTriggerOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderExtensionCommandTriggerPrompt = rpcProviderExtensionCommandTriggerResponses.find((response) => response.id === 'rpc-extension-command-trigger-prompt');
  const rpcProviderExtensionCommandTriggerMessages = rpcProviderExtensionCommandTriggerResponses.find((response) => response.id === 'rpc-extension-command-trigger-messages');
  const rpcProviderExtensionCommandTriggerSession = fs.readFileSync(rpcProviderExtensionCommandTriggerSessionFile, 'utf8');
  if (
    !rpcProviderExtensionCommandTriggerPrompt?.success ||
    !rpcProviderExtensionCommandTriggerPrompt?.data?.text?.includes('trigger custom provider') ||
    rpcProviderExtensionCommandTriggerMessages?.data?.messages?.some((message) => message.role === 'user' && message.content.includes('/trigger-custom')) ||
    !rpcProviderExtensionCommandTriggerMessages?.data?.messages?.some((message) =>
      message.role === 'custom' &&
      message.customType === 'trigger-extension' &&
      message.content === 'trigger custom provider' &&
      message.display === true
    ) ||
    !rpcProviderExtensionCommandTriggerMessages?.data?.messages?.some((message) => message.role === 'assistant' && message.content.includes('trigger custom provider')) ||
    !rpcProviderExtensionCommandTriggerSession.includes('"type":"custom_message"') ||
    rpcProviderExtensionCommandTriggerSession.includes('/trigger-custom trigger custom provider')
  ) {
    throw new Error('rpc provider prompt smoke did not trigger an agent turn from extension command sendMessage');
  }

  const rpcProviderDiscoveredExtensionHookSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-discovered-extension-hook-smoke.jsonl');
  fs.rmSync(rpcProviderDiscoveredExtensionHookSessionFile, { force: true });
  const rpcProviderDiscoveredExtensionHookOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderDiscoveredExtensionHookSessionFile],
    [
      JSON.stringify({ id: 'rpc-discovered-extension-hook-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-discovered-extension-hook-prompt', type: 'prompt', message: 'rpc extension hook events' }),
      JSON.stringify({ id: 'rpc-discovered-extension-hook-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { cwd: rpcDiscoveredExtensionProject, env: rpcProviderEnv }
  );
  const rpcProviderDiscoveredExtensionHookResponses = rpcProviderDiscoveredExtensionHookOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderDiscoveredExtensionHookPrompt = rpcProviderDiscoveredExtensionHookResponses.find((response) => response.id === 'rpc-discovered-extension-hook-prompt');
  const rpcProviderDiscoveredExtensionHookMessages = rpcProviderDiscoveredExtensionHookResponses.find((response) => response.id === 'rpc-discovered-extension-hook-messages');
  if (
    !rpcProviderDiscoveredExtensionHookPrompt?.success ||
    rpcProviderDiscoveredExtensionHookPrompt?.data?.text !== 'rpc extension hook complete: extension-result-patched' ||
    !rpcProviderDiscoveredExtensionHookMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_hook_1' && message.content === 'extension-result-patched')
  ) {
    throw new Error('rpc provider prompt smoke did not bind discovered extension tool_call/tool_result hooks');
  }

  const rpcProviderDiscoveredExtensionToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-discovered-extension-tool-smoke.jsonl');
  fs.rmSync(rpcProviderDiscoveredExtensionToolSessionFile, { force: true });
  const rpcProviderDiscoveredExtensionToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderDiscoveredExtensionToolSessionFile],
    [
      JSON.stringify({ id: 'rpc-discovered-extension-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-discovered-extension-tool-prompt', type: 'prompt', message: 'rpc extension registered tool' }),
      JSON.stringify({ id: 'rpc-discovered-extension-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { cwd: rpcDiscoveredExtensionProject, env: rpcProviderEnv }
  );
  const rpcProviderDiscoveredExtensionToolResponses = rpcProviderDiscoveredExtensionToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderDiscoveredExtensionToolPrompt = rpcProviderDiscoveredExtensionToolResponses.find((response) => response.id === 'rpc-discovered-extension-tool-prompt');
  const rpcProviderDiscoveredExtensionToolMessages = rpcProviderDiscoveredExtensionToolResponses.find((response) => response.id === 'rpc-discovered-extension-tool-messages');
  if (
    !rpcProviderDiscoveredExtensionToolPrompt?.success ||
    rpcProviderDiscoveredExtensionToolPrompt?.data?.text !== 'rpc extension tool complete: ext-echo: rpc-registered-ok' ||
    !rpcProviderDiscoveredExtensionToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_tool_1' && message.toolName === 'ext_echo' && message.content === 'ext-echo: rpc-registered-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not expose and execute a discovered registered extension tool');
  }

  const rpcProviderDiscoveredExtensionTsToolSessionFile = path.resolve('zig-out/pi-zig-rpc-provider-discovered-extension-ts-tool-smoke.jsonl');
  fs.rmSync(rpcProviderDiscoveredExtensionTsToolSessionFile, { force: true });
  const rpcProviderDiscoveredExtensionTsToolOutput = run(
    ['--mode', 'rpc', '--session', rpcProviderDiscoveredExtensionTsToolSessionFile],
    [
      JSON.stringify({ id: 'rpc-discovered-extension-ts-tool-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ id: 'rpc-discovered-extension-ts-tool-prompt', type: 'prompt', message: 'rpc extension typescript tool' }),
      JSON.stringify({ id: 'rpc-discovered-extension-ts-tool-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { cwd: rpcDiscoveredExtensionProject, env: rpcProviderEnv }
  );
  const rpcProviderDiscoveredExtensionTsToolResponses = rpcProviderDiscoveredExtensionTsToolOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderDiscoveredExtensionTsToolPrompt = rpcProviderDiscoveredExtensionTsToolResponses.find((response) => response.id === 'rpc-discovered-extension-ts-tool-prompt');
  const rpcProviderDiscoveredExtensionTsToolMessages = rpcProviderDiscoveredExtensionTsToolResponses.find((response) => response.id === 'rpc-discovered-extension-ts-tool-messages');
  if (
    !rpcProviderDiscoveredExtensionTsToolPrompt?.success ||
    rpcProviderDiscoveredExtensionTsToolPrompt?.data?.text !== 'rpc extension ts tool complete: ext-ts-echo: rpc-ts-registered-ok' ||
    !rpcProviderDiscoveredExtensionTsToolMessages?.data?.messages?.some((message) => message.role === 'tool' && message.toolCallId === 'call_rpc_extension_ts_tool_1' && message.toolName === 'ext_ts_echo' && message.content === 'ext-ts-echo: rpc-ts-registered-ok')
  ) {
    throw new Error('rpc provider prompt smoke did not expose and execute a discovered TypeScript registered extension tool');
  }

  const rpcProviderCompactionHistorySessionFile = path.resolve('zig-out/pi-zig-rpc-provider-compaction-history-smoke.jsonl');
  fs.writeFileSync(
    rpcProviderCompactionHistorySessionFile,
    [
      JSON.stringify({ type: 'session', version: 3, id: 'pi-zig-compaction-history-smoke', timestamp: 'local-foundation', cwd: '.' }),
      JSON.stringify({ type: 'model_change', id: 'm-1', parentId: null, timestamp: 'local-foundation', provider: 'openai', modelId: 'gpt-4o' }),
      JSON.stringify({ type: 'message', id: 'm-2', parentId: 'm-1', timestamp: 'local-foundation', message: { role: 'user', content: 'raw compacted provider message' } }),
      JSON.stringify({ type: 'message', id: 'm-3', parentId: 'm-2', timestamp: 'local-foundation', message: { role: 'assistant', content: [{ type: 'text', text: 'raw compacted assistant response' }], provider: 'openai', model: 'gpt-4o' } }),
      JSON.stringify({ type: 'message', id: 'm-4', parentId: 'm-3', timestamp: 'local-foundation', message: { role: 'user', content: 'kept provider message' } }),
      JSON.stringify({ type: 'compaction', id: 'm-5', parentId: 'm-4', timestamp: 'local-foundation', summary: 'summary of compacted provider history', firstKeptEntryId: 'm-4', tokensBefore: 123, details: { local: true } }),
      ''
    ].join('\n')
  );
  const rpcProviderCompactionHistoryOutput = run(
    ['rpc', rpcProviderCompactionHistorySessionFile],
    [
      JSON.stringify({ id: 'rpc-compaction-history-check', type: 'prompt', message: 'rpc compaction history check' }),
      JSON.stringify({ id: 'rpc-compaction-history-messages', type: 'get_messages' }),
      ''
    ].join('\n'),
    { env: rpcProviderEnv }
  );
  const rpcProviderCompactionHistoryResponses = rpcProviderCompactionHistoryOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const rpcProviderCompactionHistoryCheck = rpcProviderCompactionHistoryResponses.find((response) => response.id === 'rpc-compaction-history-check');
  const rpcProviderCompactionHistoryMessages = rpcProviderCompactionHistoryResponses.find((response) => response.id === 'rpc-compaction-history-messages');
  if (
    !rpcProviderCompactionHistoryCheck?.success ||
    rpcProviderCompactionHistoryCheck?.data?.text !== 'rpc compaction history observed' ||
    rpcProviderCompactionHistoryMessages?.data?.messages?.[0]?.role !== 'compactionSummary' ||
    rpcProviderCompactionHistoryMessages?.data?.messages?.[1]?.content !== 'kept provider message' ||
    rpcProviderCompactionHistoryMessages?.data?.messages?.some((message) => message.content === 'raw compacted provider message')
  ) {
    throw new Error('rpc provider prompt smoke did not replay compacted context as summary plus kept messages');
  }
} finally {
  rpcFakeProvider.stop();
}

const rpcSessionFile = 'zig-out/pi-zig-rpc-smoke.jsonl';
const rpcExportFile = 'zig-out/pi-zig-rpc-smoke.html';
fs.rmSync(rpcSessionFile, { force: true });
fs.rmSync(rpcExportFile, { force: true });
const rpcLocalAuthDir = path.resolve('zig-out/pi-zig-rpc-local-auth');
fs.rmSync(rpcLocalAuthDir, { recursive: true, force: true });
const rpcOutput = run(
  ['rpc', rpcSessionFile],
  [
    JSON.stringify({ id: 'state-1', type: 'get_state' }),
    JSON.stringify({ id: 'models-1', type: 'get_available_models' }),
    JSON.stringify({ id: 'set-model-1', type: 'set_model', provider: 'anthropic', modelId: 'claude-haiku-4-5' }),
    JSON.stringify({ id: 'prompt-1', type: 'prompt', message: 'hello rpc' }),
    JSON.stringify({ id: 'bash-1', type: 'bash', command: 'printf rpc-bash' }),
    JSON.stringify({ id: 'name-1', type: 'set_session_name', name: 'smoke session' }),
    JSON.stringify({ id: 'auto-compact-1', type: 'set_auto_compaction', enabled: true }),
    JSON.stringify({ id: 'auto-retry-1', type: 'set_auto_retry', enabled: true }),
    JSON.stringify({ id: 'compact-1', type: 'compact', customInstructions: 'focus smoke' }),
    JSON.stringify({ id: 'abort-retry-1', type: 'abort_retry' }),
    JSON.stringify({ id: 'messages-1', type: 'get_messages' }),
    JSON.stringify({ id: 'stats-1', type: 'get_session_stats' }),
    JSON.stringify({ id: 'forks-1', type: 'get_fork_messages' }),
    JSON.stringify({ id: 'export-1', type: 'export_html', outputPath: rpcExportFile }),
    JSON.stringify({ id: 'state-2', type: 'get_state' }),
    JSON.stringify({ id: 'bash-long-1', type: 'bash', command: "node -e \"for (let i = 0; i < 2105; i++) console.log('rpc-bash-line-' + String(i).padStart(4, '0'))\"" }),
    JSON.stringify({ id: 'messages-after-long-bash', type: 'get_messages' }),
    JSON.stringify({ id: 'abort-bash-1', type: 'abort_bash' }),
    ''
  ].join('\n'),
  { env: envWithoutAnthropicAuth({ PI_CODING_AGENT_DIR: rpcLocalAuthDir }) }
);
const rpcResponses = rpcOutput
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const promptResponse = rpcResponses.find((response) => response.id === 'prompt-1');
if (!promptResponse?.success) {
  throw new Error('rpc prompt smoke was not accepted');
}
const rpcModelsResponse = rpcResponses.find((response) => response.id === 'models-1');
if (
  rpcModelsResponse?.data?.models?.length !== 924 ||
  !rpcModelsResponse?.data?.models?.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('rpc get_available_models smoke did not return generated catalog');
}
const rpcSetModelResponse = rpcResponses.find((response) => response.id === 'set-model-1');
if (
  !rpcSetModelResponse?.success ||
  rpcSetModelResponse?.data?.provider !== 'anthropic' ||
  rpcSetModelResponse?.data?.id !== 'claude-haiku-4-5'
) {
  throw new Error('rpc set_model smoke did not return selected model');
}
const messagesResponse = rpcResponses.find((response) => response.id === 'messages-1');
if (
  messagesResponse?.data?.messages?.[0]?.role !== 'compactionSummary' ||
  !messagesResponse?.data?.messages?.[0]?.summary?.includes('hello rpc') ||
  messagesResponse?.data?.messages?.[1]?.content !== 'hello rpc'
) {
  throw new Error('rpc get_messages smoke did not return compacted session context');
}
const bashResponse = rpcResponses.find((response) => response.id === 'bash-1');
if (
  !bashResponse?.success ||
  bashResponse?.data?.output !== 'rpc-bash' ||
  bashResponse?.data?.exitCode !== 0 ||
  bashResponse?.data?.cancelled !== false ||
  bashResponse?.data?.truncated !== false
) {
  throw new Error('rpc bash smoke did not return upstream-shaped BashResult');
}
const bashLongResponse = rpcResponses.find((response) => response.id === 'bash-long-1');
if (
  !bashLongResponse?.success ||
  bashLongResponse?.data?.truncated !== true ||
  bashLongResponse?.data?.fullOutputPath !== 'zig-out/pi-zig-bash-full-output.log' ||
  bashLongResponse?.data?.output?.includes('rpc-bash-line-0000') ||
  !bashLongResponse?.data?.output?.includes('rpc-bash-line-2104')
) {
  throw new Error('rpc long bash smoke did not return truncated output with full-output path');
}
const messagesAfterLongBash = rpcResponses.find((response) => response.id === 'messages-after-long-bash');
const longBashMessage = messagesAfterLongBash?.data?.messages?.find(
  (message) => message.role === 'bashExecution' && message.command?.includes('rpc-bash-line-')
);
if (
  longBashMessage?.truncated !== true ||
  longBashMessage?.fullOutputPath !== 'zig-out/pi-zig-bash-full-output.log'
) {
  throw new Error('rpc get_messages smoke did not preserve fullOutputPath for truncated bashExecution');
}
const rpcBashFullOutput = fs.readFileSync('zig-out/pi-zig-bash-full-output.log', 'utf8');
if (!rpcBashFullOutput.includes('rpc-bash-line-0000') || !rpcBashFullOutput.includes('rpc-bash-line-2104')) {
  throw new Error('rpc long bash smoke did not persist complete full output');
}
const abortBashResponse = rpcResponses.find((response) => response.id === 'abort-bash-1');
if (!abortBashResponse?.success || abortBashResponse?.command !== 'abort_bash') {
  throw new Error('rpc abort_bash smoke did not return upstream-shaped success response');
}
const initialState = rpcResponses.find((response) => response.id === 'state-1');
if (initialState?.data?.isBashRunning !== false) {
  throw new Error('rpc get_state smoke did not expose idle bash running state');
}

const rpcActiveBashStateSessionFile = 'zig-out/pi-zig-rpc-active-bash-state-smoke.jsonl';
fs.rmSync(rpcActiveBashStateSessionFile, { force: true });
const rpcActiveBashStateChild = spawn(bin, ['rpc', rpcActiveBashStateSessionFile], {
  env: envWithoutAnthropicAuth(),
  stdio: ['pipe', 'pipe', 'pipe']
});
let rpcActiveBashStateStdout = '';
let rpcActiveBashStateStderr = '';
rpcActiveBashStateChild.stdout.setEncoding('utf8');
rpcActiveBashStateChild.stderr.setEncoding('utf8');
rpcActiveBashStateChild.stdout.on('data', (chunk) => {
  rpcActiveBashStateStdout += chunk;
});
rpcActiveBashStateChild.stderr.on('data', (chunk) => {
  rpcActiveBashStateStderr += chunk;
});
const rpcActiveBashStateExit = new Promise((resolve, reject) => {
  const timeout = setTimeout(() => {
    rpcActiveBashStateChild.kill('SIGKILL');
    reject(new Error('rpc active bash state smoke timed out'));
  }, 5000);
  rpcActiveBashStateChild.once('error', (error) => {
    clearTimeout(timeout);
    reject(error);
  });
  rpcActiveBashStateChild.once('exit', (code, signal) => {
    clearTimeout(timeout);
    resolve({ code, signal });
  });
});
function writeRpcActiveBashStateCommand(command) {
  rpcActiveBashStateChild.stdin.write(`${JSON.stringify(command)}\n`);
}
writeRpcActiveBashStateCommand({
  id: 'rpc-active-bash-running',
  type: 'bash',
  command: 'printf rpc-active-before; sleep 2; printf rpc-active-after'
});
await new Promise((resolve) => setTimeout(resolve, 150));
writeRpcActiveBashStateCommand({ id: 'rpc-active-bash-state', type: 'get_state' });
await new Promise((resolve) => setTimeout(resolve, 50));
writeRpcActiveBashStateCommand({ id: 'rpc-active-bash-abort', type: 'abort_bash' });
rpcActiveBashStateChild.stdin.end();
const rpcActiveBashStateResult = await rpcActiveBashStateExit;
if (rpcActiveBashStateResult.code !== 0) {
  throw new Error(`rpc active bash state smoke failed: ${rpcActiveBashStateStderr}`);
}
const rpcActiveBashStateResponses = rpcActiveBashStateStdout.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcActiveBashState = rpcActiveBashStateResponses.find((response) => response.id === 'rpc-active-bash-state');
const rpcActiveBashAbort = rpcActiveBashStateResponses.find((response) => response.id === 'rpc-active-bash-abort');
const rpcActiveBashRun = rpcActiveBashStateResponses.find((response) => response.id === 'rpc-active-bash-running');
if (!rpcActiveBashState?.success || rpcActiveBashState?.data?.isBashRunning !== true) {
  throw new Error('rpc get_state smoke did not observe a running bash command');
}
if (
  !rpcActiveBashAbort?.success ||
  !rpcActiveBashRun?.success ||
  rpcActiveBashRun?.data?.cancelled !== true ||
  rpcActiveBashRun?.data?.output?.includes('rpc-active-after')
) {
  throw new Error('rpc active bash state smoke did not abort the observed running bash command');
}
const rpcAbortBashSessionFile = 'zig-out/pi-zig-rpc-bash-abort-smoke.jsonl';
fs.rmSync(rpcAbortBashSessionFile, { force: true });
const rpcAbortBashOutput = run(
  ['rpc', rpcAbortBashSessionFile],
  [
    JSON.stringify({ id: 'rpc-bash-abort-running', type: 'bash', command: 'sleep 2; printf rpc-after-abort' }),
    JSON.stringify({ id: 'rpc-bash-abort-command', type: 'abort_bash' }),
    JSON.stringify({ id: 'rpc-bash-abort-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { env: envWithoutAnthropicAuth() }
);
const rpcAbortBashResponses = rpcAbortBashOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcAbortBashCommand = rpcAbortBashResponses.find((response) => response.id === 'rpc-bash-abort-command');
const rpcAbortBashRun = rpcAbortBashResponses.find((response) => response.id === 'rpc-bash-abort-running');
if (
  !rpcAbortBashCommand?.success ||
  !rpcAbortBashRun?.success ||
  rpcAbortBashRun?.data?.exitCode !== null ||
  rpcAbortBashRun?.data?.cancelled !== true ||
  rpcAbortBashRun?.data?.output?.includes('rpc-after-abort') ||
  !rpcAbortBashRun?.data?.output?.includes('Command cancelled')
) {
  throw new Error('rpc abort_bash smoke did not cancel a running bash command');
}
const rpcAbortBashMessages = rpcAbortBashResponses.find((response) => response.id === 'rpc-bash-abort-messages');
if (
  rpcAbortBashMessages?.data?.messages?.[0]?.role !== 'bashExecution' ||
  rpcAbortBashMessages?.data?.messages?.[0]?.cancelled !== true ||
  rpcAbortBashMessages?.data?.messages?.[0]?.output?.includes('rpc-after-abort')
) {
  throw new Error('rpc abort_bash smoke did not persist the cancelled bashExecution message');
}
const rpcTimeoutSessionFile = 'zig-out/pi-zig-rpc-bash-timeout-smoke.jsonl';
fs.rmSync(rpcTimeoutSessionFile, { force: true });
const rpcTimeoutOutput = run(
  ['rpc', rpcTimeoutSessionFile],
  [
    JSON.stringify({ id: 'rpc-bash-timeout-1', type: 'bash', command: 'printf rpc-before-timeout; sleep 1; printf rpc-after-timeout', timeout: 0.1 }),
    JSON.stringify({ id: 'rpc-bash-timeout-messages', type: 'get_messages' }),
    ''
  ].join('\n'),
  { env: envWithoutAnthropicAuth() }
);
const rpcTimeoutResponses = rpcTimeoutOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcTimeoutResponse = rpcTimeoutResponses.find((response) => response.id === 'rpc-bash-timeout-1');
if (
  !rpcTimeoutResponse?.success ||
  rpcTimeoutResponse?.data?.exitCode !== null ||
  rpcTimeoutResponse?.data?.cancelled !== true ||
  !rpcTimeoutResponse?.data?.output?.includes('rpc-before-timeout') ||
  rpcTimeoutResponse?.data?.output?.includes('rpc-after-timeout') ||
  !rpcTimeoutResponse?.data?.output?.includes('Command timed out after 0.100 seconds')
) {
  throw new Error('rpc bash timeout smoke did not return cancelled partial output');
}
const rpcTimeoutMessages = rpcTimeoutResponses.find((response) => response.id === 'rpc-bash-timeout-messages');
if (
  rpcTimeoutMessages?.data?.messages?.[0]?.role !== 'bashExecution' ||
  rpcTimeoutMessages?.data?.messages?.[0]?.cancelled !== true ||
  !rpcTimeoutMessages?.data?.messages?.[0]?.output?.includes('rpc-before-timeout')
) {
  throw new Error('rpc bash timeout smoke did not persist cancelled bashExecution message');
}
const rpcShellSettingsRoot = path.resolve('zig-out/pi-zig-rpc-shell-settings-smoke');
const rpcShellSettingsProject = path.join(rpcShellSettingsRoot, 'project');
const rpcShellSettingsHome = path.join(rpcShellSettingsRoot, 'home');
fs.rmSync(rpcShellSettingsRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(rpcShellSettingsProject, '.pi'), { recursive: true });
fs.mkdirSync(path.join(rpcShellSettingsHome, '.pi/agent'), { recursive: true });
fs.writeFileSync(path.join(rpcShellSettingsProject, '.pi/settings.json'), JSON.stringify({
  shellCommandPrefix: 'export PI_ZIG_RPC_PREFIX=from-settings'
}, null, 2));
const rpcShellSettingsOutput = run(
  ['rpc', path.join(rpcShellSettingsRoot, 'rpc-shell-settings-smoke.jsonl')],
  [
    JSON.stringify({ id: 'rpc-shell-settings-bash-1', type: 'bash', command: 'printf $PI_ZIG_RPC_PREFIX' }),
    ''
  ].join('\n'),
  {
    cwd: rpcShellSettingsProject,
    env: envWithoutAnthropicAuth({ HOME: rpcShellSettingsHome })
  }
);
const rpcShellSettingsResponse = rpcShellSettingsOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line)).find((response) => response.id === 'rpc-shell-settings-bash-1');
if (
  !rpcShellSettingsResponse?.success ||
  rpcShellSettingsResponse?.data?.output !== 'from-settings' ||
  rpcShellSettingsResponse?.data?.exitCode !== 0
) {
  throw new Error('rpc bash smoke did not apply shellCommandPrefix from settings');
}
const compactResponse = rpcResponses.find((response) => response.id === 'compact-1');
if (
  !compactResponse?.success ||
  !compactResponse?.data?.summary?.includes('hello rpc') ||
  compactResponse?.data?.firstKeptEntryId !== 'm-2' ||
  compactResponse?.data?.details?.local !== true ||
  compactResponse?.data?.details?.customInstructions !== 'focus smoke'
) {
  throw new Error('rpc compact smoke did not return upstream-shaped local compaction result');
}
if (
  !rpcResponses.find((response) => response.id === 'auto-compact-1')?.success ||
  !rpcResponses.find((response) => response.id === 'auto-retry-1')?.success ||
  !rpcResponses.find((response) => response.id === 'abort-retry-1')?.success
) {
  throw new Error('rpc auto compaction/retry controls did not return success');
}
if (
  messagesResponse?.data?.messages?.[2]?.role !== 'bashExecution' ||
  messagesResponse?.data?.messages?.[2]?.command !== 'printf rpc-bash' ||
  messagesResponse?.data?.messages?.[2]?.output !== 'rpc-bash'
) {
  throw new Error('rpc get_messages smoke did not include bashExecution message');
}
const statsResponse = rpcResponses.find((response) => response.id === 'stats-1');
if (
  statsResponse?.data?.sessionFile !== rpcSessionFile ||
  statsResponse?.data?.userMessages !== 1 ||
  statsResponse?.data?.totalMessages !== 2
) {
  throw new Error('rpc get_session_stats smoke did not return durable stats');
}
const forkResponse = rpcResponses.find((response) => response.id === 'forks-1');
if (forkResponse?.data?.messages?.[0]?.text !== 'hello rpc' || !forkResponse?.data?.messages?.[0]?.entryId) {
  throw new Error('rpc get_fork_messages smoke did not return user entry text/id');
}
const exportResponse = rpcResponses.find((response) => response.id === 'export-1');
if (exportResponse?.data?.path !== rpcExportFile) {
  throw new Error('rpc export_html smoke did not return requested path');
}
const secondState = rpcResponses.find((response) => response.id === 'state-2');
if (
  secondState?.data?.messageCount !== 3 ||
  secondState?.data?.sessionName !== 'smoke session' ||
  secondState?.data?.sessionFile !== rpcSessionFile ||
  secondState?.data?.autoCompactionEnabled !== true ||
  secondState?.data?.model?.provider !== 'anthropic' ||
  secondState?.data?.model?.id !== 'claude-haiku-4-5'
) {
  throw new Error('rpc get_state smoke did not return updated state');
}
const jsonl = fs.readFileSync(rpcSessionFile, 'utf8');
if (
  !jsonl.includes('"type":"session"') ||
  !jsonl.includes('"type":"message"') ||
  !jsonl.includes('"hello rpc"') ||
  !jsonl.includes('"type":"model_change"') ||
  !jsonl.includes('"type":"compaction"') ||
  !jsonl.includes('"customInstructions":"focus smoke"') ||
  !jsonl.includes('"modelId":"claude-haiku-4-5"') ||
  !jsonl.includes('"role":"bashExecution"') ||
  !jsonl.includes('"rpc-bash"')
) {
  throw new Error('rpc durable JSONL file does not contain session header, prompt, and bashExecution message');
}
const exportedHtml = fs.readFileSync(rpcExportFile, 'utf8');
if (!exportedHtml.includes('pi-zig session') || !exportedHtml.includes('hello rpc') || !exportedHtml.includes('rpc-bash')) {
  throw new Error('rpc HTML export did not include session content');
}

const resumeOutput = run(
  ['rpc', rpcSessionFile],
  [
    JSON.stringify({ id: 'resume-state', type: 'get_state' }),
    JSON.stringify({ id: 'resume-messages', type: 'get_messages' }),
    JSON.stringify({ id: 'resume-stats', type: 'get_session_stats' }),
    ''
  ].join('\n')
);
const resumeResponses = resumeOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const resumeState = resumeResponses.find((response) => response.id === 'resume-state');
if (resumeState?.data?.messageCount !== 4 || resumeState?.data?.sessionName !== 'smoke session') {
  throw new Error('rpc resume smoke did not load message count and session name from JSONL');
}
if (resumeState?.data?.model?.provider !== 'anthropic' || resumeState?.data?.model?.id !== 'claude-haiku-4-5') {
  throw new Error('rpc resume smoke did not load model_change from JSONL');
}
const resumeMessages = resumeResponses.find((response) => response.id === 'resume-messages');
if (
  resumeMessages?.data?.messages?.[0]?.role !== 'compactionSummary' ||
  resumeMessages?.data?.messages?.[1]?.content !== 'hello rpc' ||
  resumeMessages?.data?.messages?.[2]?.role !== 'bashExecution' ||
  resumeMessages?.data?.messages?.[2]?.output !== 'rpc-bash' ||
  resumeMessages?.data?.messages?.[3]?.role !== 'bashExecution' ||
  resumeMessages?.data?.messages?.[3]?.output?.includes('rpc-bash-line-0000') ||
  !resumeMessages?.data?.messages?.[3]?.output?.includes('rpc-bash-line-2104')
) {
  throw new Error('rpc resume smoke did not reconstruct messages from JSONL');
}
const resumeStats = resumeResponses.find((response) => response.id === 'resume-stats');
if (resumeStats?.data?.userMessages !== 1 || resumeStats?.data?.totalMessages !== 3) {
  throw new Error('rpc resume smoke did not reconstruct durable stats');
}

const switchDriverFile = 'zig-out/pi-zig-rpc-switch-driver.jsonl';
const switchSessionFile = 'zig-out/pi-zig-rpc-switch-target.jsonl';
fs.rmSync(switchDriverFile, { force: true });
fs.writeFileSync(
  switchSessionFile,
  [
    JSON.stringify({ type: 'session', version: 3, id: 'switch-session', timestamp: '2026-05-26T00:00:00.000Z', cwd: '.' }),
    JSON.stringify({ type: 'message', id: 'a1b2c3d4', parentId: null, timestamp: '2026-05-26T00:00:01.000Z', message: { role: 'user', content: 'loaded user' } }),
    JSON.stringify({ type: 'message', id: 'b2c3d4e5', parentId: 'a1b2c3d4', timestamp: '2026-05-26T00:00:02.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'hello from assistant' }], provider: 'faux', model: 'fixture', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop' } }),
    JSON.stringify({ type: 'session_info', id: 'c3d4e5f6', parentId: 'b2c3d4e5', timestamp: '2026-05-26T00:00:03.000Z', name: 'loaded fixture' }),
    ''
  ].join('\n')
);
const switchOutput = run(
  ['rpc', switchDriverFile],
  [
    JSON.stringify({ id: 'switch', type: 'switch_session', sessionPath: switchSessionFile }),
    JSON.stringify({ id: 'switch-state', type: 'get_state' }),
    JSON.stringify({ id: 'switch-assistant', type: 'get_last_assistant_text' }),
    JSON.stringify({ id: 'cycle-model', type: 'cycle_model' }),
    ''
  ].join('\n')
);
const switchResponses = switchOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
if (!switchResponses.find((response) => response.id === 'switch')?.success) {
  throw new Error('rpc switch_session smoke failed');
}
const switchState = switchResponses.find((response) => response.id === 'switch-state');
if (
  switchState?.data?.sessionFile !== switchSessionFile ||
  switchState?.data?.sessionId !== 'switch-session' ||
  switchState?.data?.messageCount !== 2 ||
  switchState?.data?.sessionName !== 'loaded fixture'
) {
  throw new Error('rpc switch_session smoke did not load target session state');
}
const assistantText = switchResponses.find((response) => response.id === 'switch-assistant');
if (assistantText?.data?.text !== 'hello from assistant') {
  throw new Error('rpc get_last_assistant_text smoke did not read loaded assistant text');
}
const cycleModel = switchResponses.find((response) => response.id === 'cycle-model');
if (!cycleModel?.success || !cycleModel?.data?.model?.id || cycleModel?.data?.isScoped !== false) {
  throw new Error('rpc cycle_model smoke did not return an upstream-shaped cycle result');
}

const forkSessionFile = 'zig-out/pi-zig-rpc-fork-source.jsonl';
fs.rmSync(forkSessionFile, { force: true });
fs.rmSync(`${forkSessionFile}.fork-2.jsonl`, { force: true });
const forkRunResult = await runRpcSequential(
  ['rpc', forkSessionFile],
  [
    { id: 'fork-prompt-1', type: 'prompt', message: 'first fork prompt' },
    { id: 'fork-prompt-2', type: 'prompt', message: 'second fork prompt' },
    { id: 'fork-list', type: 'get_fork_messages' },
    { id: 'fork-run', type: 'fork', entryId: 'm-2' },
    { id: 'fork-state', type: 'get_state' }
  ]
);
const forkResponses = forkRunResult.lines;
const forkList = forkResponses.find((response) => response.id === 'fork-list');
if (
  forkList?.data?.messages?.length !== 2 ||
  forkList?.data?.messages?.[1]?.entryId !== 'm-2' ||
  forkList?.data?.messages?.[1]?.text !== 'second fork prompt'
) {
  throw new Error('rpc get_fork_messages smoke did not expose forkable user messages');
}
const forkRun = forkResponses.find((response) => response.id === 'fork-run');
if (!forkRun?.success || forkRun?.data?.text !== 'second fork prompt' || forkRun?.data?.cancelled !== false) {
  throw new Error('rpc fork smoke did not return selected text and cancellation state');
}
const forkState = forkResponses.find((response) => response.id === 'fork-state');
if (
  forkState?.data?.sessionFile !== `${forkSessionFile}.fork-2.jsonl` ||
  forkState?.data?.messageCount !== 1
) {
  throw new Error('rpc fork smoke did not rebind to a durable sibling session with prefix history');
}
const forkJsonl = fs.readFileSync(`${forkSessionFile}.fork-2.jsonl`, 'utf8');
if (!forkJsonl.includes(`"parentSession":"${forkSessionFile}"`) || forkJsonl.includes('second fork prompt')) {
  throw new Error('rpc fork JSONL did not record parent session or incorrectly copied selected prompt');
}

const cloneSessionFile = 'zig-out/pi-zig-rpc-clone-source.jsonl';
fs.rmSync(cloneSessionFile, { force: true });
fs.rmSync(`${cloneSessionFile}.clone-2.jsonl`, { force: true });
const cloneOutput = run(
  ['rpc', cloneSessionFile],
  [
    JSON.stringify({ id: 'clone-prompt', type: 'prompt', message: 'clone me' }),
    JSON.stringify({ id: 'clone-run', type: 'clone' }),
    JSON.stringify({ id: 'clone-state', type: 'get_state' }),
    ''
  ].join('\n')
);
const cloneResponses = cloneOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
if (!cloneResponses.find((response) => response.id === 'clone-run')?.success) {
  throw new Error('rpc clone smoke failed');
}
const cloneState = cloneResponses.find((response) => response.id === 'clone-state');
if (
  cloneState?.data?.sessionFile !== `${cloneSessionFile}.clone-2.jsonl` ||
  cloneState?.data?.messageCount !== 1
) {
  throw new Error('rpc clone smoke did not rebind to a copied sibling session');
}
const cloneJsonl = fs.readFileSync(`${cloneSessionFile}.clone-2.jsonl`, 'utf8');
if (!cloneJsonl.includes(`"parentSession":"${cloneSessionFile}"`) || !cloneJsonl.includes('clone me')) {
  throw new Error('rpc clone JSONL did not record parent session and copied prompt');
}

// ===== FLOW 01: inventory =====
// Guard the upstream inventory script so it cannot silently miss a package or
// surface. We run the script, assert it exits 0 (its own self-checks pass), then
// cross-check the reported package count against the package.json files actually
// on disk and confirm the machine-readable artifact was written.
{
  const inventoryStdout = execFileSync('node', ['scripts/upstream-inventory.mjs'], { encoding: 'utf8' });
  let inventory;
  try {
    inventory = JSON.parse(inventoryStdout).upstream;
  } catch (error) {
    throw new Error(`upstream-inventory.mjs did not emit valid JSON: ${error.message}`);
  }

  // Count package.json files on disk under upstream/pi/packages (excluding node_modules).
  function countPackageManifests(dir) {
    let total = 0;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'dist') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        total += countPackageManifests(full);
      } else if (entry.name === 'package.json') {
        total += 1;
      }
    }
    return total;
  }
  const onDiskPackages = countPackageManifests(path.resolve('upstream/pi/packages'));

  if (inventory.packageCount !== onDiskPackages) {
    throw new Error(
      `inventory reported ${inventory.packageCount} packages but ${onDiskPackages} package.json files exist on disk`,
    );
  }
  if (inventory.packages.length !== onDiskPackages) {
    throw new Error('inventory packages array length does not match the reported package count');
  }
  if (inventory.primaryPackageCount !== 4) {
    throw new Error(`inventory expected 4 primary packages, reported ${inventory.primaryPackageCount}`);
  }
  if (inventory.rpcCommands.length !== 29) {
    throw new Error(`inventory expected 29 inbound RPC commands, reported ${inventory.rpcCommands.length}`);
  }
  if (inventory.providers.transportApis.length !== 9) {
    throw new Error(`inventory expected 9 transport APIs, reported ${inventory.providers.transportApis.length}`);
  }
  if (inventory.providers.oauthProviders.length !== 3) {
    throw new Error(`inventory expected 3 OAuth providers, reported ${inventory.providers.oauthProviders.length}`);
  }
  if (inventory.extensions.events.length !== 29) {
    throw new Error(`inventory expected 29 extension events, reported ${inventory.extensions.events.length}`);
  }

  const artifactPath = path.resolve('docs/inventory/upstream-inventory.json');
  if (!fs.existsSync(artifactPath)) {
    throw new Error('upstream-inventory.mjs did not write docs/inventory/upstream-inventory.json');
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  if (artifact.counts.packages !== onDiskPackages) {
    throw new Error('inventory artifact package count does not match on-disk package.json files');
  }
}
console.log('flow 01 upstream inventory smoke passed');
// ===== FLOW 05: models =====
// Parity with upstream model registry/resolver:
//   upstream/pi/packages/ai/src/models.ts (getSupportedThinkingLevels)
//   upstream/pi/packages/coding-agent/src/core/model-resolver.ts (defaultModelPerProvider,
//     parseModelPattern, resolveCliModel, tryMatchModel alias preference)
// Proven against the live generated catalog, not mocks.

// Every provider default in upstream defaultModelPerProvider must resolve to a real
// catalog entry (DoD: provider-specific defaults are not stale hardcodes).
const flow05DefaultModelPerProvider = {
  'amazon-bedrock': 'us.anthropic.claude-opus-4-6-v1',
  anthropic: 'claude-opus-4-7',
  openai: 'gpt-5.4',
  'azure-openai-responses': 'gpt-5.4',
  'openai-codex': 'gpt-5.5',
  deepseek: 'deepseek-v4-pro',
  google: 'gemini-3.1-pro-preview',
  'google-vertex': 'gemini-3.1-pro-preview',
  'github-copilot': 'gpt-5.4',
  openrouter: 'moonshotai/kimi-k2.6',
  'vercel-ai-gateway': 'zai/glm-5.1',
  xai: 'grok-4.20-0309-reasoning',
  groq: 'openai/gpt-oss-120b',
  cerebras: 'zai-glm-4.7',
  zai: 'glm-5.1',
  mistral: 'devstral-medium-latest',
  minimax: 'MiniMax-M2.7',
  'minimax-cn': 'MiniMax-M2.7',
  moonshotai: 'kimi-k2.6',
  'moonshotai-cn': 'kimi-k2.6',
  huggingface: 'moonshotai/Kimi-K2.6',
  fireworks: 'accounts/fireworks/models/kimi-k2p6',
  together: 'moonshotai/Kimi-K2.6',
  opencode: 'kimi-k2.6',
  'opencode-go': 'kimi-k2.6',
  'kimi-coding': 'kimi-for-coding',
  'cloudflare-workers-ai': '@cf/moonshotai/kimi-k2.6',
  'cloudflare-ai-gateway': 'workers-ai/@cf/moonshotai/kimi-k2.6',
  xiaomi: 'mimo-v2.5-pro',
  'xiaomi-token-plan-cn': 'mimo-v2.5-pro',
  'xiaomi-token-plan-ams': 'mimo-v2.5-pro',
  'xiaomi-token-plan-sgp': 'mimo-v2.5-pro',
};
const flow05FullCatalog = JSON.parse(run(['models']));
// Providers that only exist as auth/OAuth overlays upstream and have no built-in catalog
// entries (no MODELS.<provider> block). Their defaults cannot resolve from the generated
// catalog alone; documented as platform gap rather than hidden.
const flow05CatalogProviders = new Set(flow05FullCatalog.models.map((model) => model.provider));
for (const [provider, modelId] of Object.entries(flow05DefaultModelPerProvider)) {
  if (!flow05CatalogProviders.has(provider)) {
    throw new Error(`models default-provider parity: provider "${provider}" missing from generated catalog`);
  }
  const resolved = JSON.parse(run(['model', provider, modelId]));
  if (resolved.error || resolved.provider !== provider || resolved.id !== modelId) {
    throw new Error(`models stale default: ${provider}/${modelId} does not exist in generated catalog`);
  }
}

// Default model count must match the upstream provider lineup exactly.
if (Object.keys(flow05DefaultModelPerProvider).length !== flow05FullCatalog.providers.length) {
  throw new Error('models default-provider map size drifted from generated provider count');
}

// Alias preference: fuzzy matches prefer an alias (no date/-latest suffix) over dated versions.
const flow05Alias = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'sonnet']));
if (flow05Alias.error !== null || !flow05Alias.model || !/sonnet/.test(flow05Alias.model.id) || /-\d{8}$/.test(flow05Alias.model.id)) {
  throw new Error('models alias preference: fuzzy sonnet did not resolve to an alias id');
}

// Provider/model split is preferred over a gateway model whose id literally contains a slash:
// "zai/glm-5.1" must resolve to provider=zai id=glm-5.1, not vercel-ai-gateway id=zai/glm-5.1.
const flow05Split = JSON.parse(run(['resolve-model', 'zai/glm-5.1']));
if (flow05Split.error !== null || flow05Split.model?.provider !== 'zai' || flow05Split.model?.id !== 'glm-5.1') {
  throw new Error('models provider-split: zai/glm-5.1 did not prefer the zai provider model');
}

// OpenRouter-style colon-in-id models: exact match must keep the full id, and a trailing
// valid thinking suffix must be stripped recursively while preserving the colon-bearing id.
const flow05ColonModel = flow05FullCatalog.models.find((model) => model.provider === 'openrouter' && model.id.endsWith(':free'));
if (!flow05ColonModel) {
  throw new Error('models colon-id parity: expected an openrouter :free model in the generated catalog');
}
const flow05ColonExact = JSON.parse(run(['resolve-model', `openrouter/${flow05ColonModel.id}`]));
if (flow05ColonExact.error !== null || flow05ColonExact.model?.id !== flow05ColonModel.id || flow05ColonExact.thinkingLevel !== null) {
  throw new Error('models colon-id parity: exact openrouter colon id did not match cleanly');
}
const flow05ColonThinking = JSON.parse(run(['resolve-model', `openrouter/${flow05ColonModel.id}:high`]));
if (flow05ColonThinking.error !== null || flow05ColonThinking.model?.id !== flow05ColonModel.id || flow05ColonThinking.thinkingLevel !== 'high') {
  throw new Error('models colon-id parity: colon id with :high suffix did not strip the thinking level');
}

// Thinking-variant metadata: deepseek-v4-flash disables minimal/low/medium but keeps off/high/xhigh,
// matching upstream getSupportedThinkingLevels over thinkingLevelMap.
const flow05DeepseekFlash = JSON.parse(run(['model', 'deepseek', 'deepseek-v4-flash']));
if (
  flow05DeepseekFlash.reasoning !== true ||
  JSON.stringify(flow05DeepseekFlash.supportedThinkingLevels) !== JSON.stringify(['off', 'high', 'xhigh'])
) {
  throw new Error('models thinking-variant parity: deepseek-v4-flash supported levels drifted');
}

// A reasoning model that maps off to null exposes no "off" level (azure gpt-5).
const flow05GptOffNull = JSON.parse(run(['model', 'azure-openai-responses', 'gpt-5']));
if (
  flow05GptOffNull.reasoning !== true ||
  flow05GptOffNull.supportedThinkingLevels.includes('off') ||
  !flow05GptOffNull.supportedThinkingLevels.includes('high')
) {
  throw new Error('models thinking-variant parity: off=null reasoning model still advertised off');
}

// Non-reasoning models only support the "off" thinking level.
const flow05NonReasoning = JSON.parse(run(['model', 'amazon-bedrock', 'amazon.nova-2-lite-v1:0']));
if (
  flow05NonReasoning.reasoning !== false ||
  JSON.stringify(flow05NonReasoning.supportedThinkingLevels) !== JSON.stringify(['off'])
) {
  throw new Error('models thinking-variant parity: non-reasoning model did not collapse to [off]');
}

// Image capability flag comes from generated metadata: claude has image input, deepseek-v4-flash does not.
const flow05Vision = JSON.parse(run(['model', 'anthropic', 'claude-haiku-4-5']));
if (!flow05Vision.input.includes('image') || !flow05Vision.input.includes('text')) {
  throw new Error('models image-capability parity: anthropic haiku missing image input flag');
}
if (flow05DeepseekFlash.input.includes('image')) {
  throw new Error('models image-capability parity: deepseek-v4-flash should be text-only');
}

// xhigh capability: a model whose thinkingLevelMap maps xhigh exposes it; otherwise it must not.
const flow05Xhigh = JSON.parse(run(['model', 'amazon-bedrock', 'anthropic.claude-opus-4-6-v1']));
if (!flow05Xhigh.supportedThinkingLevels.includes('xhigh')) {
  throw new Error('models thinking-variant parity: opus-4-6 should advertise xhigh');
}

// Strict CLI parsing: an invalid colon suffix on an explicit provider is treated as part of a
// custom model id (upstream allowInvalidThinkingLevelFallback=false + buildFallbackModel), not a
// thinking level, and is flagged customModel without erroring.
const flow05StrictCustom = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'claude-haiku-4-5:bogus']));
if (
  flow05StrictCustom.error !== null ||
  flow05StrictCustom.customModel !== true ||
  flow05StrictCustom.thinkingLevel !== null ||
  flow05StrictCustom.model?.provider !== 'anthropic' ||
  flow05StrictCustom.model?.id !== 'claude-haiku-4-5:bogus'
) {
  throw new Error('models strict parsing: invalid :suffix should become a custom model id, not a thinking level');
}

// Unknown provider yields a clear error and no model.
const flow05UnknownProvider = JSON.parse(run(['resolve-model', '--provider', 'not-a-provider', 'whatever']));
if (flow05UnknownProvider.model !== null || !/Unknown provider/.test(flow05UnknownProvider.error ?? '')) {
  throw new Error('models error parity: unknown provider did not produce an Unknown provider error');
}

// Unresolvable bare model (no provider, no match) yields a not-found error and no model.
const flow05NotFound = JSON.parse(run(['resolve-model', 'definitely-not-a-real-model-xyz']));
if (flow05NotFound.model !== null || !/not found/.test(flow05NotFound.error ?? '')) {
  throw new Error('models error parity: unresolvable bare model did not produce a not-found error');
// ===== FLOW 03: package/settings =====
const flow03Root = path.resolve('zig-out/pi-zig-flow03-fixture');
const flow03Home = path.join(flow03Root, 'home');
const flow03Project = path.join(flow03Root, 'project');
const flow03FakeBin = path.join(flow03Root, 'fake-bin');
const flow03Record = path.join(flow03Root, 'commands.jsonl');
const flow03GlobalSettingsPath = path.join(flow03Home, '.pi/agent/settings.json');
const flow03Env = {
  ...process.env,
  HOME: flow03Home,
  PATH: `${flow03FakeBin}${path.delimiter}${process.env.PATH ?? ''}`,
  PI_ZIG_FAKE_COMMAND_RECORD: flow03Record
};
fs.rmSync(flow03Root, { recursive: true, force: true });
fs.mkdirSync(path.join(flow03Home, '.pi/agent'), { recursive: true });
fs.mkdirSync(path.join(flow03Project, '.pi'), { recursive: true });
fs.mkdirSync(flow03FakeBin, { recursive: true });
function flow03Records() {
  const text = fs.existsSync(flow03Record) ? fs.readFileSync(flow03Record, 'utf8').trim() : '';
  return text ? text.split('\n').map((line) => JSON.parse(line)) : [];
}
fs.writeFileSync(
  path.join(flow03FakeBin, 'npm'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'npm', args, cwd: process.cwd() }) + '\\n');
function optionValue(name) { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; }
function packageName(spec) { const s = spec.startsWith('@') ? 1 : 0; const at = spec.lastIndexOf('@'); return at > s ? spec.slice(0, at) : spec; }
if (args[0] === 'view' && args[2] === 'version') { console.log(JSON.stringify(args[1] === 'pinned-extension' ? '1.0.0' : '2.0.0')); process.exit(0); }
const root = optionValue('--prefix') || process.cwd();
const installIndex = args.indexOf('install');
if (installIndex >= 0) {
  fs.mkdirSync(path.join(root, 'node_modules'), { recursive: true });
  for (const spec of args.slice(installIndex + 1)) {
    if (spec.startsWith('--')) break;
    const name = packageName(spec);
    if (!name) continue;
    const dir = path.join(root, 'node_modules', ...name.split('/'));
    fs.mkdirSync(dir, { recursive: true });
    const at = spec.startsWith('@') ? spec.slice(1).lastIndexOf('@') + 1 : spec.lastIndexOf('@');
    const version = at > 0 && !spec.endsWith('@latest') ? spec.slice(at + 1) : '1.0.0';
    fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name, version }));
  }
}
process.exit(0);
`
);
fs.chmodSync(path.join(flow03FakeBin, 'npm'), 0o755);
fs.writeFileSync(
  path.join(flow03FakeBin, 'git'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'git', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'clone') {
  const target = args[2];
  fs.mkdirSync(path.join(target, '.git'), { recursive: true });
  fs.writeFileSync(path.join(target, 'extension.js'), 'fake git extension');
} else if (args[0] === 'rev-parse') {
  console.log(args.includes('HEAD') && !args.includes('FETCH_HEAD') ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' : 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
}
process.exit(0);
`
);
fs.chmodSync(path.join(flow03FakeBin, 'git'), 0o755);

// Git source parsing parity: paths with fewer than two segments are not git
// sources (matches upstream parseGenericGitUrl), so they fall through to local
// handling and report a missing path instead of attempting a clone.
const flow03SingleSegment = runFail(['install', 'git:github.com/singleuser'], undefined, { cwd: flow03Project, env: flow03Env });
if (
  flow03SingleSegment.status !== 1 ||
  !flow03SingleSegment.stderr.includes('Path does not exist') ||
  flow03Records().some((record) => record.command === 'git' && record.args[0] === 'clone')
) {
  throw new Error('flow03: single-segment git shorthand should fall through to local handling, not clone');
}

// Two-segment git shorthand still parses as a git source and clones.
run(['install', 'git:github.com/user/repo'], undefined, { cwd: flow03Project, env: flow03Env });
if (!fs.existsSync(path.join(flow03Home, '.pi/agent/git/github.com/user/repo/extension.js'))) {
  throw new Error('flow03: two-segment git shorthand should clone into the managed git root');
}
run(['remove', 'git:github.com/user/repo'], undefined, { cwd: flow03Project, env: flow03Env });

// Package object filters persist verbatim and list as "(filtered)".
fs.writeFileSync(
  flow03GlobalSettingsPath,
  JSON.stringify({ packages: [{ source: 'npm:filtered-extension', skills: ['only-this'], extensions: [] }] }, null, 2)
);
const flow03FilteredList = run(['list'], undefined, { cwd: flow03Project, env: flow03Env });
if (!flow03FilteredList.includes('npm:filtered-extension (filtered)')) {
  throw new Error('flow03: object-form package source should be listed as filtered');
}

// Pinned npm versions are skipped by package updates; unpinned ones are checked.
fs.writeFileSync(
  flow03GlobalSettingsPath,
  JSON.stringify({ packages: ['npm:pinned-extension@1.0.0', 'npm:fresh-extension'] }, null, 2)
);
run(['install', 'npm:pinned-extension@1.0.0'], undefined, { cwd: flow03Project, env: flow03Env });
run(['install', 'npm:fresh-extension'], undefined, { cwd: flow03Project, env: flow03Env });
const flow03UpdateRecordStart = flow03Records().length;
run(['update', '--extensions'], undefined, { cwd: flow03Project, env: flow03Env });
const flow03UpdateRecords = flow03Records().slice(flow03UpdateRecordStart);
if (
  flow03UpdateRecords.some((record) => record.command === 'npm' && record.args.includes('view') && record.args.includes('pinned-extension')) ||
  flow03UpdateRecords.some((record) => record.command === 'npm' && record.args.includes('pinned-extension@latest')) ||
  !flow03UpdateRecords.some((record) => record.command === 'npm' && record.args.includes('view') && record.args.includes('fresh-extension')) ||
  !flow03UpdateRecords.some((record) => record.command === 'npm' && record.args.includes('fresh-extension@latest'))
) {
  throw new Error('flow03: package update should skip pinned npm versions and refresh unpinned stale ones');
}

// Pinned git refs are reconciled (fetched + reset to the ref) but not advanced.
fs.writeFileSync(
  flow03GlobalSettingsPath,
  JSON.stringify({ packages: ['git:github.com/user/pinned@v1.0.0'] }, null, 2)
);
run(['install', 'git:github.com/user/pinned@v1.0.0'], undefined, { cwd: flow03Project, env: flow03Env });
const flow03GitUpdateStart = flow03Records().length;
run(['update', '--extensions'], undefined, { cwd: flow03Project, env: flow03Env });
const flow03GitUpdateRecords = flow03Records().slice(flow03GitUpdateStart);
if (
  !flow03GitUpdateRecords.some((record) => record.command === 'git' && record.args[0] === 'fetch' && record.args.includes('v1.0.0')) ||
  !flow03GitUpdateRecords.some((record) => record.command === 'git' && record.args[0] === 'reset' && record.args.includes('FETCH_HEAD'))
) {
  throw new Error('flow03: pinned git ref update should fetch and reset to the configured ref');
}

// Settings migration: legacy fields are rewritten and unrelated keys preserved.
fs.writeFileSync(
  flow03GlobalSettingsPath,
  JSON.stringify({ queueMode: 'all', websockets: true, theme: 'dark', packages: ['npm:keep-me'] }, null, 2)
);
run(['settings', 'set', 'defaultModel', 'gpt-5-mini'], undefined, { cwd: flow03Project, env: flow03Env });
const flow03Migrated = JSON.parse(fs.readFileSync(flow03GlobalSettingsPath, 'utf8'));
if (
  flow03Migrated.queueMode !== undefined ||
  flow03Migrated.websockets !== undefined ||
  flow03Migrated.steeringMode !== 'all' ||
  flow03Migrated.transport !== 'websocket' ||
  flow03Migrated.theme !== 'dark' ||
  flow03Migrated.defaultModel !== 'gpt-5-mini' ||
  flow03Migrated.packages?.[0] !== 'npm:keep-me'
) {
  throw new Error('flow03: settings write should migrate legacy fields and preserve unrelated keys');
}

// Invalid JSON settings must surface an error and never be rewritten.
fs.writeFileSync(flow03GlobalSettingsPath, '{ not valid json');
const flow03InvalidWrite = runFail(['settings', 'set', 'theme', 'light'], undefined, { cwd: flow03Project, env: flow03Env });
if (
  flow03InvalidWrite.status !== 1 ||
  !flow03InvalidWrite.stderr.includes('Refusing to overwrite invalid settings file') ||
  fs.readFileSync(flow03GlobalSettingsPath, 'utf8') !== '{ not valid json'
) {
  throw new Error('flow03: invalid settings JSON must be reported and left untouched');
}

console.log('basic pi-zig smokes passed');
