/** Live event log: every unsolicited backend event (lifecycle, retry, etc.). */

import { useStore, useWorkbenchState } from '../hooks';

function summarize(type: string, raw: Record<string, unknown>): string {
  switch (type) {
    case 'auto_retry_start':
      return `attempt ${raw.attempt}/${raw.maxAttempts}, delay ${raw.delayMs}ms`;
    case 'auto_retry_end':
      return raw.success ? `recovered at attempt ${raw.attempt}` : `gave up at attempt ${raw.attempt}`;
    case 'agent_end':
      return raw.willRetry ? 'will retry' : 'turn complete';
    case 'response':
      return `${raw.command} ${raw.success ? 'ok' : 'error'}`;
    default:
      return '';
  }
}

export function EventLog() {
  const store = useStore();
  const state = useWorkbenchState();

  return (
    <section class="panel">
      <div class="panel-head">
        <h2>Event stream</h2>
        <button class="btn ghost tiny" onClick={() => store.clearEvents()} disabled={state.events.length === 0}>
          Clear
        </button>
      </div>
      <div class="panel-body">
        {state.events.length === 0 ? (
          <p class="muted small">No events yet. Lifecycle, retry, and status events appear here while the agent runs.</p>
        ) : (
          <ul class="event-list">
            {state.events
              .slice()
              .reverse()
              .map((entry) => (
                <li class="event-item" key={entry.id}>
                  <span class="event-type" data-type={entry.type}>
                    {entry.type}
                  </span>
                  <span class="event-detail">{summarize(entry.type, entry.raw as Record<string, unknown>)}</span>
                  <span class="event-time">{new Date(entry.at).toLocaleTimeString()}</span>
                </li>
              ))}
          </ul>
        )}
      </div>
    </section>
  );
}
