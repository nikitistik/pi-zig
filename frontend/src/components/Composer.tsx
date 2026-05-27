/** Prompt composer: text input, image attachments, send/steer/follow-up, abort. */

import { useRef, useState } from 'preact/hooks';
import { fileToImageContent, useStore, useWorkbenchState } from '../hooks';

export function Composer() {
  const store = useStore();
  const state = useWorkbenchState();
  const [text, setText] = useState('');
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  // `busy` is set the instant a prompt is sent; the backend's get_state is
  // blocked while a prompt thread runs, so isStreaming can lag. Treat either as
  // "agent active" for steering and showing the Abort control (abort is a
  // non-blocking command that reaches the backend mid-run).
  const streaming = (state.state?.isStreaming ?? false) || state.busy;
  const connected = state.connection === 'open';

  const onAttach = async (files: FileList | null) => {
    if (!files) return;
    for (const file of Array.from(files)) {
      if (!file.type.startsWith('image/')) {
        continue;
      }
      try {
        const image = await fileToImageContent(file);
        store.addAttachment(image);
      } catch {
        /* ignore unreadable file */
      }
    }
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  const submit = async () => {
    if (text.trim().length === 0 && state.attachments.length === 0) return;
    const value = text;
    setText('');
    if (streaming) {
      await store.steer(value);
    } else {
      await store.sendPrompt(value);
    }
  };

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      void submit();
    }
  };

  return (
    <div class="composer">
      {state.attachments.length > 0 ? (
        <div class="attachments">
          {state.attachments.map((image, i) => (
            <div class="attachment" key={i}>
              <img src={`data:${image.mimeType};base64,${image.data}`} alt="attachment preview" />
              <button class="attachment-remove" title="Remove" onClick={() => store.removeAttachment(i)}>
                ×
              </button>
            </div>
          ))}
        </div>
      ) : null}

      <div class="composer-row">
        <textarea
          class="composer-input"
          rows={3}
          placeholder={streaming ? 'Steer the running agent… (Cmd/Ctrl+Enter)' : 'Send a message or /command… (Cmd/Ctrl+Enter)'}
          value={text}
          disabled={!connected}
          onInput={(e) => setText((e.target as HTMLTextAreaElement).value)}
          onKeyDown={onKeyDown}
        />
      </div>

      <div class="composer-actions">
        <div class="composer-actions-left">
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            multiple
            class="visually-hidden"
            id="image-input"
            onChange={(e) => void onAttach((e.target as HTMLInputElement).files)}
          />
          <label class="btn ghost" for="image-input" title="Attach image">
            Attach image
          </label>
          {streaming ? (
            <button class="btn ghost" disabled={!connected} onClick={() => void store.followUp(text)}>
              Queue follow-up
            </button>
          ) : null}
        </div>

        <div class="composer-actions-right">
          {streaming ? (
            <button class="btn danger" disabled={!connected} onClick={() => void store.abort()}>
              Abort
            </button>
          ) : null}
          {state.state?.isBashRunning ? (
            <button class="btn danger" disabled={!connected} onClick={() => void store.abortBash()}>
              Abort bash
            </button>
          ) : null}
          {state.state?.isRetrying ? (
            <button class="btn ghost" disabled={!connected} onClick={() => void store.abortRetry()}>
              Stop retry
            </button>
          ) : null}
          <button class="btn primary" disabled={!connected} onClick={() => void submit()}>
            {streaming ? 'Steer' : 'Send'}
          </button>
        </div>
      </div>
    </div>
  );
}
