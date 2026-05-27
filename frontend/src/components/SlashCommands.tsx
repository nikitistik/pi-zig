/** Slash command browser: lists extension/prompt/skill commands; runs on click. */

import { useMemo, useState } from 'preact/hooks';
import { useStore, useWorkbenchState } from '../hooks';

export function SlashCommands() {
  const store = useStore();
  const state = useWorkbenchState();
  const [filter, setFilter] = useState('');

  const filtered = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    if (needle.length === 0) return state.commands;
    return state.commands.filter(
      (c) => c.name.toLowerCase().includes(needle) || (c.description ?? '').toLowerCase().includes(needle),
    );
  }, [state.commands, filter]);

  const streaming = state.state?.isStreaming ?? false;

  return (
    <section class="panel">
      <div class="panel-head">
        <h2>Commands</h2>
        <button class="btn ghost tiny" onClick={() => void store.refreshCommands()} disabled={state.connection !== 'open'}>
          Reload
        </button>
      </div>
      <div class="panel-body">
        <input
          class="filter-input"
          placeholder="Filter commands…"
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        {state.loadingCommands ? (
          <p class="muted small">Loading commands…</p>
        ) : filtered.length === 0 ? (
          <p class="muted small">{state.commands.length === 0 ? 'No commands available.' : 'No matches.'}</p>
        ) : (
          <ul class="command-browser">
            {filtered.map((command, index) => (
              <li key={`${command.source}:${command.name}:${index}`}>
                <button
                  class="command-item"
                  title={streaming ? 'Sends as steering while streaming' : `Run /${command.name}`}
                  disabled={state.connection !== 'open'}
                  onClick={() => {
                    const text = `/${command.name}`;
                    if (streaming) void store.steer(text);
                    else void store.sendPrompt(text);
                  }}
                >
                  <span class="command-name">/{command.name}</span>
                  <span class="command-source" data-source={command.source}>
                    {command.source}
                  </span>
                  {command.description ? <span class="command-desc">{command.description}</span> : null}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
