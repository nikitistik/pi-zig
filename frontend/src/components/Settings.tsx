/** Model/provider, thinking, queue mode, compaction, retry, and session controls. */

import { useMemo, useState } from 'preact/hooks';
import type { Model, QueueModeValue, ThinkingLevel } from '../rpc/protocol';
import { useStore, useWorkbenchState } from '../hooks';

const THINKING_LEVELS: ThinkingLevel[] = ['off', 'low', 'medium', 'high', 'max'];
const QUEUE_MODES: QueueModeValue[] = ['all', 'one-at-a-time'];

function ModelPicker() {
  const store = useStore();
  const state = useWorkbenchState();
  const [provider, setProvider] = useState<string>('');

  const providers = useMemo(() => {
    const set = new Set<string>();
    for (const model of state.models) set.add(model.provider);
    return Array.from(set).sort();
  }, [state.models]);

  const activeProvider = provider || state.state?.model?.provider || providers[0] || '';
  const modelsForProvider = useMemo(
    () => state.models.filter((m) => m.provider === activeProvider),
    [state.models, activeProvider],
  );

  const onSelectModel = (event: Event) => {
    const id = (event.target as HTMLSelectElement).value;
    const model = state.models.find((m) => m.provider === activeProvider && m.id === id);
    if (model) void store.selectModel(model);
  };

  const current = state.state?.model;

  return (
    <div class="control-group">
      <label class="control-label">Provider</label>
      <select
        class="select"
        value={activeProvider}
        disabled={state.connection !== 'open' || state.loadingModels}
        onChange={(e) => setProvider((e.target as HTMLSelectElement).value)}
      >
        {providers.length === 0 ? <option value="">{state.loadingModels ? 'Loading…' : 'No providers'}</option> : null}
        {providers.map((p) => (
          <option value={p} key={p}>
            {p}
          </option>
        ))}
      </select>

      <label class="control-label">Model</label>
      <select
        class="select"
        value={current?.provider === activeProvider ? current.id : ''}
        disabled={state.connection !== 'open' || modelsForProvider.length === 0}
        onChange={onSelectModel}
      >
        <option value="" disabled>
          {modelsForProvider.length === 0 ? 'No models' : 'Select model…'}
        </option>
        {modelsForProvider.map((m: Model) => (
          <option value={m.id} key={m.id}>
            {m.name}
            {m.reasoning ? ' · reasoning' : ''}
          </option>
        ))}
      </select>

      {current ? (
        <p class="muted small">
          {current.provider}/{current.id} · ctx {current.contextWindow.toLocaleString()} · out {current.maxTokens.toLocaleString()}
          {current.input.includes('image') ? ' · vision' : ''}
        </p>
      ) : (
        <p class="muted small">No model selected — prompts will be acknowledged without a reply.</p>
      )}
    </div>
  );
}

export function Settings() {
  const store = useStore();
  const state = useWorkbenchState();
  const s = state.state;
  const disabled = state.connection !== 'open';
  const [nameDraft, setNameDraft] = useState('');

  const supportedLevels = s?.model?.supportedThinkingLevels ?? THINKING_LEVELS;

  return (
    <section class="panel">
      <div class="panel-head">
        <h2>Controls</h2>
        <button class="btn ghost tiny" onClick={() => void store.refreshState()} disabled={disabled}>
          Refresh
        </button>
      </div>
      <div class="panel-body">
        <ModelPicker />

        <div class="control-group">
          <label class="control-label">Thinking level</label>
          <div class="segmented">
            {THINKING_LEVELS.map((level) => {
              const allowed = supportedLevels.includes(level);
              return (
                <button
                  key={level}
                  class="segment"
                  data-active={s?.thinkingLevel === level ? 'true' : 'false'}
                  disabled={disabled || !allowed}
                  title={allowed ? '' : 'Not supported by current model'}
                  onClick={() => void store.setThinkingLevel(level)}
                >
                  {level}
                </button>
              );
            })}
          </div>
        </div>

        <div class="control-group">
          <label class="control-label">Steering mode</label>
          <div class="segmented">
            {QUEUE_MODES.map((mode) => (
              <button
                key={mode}
                class="segment"
                data-active={s?.steeringMode === mode ? 'true' : 'false'}
                disabled={disabled}
                onClick={() => void store.setSteeringMode(mode)}
              >
                {mode}
              </button>
            ))}
          </div>
          <label class="control-label">Follow-up mode</label>
          <div class="segmented">
            {QUEUE_MODES.map((mode) => (
              <button
                key={mode}
                class="segment"
                data-active={s?.followUpMode === mode ? 'true' : 'false'}
                disabled={disabled}
                onClick={() => void store.setFollowUpMode(mode)}
              >
                {mode}
              </button>
            ))}
          </div>
        </div>

        <div class="control-group">
          <label class="toggle">
            <input
              type="checkbox"
              checked={s?.autoCompactionEnabled ?? false}
              disabled={disabled}
              onChange={(e) => void store.setAutoCompaction((e.target as HTMLInputElement).checked)}
            />
            <span>Auto compaction</span>
          </label>
          <label class="toggle">
            <input
              type="checkbox"
              checked={s?.autoRetryEnabled ?? false}
              disabled={disabled}
              onChange={(e) => void store.setAutoRetry((e.target as HTMLInputElement).checked)}
            />
            <span>Auto retry</span>
          </label>
        </div>

        <div class="control-group">
          <label class="control-label">Session</label>
          <div class="button-row">
            <button class="btn ghost" disabled={disabled} onClick={() => void store.compact()}>
              Compact
            </button>
            <button class="btn ghost" disabled={disabled} onClick={() => void store.exportHtml()}>
              Export HTML
            </button>
            <button class="btn ghost" disabled={disabled} onClick={() => void store.newSession()}>
              New session
            </button>
          </div>
          <div class="name-row">
            <input
              class="filter-input"
              placeholder={s?.sessionName ?? 'Set session name…'}
              value={nameDraft}
              disabled={disabled}
              onInput={(e) => setNameDraft((e.target as HTMLInputElement).value)}
            />
            <button
              class="btn ghost"
              disabled={disabled || nameDraft.trim().length === 0}
              onClick={() => {
                void store.setSessionName(nameDraft);
                setNameDraft('');
              }}
            >
              Rename
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
