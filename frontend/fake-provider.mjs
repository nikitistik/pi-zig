/**
 * Minimal OpenAI-compatible fake provider for smoke-testing the real Zig agent
 * loop without a paid API key.
 *
 * The Zig client (src/pi/ai_client.zig) posts to `<PI_ZIG_PROVIDER_BASE_URL>
 * /chat/completions` with `"stream": true` and reads a `data:`-prefixed SSE
 * stream terminated by `data: [DONE]`. Each chunk is parsed as
 * `{ choices: [{ delta: { content } }] }`. This server returns a canned reply
 * (optionally echoing whether an image was attached) so prompt/stream/abort
 * flows exercise the genuine backend.
 *
 *   PORT  listen port (default 8799). Set PI_ZIG_PROVIDER_BASE_URL to
 *         http://127.0.0.1:<PORT>/v1 and OPENAI_API_KEY to any value.
 */

import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 8799);
const REPLY = process.env.FAKE_REPLY ?? 'Hello from the fake provider. The pi-zig workbench round-trip works.';
// Optional delay before responding, to keep a request in-flight long enough to
// exercise the abort control during verification.
const DELAY_MS = Number(process.env.FAKE_DELAY_MS ?? 0);

function chunk(content, first) {
  const delta = first ? { role: 'assistant', content } : { content };
  return `data: ${JSON.stringify({ id: 'fake', object: 'chat.completion.chunk', choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`;
}

function finalChunk() {
  return `data: ${JSON.stringify({ id: 'fake', object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`;
}

const server = createServer((req, res) => {
  if (!req.url || !req.url.includes('chat/completions')) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
    return;
  }

  let body = '';
  req.on('data', (d) => (body += d));
  req.on('end', () => {
    if (DELAY_MS > 0) {
      const timer = setTimeout(() => respond(), DELAY_MS);
      req.on('close', () => clearTimeout(timer));
    } else {
      respond();
    }
    return;

    function respond() {
    let stream = false;
    let hasImage = false;
    try {
      const parsed = JSON.parse(body || '{}');
      stream = parsed.stream === true;
      const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
      hasImage = JSON.stringify(messages).includes('image_url') || JSON.stringify(messages).includes('"image"');
    } catch {
      /* ignore malformed body */
    }
    console.log(`[fake-provider] ${req.method} ${req.url} stream=${stream} (${body.length} bytes)`);

    const reply = `${REPLY}${hasImage ? ' I can see the attached image.' : ''}`;

    if (!stream) {
      // Non-streaming chat-completions response (matches the shape the Zig
      // parser expects in src/pi/ai_client.zig: choices[].message.content).
      const buf = Buffer.from(
        JSON.stringify({
          id: 'fake',
          object: 'chat.completion',
          choices: [{ index: 0, message: { role: 'assistant', content: reply }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
        }),
        'utf8',
      );
      res.writeHead(200, {
        'content-type': 'application/json',
        'content-length': String(buf.length),
        connection: 'keep-alive',
      });
      res.end(buf);
      return;
    }

    // Streaming SSE response: one delta per word, then [DONE].
    const words = reply.split(' ');
    let payload = '';
    words.forEach((word, i) => {
      payload += chunk((i === 0 ? '' : ' ') + word, i === 0);
    });
    payload += finalChunk();
    payload += 'data: [DONE]\n\n';

    const bodyBuf = Buffer.from(payload, 'utf8');
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      'content-length': String(bodyBuf.length),
      connection: 'keep-alive',
    });
    res.end(bodyBuf);
    }
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[fake-provider] OpenAI-compatible SSE endpoint on http://127.0.0.1:${PORT}/v1/chat/completions`);
});
