/** Session metadata + stats panel. */

import { useStore, useWorkbenchState } from '../hooks';

export function SessionInfo() {
  const store = useStore();
  const state = useWorkbenchState();
  const s = state.state;

  return (
    <section class="panel">
      <div class="panel-head">
        <h2>Session</h2>
        <button
          class="btn ghost tiny"
          onClick={() => {
            void store.refreshState();
            void store.refreshMessages();
          }}
          disabled={state.connection !== 'open'}
        >
          Refresh
        </button>
      </div>
      <div class="panel-body">
        {s ? (
          <dl class="kv">
            <div>
              <dt>id</dt>
              <dd class="mono">{s.sessionId || '—'}</dd>
            </div>
            <div>
              <dt>file</dt>
              <dd class="mono small">{s.sessionFile || '—'}</dd>
            </div>
            {s.sessionName ? (
              <div>
                <dt>name</dt>
                <dd>{s.sessionName}</dd>
              </div>
            ) : null}
            <div>
              <dt>messages</dt>
              <dd>{s.messageCount}</dd>
            </div>
            <div>
              <dt>pending</dt>
              <dd>
                {s.pendingMessageCount} ({s.pendingSteeringCount} steer / {s.pendingFollowUpCount} follow-up)
              </dd>
            </div>
          </dl>
        ) : (
          <p class="muted small">Not connected.</p>
        )}
      </div>
    </section>
  );
}
