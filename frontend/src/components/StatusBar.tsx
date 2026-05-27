/** Top status bar: connection state, session id, model, streaming indicator. */

import type { TransportStatus } from '../rpc/transport';
import { useWorkbenchState } from '../hooks';

function connectionText(status: TransportStatus): string {
  switch (status) {
    case 'open':
      return 'connected';
    case 'connecting':
      return 'connecting';
    case 'closed':
      return 'disconnected';
    case 'error':
      return 'error';
  }
}

export function StatusBar() {
  const state = useWorkbenchState();
  const s = state.state;

  return (
    <header class="statusbar">
      <div class="statusbar-left">
        <span class="wordmark">pi-zig</span>
        <span class="subtitle">workbench</span>
      </div>
      <div class="statusbar-right">
        {s?.isStreaming ? <span class="pill live">streaming</span> : null}
        {s?.isRetrying ? <span class="pill warn">retrying</span> : null}
        {s?.isBashRunning ? <span class="pill warn">bash</span> : null}
        {s && s.pendingMessageCount > 0 ? (
          <span class="pill">queued {s.pendingMessageCount}</span>
        ) : null}
        {s?.model ? (
          <span class="status-model" title={`${s.model.provider}/${s.model.id}`}>
            {s.model.provider}/{s.model.name}
          </span>
        ) : (
          <span class="status-model muted">no model</span>
        )}
        <span class="conn" data-status={state.connection}>
          <span class="conn-dot" />
          {connectionText(state.connection)}
        </span>
      </div>
    </header>
  );
}

export function Toasts() {
  const state = useWorkbenchState();
  if (state.toasts.length === 0) return null;
  return (
    <div class="toasts" role="status" aria-live="polite">
      {state.toasts.map((toast) => (
        <div class="toast" data-kind={toast.kind} key={toast.id}>
          {toast.message}
        </div>
      ))}
    </div>
  );
}
