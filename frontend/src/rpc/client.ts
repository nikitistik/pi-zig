/**
 * Typed RPC client for the pi-zig backend.
 *
 * Wraps a line Transport: writes commands as JSON lines (assigning a unique
 * `id`) and resolves the matching `response` line. Unsolicited `event` lines
 * (message_start/turn_end/agent_end/auto_retry_* and any future streaming
 * deltas) are delivered to event subscribers.
 *
 * Mirrors the request/response contract in
 * upstream/pi/packages/coding-agent/src/modes/rpc/rpc-types.ts and the wire
 * format in src/pi/rpc.zig.
 */

import {
  isRpcEvent,
  isRpcResponse,
  type AgentMessage,
  type BashResult,
  type ImageContent,
  type Model,
  type PromptResultData,
  type QueueModeValue,
  type RpcCommand,
  type RpcEvent,
  type RpcResponse,
  type SessionState,
  type SessionStats,
  type SlashCommand,
  type StreamingBehavior,
  type ThinkingLevel,
} from './protocol';
import type { Transport, TransportStatus } from './transport';

export class RpcError extends Error {
  constructor(public command: string, message: string) {
    super(message);
    this.name = 'RpcError';
  }
}

interface Pending {
  resolve: (response: RpcResponse) => void;
  reject: (err: Error) => void;
  command: string;
  timer: ReturnType<typeof setTimeout>;
}

export type EventHandler = (event: RpcEvent) => void;
export type StatusHandler = (status: TransportStatus, detail?: string) => void;

const DEFAULT_TIMEOUT_MS = 600_000;

export class RpcClient {
  private pending = new Map<string, Pending>();
  private eventHandlers = new Set<EventHandler>();
  private rawHandlers = new Set<(line: unknown) => void>();
  private seq = 0;

  constructor(private transport: Transport) {
    transport.onMessage((line) => this.handleLine(line));
    // If the connection drops, settle every in-flight request so awaiting
    // callers (e.g. a pending prompt) don't hang forever.
    transport.onStatus((status) => {
      if (status === 'closed' || status === 'error') this.rejectAllPending('connection lost');
    });
  }

  private rejectAllPending(reason: string): void {
    for (const [, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new RpcError(pending.command, reason));
    }
    this.pending.clear();
  }

  onEvent(handler: EventHandler): () => void {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  /** Observe every parsed inbound object (responses and events). */
  onRaw(handler: (value: unknown) => void): () => void {
    this.rawHandlers.add(handler);
    return () => this.rawHandlers.delete(handler);
  }

  onStatus(handler: StatusHandler): void {
    this.transport.onStatus(handler);
  }

  status(): TransportStatus {
    return this.transport.status();
  }

  private handleLine(line: string): void {
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      return;
    }
    for (const handler of this.rawHandlers) handler(value);

    if (isRpcResponse(value)) {
      const id = value.id;
      if (id && this.pending.has(id)) {
        const pending = this.pending.get(id)!;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        pending.resolve(value);
        return;
      }
      // Response without a tracked id (e.g. async prompt completion routed by
      // command): surface it as an event so the store can react.
      const asEvent = { ...(value as unknown as Record<string, unknown>), type: 'response' } as RpcEvent;
      for (const handler of this.eventHandlers) handler(asEvent);
      return;
    }

    if (isRpcEvent(value)) {
      for (const handler of this.eventHandlers) handler(value);
    }
  }

  /** Send a command and await its correlated response. */
  request<TData = unknown>(
    command: RpcCommand,
    options: { timeoutMs?: number } = {},
  ): Promise<RpcResponse<TData>> {
    const id = command.id ?? `c-${++this.seq}-${Date.now().toString(36)}`;
    const payload = { ...command, id };
    return new Promise<RpcResponse<TData>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new RpcError(command.type, `timed out after ${options.timeoutMs ?? DEFAULT_TIMEOUT_MS}ms`));
      }, options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: resolve as (response: RpcResponse) => void,
        reject,
        command: command.type,
        timer,
      });
      this.transport.send(JSON.stringify(payload));
    });
  }

  /** Send a command and unwrap data, throwing RpcError on failure. */
  async call<TData = unknown>(command: RpcCommand, options?: { timeoutMs?: number }): Promise<TData> {
    const response = await this.request<TData>(command, options);
    if (!response.success) {
      throw new RpcError(response.command, response.error);
    }
    return response.data as TData;
  }

  // --- Typed convenience wrappers --------------------------------------------

  getState(): Promise<SessionState> {
    return this.call<SessionState>({ type: 'get_state' });
  }

  getMessages(): Promise<{ messages: AgentMessage[] }> {
    return this.call<{ messages: AgentMessage[] }>({ type: 'get_messages' });
  }

  getAvailableModels(): Promise<{ models: Model[] }> {
    return this.call<{ models: Model[] }>({ type: 'get_available_models' });
  }

  getCommands(): Promise<{ commands: SlashCommand[] }> {
    return this.call<{ commands: SlashCommand[] }>({ type: 'get_commands' });
  }

  getSessionStats(): Promise<SessionStats> {
    return this.call<SessionStats>({ type: 'get_session_stats' });
  }

  setModel(provider: string, modelId: string): Promise<Model> {
    return this.call<Model>({ type: 'set_model', provider, modelId });
  }

  setThinkingLevel(level: ThinkingLevel): Promise<void> {
    return this.call<void>({ type: 'set_thinking_level', level });
  }

  setSteeringMode(mode: QueueModeValue): Promise<void> {
    return this.call<void>({ type: 'set_steering_mode', mode });
  }

  setFollowUpMode(mode: QueueModeValue): Promise<void> {
    return this.call<void>({ type: 'set_follow_up_mode', mode });
  }

  setAutoCompaction(enabled: boolean): Promise<void> {
    return this.call<void>({ type: 'set_auto_compaction', enabled });
  }

  setAutoRetry(enabled: boolean): Promise<void> {
    return this.call<void>({ type: 'set_auto_retry', enabled });
  }

  /**
   * Send a prompt. The backend acknowledges asynchronously: it returns a
   * `prompt` response either immediately (success with no data when no model
   * is configured) or after the agent run completes (with data.text). Status
   * events stream in between. Callers should not block on this — instead drive
   * the UI from events + a follow-up get_state/get_messages.
   */
  prompt(
    message: string,
    options: { images?: ImageContent[]; streamingBehavior?: StreamingBehavior } = {},
  ): Promise<RpcResponse<PromptResultData>> {
    return this.request<PromptResultData>({
      type: 'prompt',
      message,
      images: options.images,
      streamingBehavior: options.streamingBehavior,
    });
  }

  steer(message: string, images?: ImageContent[]): Promise<RpcResponse> {
    return this.request({ type: 'steer', message, images });
  }

  followUp(message: string, images?: ImageContent[]): Promise<RpcResponse> {
    return this.request({ type: 'follow_up', message, images });
  }

  abort(): Promise<void> {
    return this.call<void>({ type: 'abort' });
  }

  abortRetry(): Promise<void> {
    return this.call<void>({ type: 'abort_retry' });
  }

  runBash(command: string, timeout?: number): Promise<BashResult> {
    return this.call<BashResult>({ type: 'bash', command, timeout });
  }

  abortBash(): Promise<void> {
    return this.call<void>({ type: 'abort_bash' });
  }

  compact(customInstructions?: string): Promise<unknown> {
    return this.call({ type: 'compact', customInstructions });
  }

  exportHtml(outputPath?: string): Promise<{ path: string }> {
    return this.call<{ path: string }>({ type: 'export_html', outputPath });
  }

  newSession(parentSession?: string): Promise<{ cancelled: boolean }> {
    return this.call<{ cancelled: boolean }>({ type: 'new_session', parentSession });
  }

  switchSession(sessionPath: string): Promise<{ cancelled: boolean }> {
    return this.call<{ cancelled: boolean }>({ type: 'switch_session', sessionPath });
  }

  setSessionName(name: string): Promise<void> {
    return this.call<void>({ type: 'set_session_name', name });
  }
}
