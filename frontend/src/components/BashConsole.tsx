/** Inline bash runner: sends a `bash` command through the real backend. */

import { useState } from 'preact/hooks';
import { useStore, useWorkbenchState } from '../hooks';

export function BashConsole() {
  const store = useStore();
  const state = useWorkbenchState();
  const [command, setCommand] = useState('');
  const disabled = state.connection !== 'open';
  const running = state.state?.isBashRunning ?? false;

  const run = () => {
    if (command.trim().length === 0) return;
    void store.runBash(command);
    setCommand('');
  };

  return (
    <section class="panel">
      <div class="panel-head">
        <h2>Bash</h2>
        {running ? <span class="pill warn">running</span> : null}
      </div>
      <div class="panel-body">
        <div class="name-row">
          <input
            class="filter-input mono"
            placeholder="echo hello"
            value={command}
            disabled={disabled}
            onInput={(e) => setCommand((e.target as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') run();
            }}
          />
          <button class="btn ghost" disabled={disabled || command.trim().length === 0} onClick={run}>
            Run
          </button>
          {running ? (
            <button class="btn danger" disabled={disabled} onClick={() => void store.abortBash()}>
              Abort
            </button>
          ) : null}
        </div>
        <p class="muted small">Output is appended to the transcript as a bash entry.</p>
      </div>
    </section>
  );
}
