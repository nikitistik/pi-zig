/** Session transcript: renders the ordered message history with tool panels. */

import { useEffect, useRef } from 'preact/hooks';
import type { AgentMessage, ImageContent, ToolCall } from '../rpc/protocol';

function roleLabel(role: AgentMessage['role']): string {
  switch (role) {
    case 'bashExecution':
      return 'bash';
    case 'compactionSummary':
      return 'compaction';
    default:
      return role;
  }
}

function ImageThumb({ image }: { image: ImageContent }) {
  const src = `data:${image.mimeType};base64,${image.data}`;
  return <img class="msg-image" src={src} alt="attachment" />;
}

function ToolCallPanel({ call }: { call: ToolCall }) {
  let pretty = call.argumentsJson;
  try {
    pretty = JSON.stringify(JSON.parse(call.argumentsJson), null, 2);
  } catch {
    /* leave raw */
  }
  return (
    <details class="tool-call" open>
      <summary>
        <span class="tool-badge">tool</span>
        <code>{call.name}</code>
        <span class="tool-id">{call.id}</span>
      </summary>
      <pre class="tool-args">{pretty}</pre>
    </details>
  );
}

function ToolResultPanel({ message }: { message: AgentMessage }) {
  return (
    <details class="tool-result" data-error={message.isError ? 'true' : 'false'} open>
      <summary>
        <span class="tool-badge" data-error={message.isError ? 'true' : 'false'}>
          {message.isError ? 'tool error' : 'tool result'}
        </span>
        {message.toolName ? <code>{message.toolName}</code> : null}
      </summary>
      <pre class="tool-output">{message.content ?? ''}</pre>
    </details>
  );
}

function BashPanel({ message }: { message: AgentMessage }) {
  return (
    <div class="bash-panel">
      <div class="bash-command">
        <span class="prompt-sign">$</span>
        <code>{message.command ?? ''}</code>
        {message.cancelled ? <span class="pill warn">cancelled</span> : null}
        {typeof message.exitCode === 'number' ? (
          <span class="pill" data-bad={message.exitCode !== 0 ? 'true' : 'false'}>
            exit {message.exitCode}
          </span>
        ) : null}
      </div>
      <pre class="bash-output">{message.output ?? ''}</pre>
      {message.truncated ? <p class="muted small">output truncated{message.fullOutputPath ? ` (full: ${message.fullOutputPath})` : ''}</p> : null}
    </div>
  );
}

function MessageBlock({ message }: { message: AgentMessage }) {
  if (message.role === 'tool') {
    return <ToolResultPanel message={message} />;
  }
  if (message.role === 'bashExecution') {
    return (
      <article class="msg" data-role="bash">
        <header class="msg-head">
          <span class="role-badge" data-role="bash">bash</span>
        </header>
        <BashPanel message={message} />
      </article>
    );
  }
  if (message.role === 'compactionSummary') {
    return (
      <article class="msg" data-role="compaction">
        <header class="msg-head">
          <span class="role-badge" data-role="compaction">compaction</span>
          {typeof message.tokensBefore === 'number' ? (
            <span class="muted small">{message.tokensBefore} tokens before</span>
          ) : null}
        </header>
        <p class="msg-body">{message.summary ?? message.content ?? ''}</p>
      </article>
    );
  }

  const failed = message.role === 'assistant' && (message.stopReason === 'error' || message.stopReason === 'aborted');
  return (
    <article class="msg" data-role={message.role}>
      <header class="msg-head">
        <span class="role-badge" data-role={message.role}>{roleLabel(message.role)}</span>
        {message.role === 'custom' && message.customType ? (
          <span class="muted small">{message.customType}</span>
        ) : null}
        {failed ? <span class="pill bad">{message.stopReason}</span> : null}
      </header>
      {message.content ? <p class="msg-body">{message.content}</p> : null}
      {failed && message.errorMessage ? <p class="msg-error">{message.errorMessage}</p> : null}
      {message.images && message.images.length > 0 ? (
        <div class="msg-images">
          {message.images.map((image, i) => (
            <ImageThumb image={image} key={i} />
          ))}
        </div>
      ) : null}
      {message.toolCalls && message.toolCalls.length > 0 ? (
        <div class="tool-calls">
          {message.toolCalls.map((call) => (
            <ToolCallPanel call={call} key={call.id} />
          ))}
        </div>
      ) : null}
    </article>
  );
}

export function Transcript({
  messages,
  loading,
  streaming,
}: {
  messages: AgentMessage[];
  loading: boolean;
  streaming: boolean;
}) {
  const endRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [messages.length, streaming]);

  if (loading && messages.length === 0) {
    return (
      <div class="transcript-empty">
        <div class="spinner" aria-label="Loading" />
        <p>Loading session history…</p>
      </div>
    );
  }

  if (messages.length === 0 && !streaming) {
    return (
      <div class="transcript-empty">
        <h3>No messages yet</h3>
        <p class="muted">Send a prompt below to start the conversation. Slash commands and bash run inline.</p>
      </div>
    );
  }

  return (
    <div class="transcript" role="log" aria-live="polite">
      {messages.map((message, i) => (
        <MessageBlock message={message} key={i} />
      ))}
      {streaming ? (
        <div class="streaming-indicator">
          <div class="spinner small" aria-label="Assistant is working" />
          <span>Assistant is working…</span>
        </div>
      ) : null}
      <div ref={endRef} />
    </div>
  );
}
