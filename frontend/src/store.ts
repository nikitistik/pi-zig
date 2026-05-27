/**
 * Workbench store: a tiny observable that wires the RpcClient to UI state.
 *
 * It owns the canonical view of session state, transcript messages, available
 * models, slash commands, the live event log, and connection status. UI
 * components subscribe via the `useStore` hook (see hooks.ts).
 *
 * Streaming model: the Zig runtime delivers a completed assistant turn as a
 * single `prompt` response (data.text) rather than incremental text deltas,
 * and emits lifecycle/status events (message_start/turn_end/agent_end/
 * auto_retry_*) while running. We therefore reflect "streaming" via state
 * (isStreaming) and refresh the transcript when a turn settles, while logging
 * every event so tool/lifecycle activity is visible live.
 */

import { RpcClient, RpcError } from './rpc/client';
import {
  type AgentMessage,
  type ImageContent,
  type Model,
  type QueueModeValue,
  type RpcEvent,
  type SessionState,
  type SlashCommand,
  type ThinkingLevel,
} from './rpc/protocol';
import { WebSocketTransport, type TransportStatus } from './rpc/transport';

export interface EventLogEntry {
  id: number;
  at: number;
  type: string;
  raw: RpcEvent;
}

export interface ToastEntry {
  id: number;
  kind: 'error' | 'info';
  message: string;
}

export interface WorkbenchState {
  connection: TransportStatus;
  connectionDetail?: string;
  state: SessionState | null;
  messages: AgentMessage[];
  models: Model[];
  commands: SlashCommand[];
  events: EventLogEntry[];
  toasts: ToastEntry[];
  /** Pending composer attachments (data URLs decoded to ImageContent). */
  attachments: ImageContent[];
  loadingMessages: boolean;
  loadingModels: boolean;
  loadingCommands: boolean;
  /** True between sending a prompt and receiving its settling response. */
  busy: boolean;
  lastError?: string;
  /** Last assistant turn text captured directly from a prompt response. */
  lastTurnText?: string;
}

type Listener = () => void;

const MAX_EVENTS = 200;

export class WorkbenchStore {
  private listeners = new Set<Listener>();
  private seq = 0;
  readonly client: RpcClient;

  private current: WorkbenchState = {
    connection: 'connecting',
    state: null,
    messages: [],
    models: [],
    commands: [],
    events: [],
    toasts: [],
    attachments: [],
    loadingMessages: false,
    loadingModels: false,
    loadingCommands: false,
    busy: false,
  };

  constructor(client?: RpcClient) {
    this.client = client ?? new RpcClient(new WebSocketTransport());
    this.client.onStatus((status, detail) => {
      const wasOffline = this.current.connection !== 'open';
      this.patch({ connection: status, connectionDetail: detail });
      if (status === 'open' && wasOffline) {
        void this.bootstrap();
      }
    });
    this.client.onEvent((event) => this.handleEvent(event));
  }

  getState(): WorkbenchState {
    return this.current;
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private patch(partial: Partial<WorkbenchState>): void {
    this.current = { ...this.current, ...partial };
    for (const listener of this.listeners) listener();
  }

  private nextId(): number {
    return ++this.seq;
  }

  private pushToast(kind: ToastEntry['kind'], message: string): void {
    const toast: ToastEntry = { id: this.nextId(), kind, message };
    this.patch({ toasts: [...this.current.toasts, toast] });
    setTimeout(() => this.dismissToast(toast.id), kind === 'error' ? 6000 : 3000);
  }

  dismissToast(id: number): void {
    this.patch({ toasts: this.current.toasts.filter((t) => t.id !== id) });
  }

  private handleEvent(event: RpcEvent): void {
    const entry: EventLogEntry = {
      id: this.nextId(),
      at: Date.now(),
      type: event.type,
      raw: event,
    };
    const events = [...this.current.events, entry].slice(-MAX_EVENTS);
    this.patch({ events });

    // When a turn settles or retries finish, refresh state + transcript so
    // tool calls and the assistant reply appear.
    if (
      event.type === 'agent_end' ||
      event.type === 'turn_end' ||
      event.type === 'auto_retry_end'
    ) {
      void this.refreshAfterTurn();
    }
    if (event.type === 'auto_retry_start') {
      const attempt = typeof event.attempt === 'number' ? event.attempt : '?';
      const max = typeof event.maxAttempts === 'number' ? event.maxAttempts : '?';
      this.pushToast('info', `Retrying (attempt ${attempt}/${max})`);
    }
  }

  private async refreshAfterTurn(): Promise<void> {
    await Promise.allSettled([this.refreshState(), this.refreshMessages()]);
  }

  // --- Bootstrap + refreshers ------------------------------------------------

  async bootstrap(): Promise<void> {
    await Promise.allSettled([
      this.refreshState(),
      this.refreshMessages(),
      this.refreshModels(),
      this.refreshCommands(),
    ]);
  }

  async refreshState(): Promise<void> {
    try {
      const state = await this.client.getState();
      this.patch({ state });
    } catch (err) {
      this.reportError(err);
    }
  }

  async refreshMessages(): Promise<void> {
    this.patch({ loadingMessages: true });
    try {
      const { messages } = await this.client.getMessages();
      this.patch({ messages, loadingMessages: false });
    } catch (err) {
      this.patch({ loadingMessages: false });
      this.reportError(err);
    }
  }

  async refreshModels(): Promise<void> {
    this.patch({ loadingModels: true });
    try {
      const { models } = await this.client.getAvailableModels();
      this.patch({ models, loadingModels: false });
    } catch (err) {
      this.patch({ loadingModels: false });
      this.reportError(err);
    }
  }

  async refreshCommands(): Promise<void> {
    this.patch({ loadingCommands: true });
    try {
      const { commands } = await this.client.getCommands();
      this.patch({ commands, loadingCommands: false });
    } catch (err) {
      this.patch({ loadingCommands: false });
      this.reportError(err);
    }
  }

  // --- Actions ---------------------------------------------------------------

  async sendPrompt(message: string): Promise<void> {
    const trimmed = message.trim();
    if (trimmed.length === 0) return;
    const images = this.current.attachments;
    this.patch({ busy: true, attachments: [], lastError: undefined });
    // Optimistically reflect the user message and streaming state.
    void this.refreshState();
    try {
      const response = await this.client.prompt(trimmed, {
        images: images.length > 0 ? images : undefined,
      });
      if (!response.success) {
        this.patch({ lastError: response.error });
        this.pushToast('error', response.error);
      } else if (response.data && typeof response.data.text === 'string') {
        this.patch({ lastTurnText: response.data.text });
      }
    } catch (err) {
      this.reportError(err);
    } finally {
      this.patch({ busy: false });
      await this.refreshAfterTurn();
    }
  }

  async steer(message: string): Promise<void> {
    const trimmed = message.trim();
    if (trimmed.length === 0) return;
    try {
      const response = await this.client.steer(trimmed);
      if (!response.success) this.pushToast('error', response.error);
      else this.pushToast('info', 'Steering message queued');
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async followUp(message: string): Promise<void> {
    const trimmed = message.trim();
    if (trimmed.length === 0) return;
    try {
      const response = await this.client.followUp(trimmed);
      if (!response.success) this.pushToast('error', response.error);
      else this.pushToast('info', 'Follow-up message queued');
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async abort(): Promise<void> {
    try {
      await this.client.abort();
      this.pushToast('info', 'Abort requested');
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async abortRetry(): Promise<void> {
    try {
      await this.client.abortRetry();
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async runBash(command: string): Promise<void> {
    const trimmed = command.trim();
    if (trimmed.length === 0) return;
    try {
      await this.client.runBash(trimmed);
      await this.refreshAfterTurn();
    } catch (err) {
      this.reportError(err);
    }
  }

  async abortBash(): Promise<void> {
    try {
      await this.client.abortBash();
      this.pushToast('info', 'Bash abort requested');
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async selectModel(model: Model): Promise<void> {
    try {
      await this.client.setModel(model.provider, model.id);
      await this.refreshState();
      this.pushToast('info', `Model set to ${model.provider}/${model.id}`);
    } catch (err) {
      this.reportError(err);
    }
  }

  async setThinkingLevel(level: ThinkingLevel): Promise<void> {
    try {
      await this.client.setThinkingLevel(level);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async setSteeringMode(mode: QueueModeValue): Promise<void> {
    try {
      await this.client.setSteeringMode(mode);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async setFollowUpMode(mode: QueueModeValue): Promise<void> {
    try {
      await this.client.setFollowUpMode(mode);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async setAutoCompaction(enabled: boolean): Promise<void> {
    try {
      await this.client.setAutoCompaction(enabled);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async setAutoRetry(enabled: boolean): Promise<void> {
    try {
      await this.client.setAutoRetry(enabled);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  async compact(customInstructions?: string): Promise<void> {
    try {
      await this.client.compact(customInstructions);
      this.pushToast('info', 'Compaction recorded');
      await this.refreshAfterTurn();
    } catch (err) {
      this.reportError(err);
    }
  }

  async exportHtml(): Promise<void> {
    try {
      const { path } = await this.client.exportHtml();
      this.pushToast('info', `Exported to ${path}`);
    } catch (err) {
      this.reportError(err);
    }
  }

  async newSession(): Promise<void> {
    try {
      await this.client.newSession();
      await this.bootstrap();
      this.pushToast('info', 'Started new session');
    } catch (err) {
      this.reportError(err);
    }
  }

  async setSessionName(name: string): Promise<void> {
    const trimmed = name.trim();
    if (trimmed.length === 0) return;
    try {
      await this.client.setSessionName(trimmed);
      await this.refreshState();
    } catch (err) {
      this.reportError(err);
    }
  }

  addAttachment(image: ImageContent): void {
    this.patch({ attachments: [...this.current.attachments, image] });
  }

  removeAttachment(index: number): void {
    this.patch({ attachments: this.current.attachments.filter((_, i) => i !== index) });
  }

  clearEvents(): void {
    this.patch({ events: [] });
  }

  private reportError(err: unknown): void {
    const message = err instanceof RpcError ? `${err.command}: ${err.message}` : err instanceof Error ? err.message : String(err);
    this.patch({ lastError: message });
    this.pushToast('error', message);
  }
}
