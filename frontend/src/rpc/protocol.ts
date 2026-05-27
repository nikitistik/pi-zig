/**
 * Typed RPC protocol contract for the pi-zig backend.
 *
 * This mirrors the upstream contract in
 * `upstream/pi/packages/coding-agent/src/modes/rpc/rpc-types.ts`
 * and the concrete wire format emitted by the Zig runtime in
 * `src/pi/rpc.zig` (handleValue dispatch + writeResponseHead/writeError +
 * the writeRpc*Event status emitters).
 *
 * Commands are written as JSON lines on the backend's stdin.
 * Responses (`type:"response"`) and unsolicited events are read as JSON lines
 * from the backend's stdout. Responses correlate to a command by the optional
 * `id` field; events have no `id` and arrive at any time while a prompt runs.
 */

export type ThinkingLevel = 'off' | 'low' | 'medium' | 'high' | 'max';
export type QueueModeValue = 'all' | 'one-at-a-time';
export type StreamingBehavior = 'steer' | 'followUp';

/** Image attachment payload (matches `parseRpcImages` in src/pi/rpc.zig). */
export interface ImageContent {
  type: 'image';
  /** base64-encoded image bytes (no data: prefix). */
  data: string;
  /** e.g. "image/png". */
  mimeType: string;
}

/** Model record as emitted by `models.writeModelJson` in src/pi/models.zig. */
export interface Model {
  id: string;
  name: string;
  api: string;
  provider: string;
  baseUrl: string;
  reasoning: boolean;
  input: Array<'text' | 'image'>;
  cost: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  };
  contextWindow: number;
  maxTokens: number;
  supportedThinkingLevels: ThinkingLevel[];
}

/** A tool call attached to an assistant message (src/pi/rpc.zig writeStoredMessage). */
export interface ToolCall {
  id: string;
  name: string;
  argumentsJson: string;
  thoughtSignature?: string;
}

/** One transcript message returned by `get_messages`. */
export interface AgentMessage {
  role:
    | 'system'
    | 'user'
    | 'assistant'
    | 'tool'
    | 'bashExecution'
    | 'compactionSummary'
    | 'custom';
  content?: string;
  images?: ImageContent[];
  // assistant
  toolCalls?: ToolCall[];
  stopReason?: string;
  errorMessage?: string;
  // tool result
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
  terminate?: boolean;
  // bash execution
  command?: string;
  output?: string;
  exitCode?: number | null;
  cancelled?: boolean;
  truncated?: boolean;
  fullOutputPath?: string;
  // compaction summary
  summary?: string;
  tokensBefore?: number;
  firstKeptEntryId?: string;
  // custom message
  customType?: string;
  display?: boolean;
}

/** Session state from `get_state` (src/pi/rpc.zig writeState). */
export interface SessionState {
  model: Model | null;
  thinkingLevel: ThinkingLevel;
  isStreaming: boolean;
  isRetrying: boolean;
  isBashRunning: boolean;
  isCompacting: boolean;
  steeringMode: QueueModeValue;
  followUpMode: QueueModeValue;
  sessionId: string;
  sessionFile: string;
  sessionName?: string;
  autoCompactionEnabled: boolean;
  autoRetryEnabled: boolean;
  autoRetryMaxAttempts: number;
  autoRetryBaseDelayMs: number;
  autoRetryMaxDelayMs: number;
  lastRetryAttempts: number;
  lastRetryDelayMs: number;
  messageCount: number;
  pendingMessageCount: number;
  pendingSteeringCount: number;
  pendingFollowUpCount: number;
}

/** A slash command from `get_commands` (src/pi/commands.zig). */
export interface SlashCommand {
  name: string;
  description?: string;
  source: 'extension' | 'prompt' | 'skill';
  sourceInfo?: unknown;
}

export interface SessionStats {
  sessionFile: string;
  sessionId: string;
  userMessages: number;
  assistantMessages: number;
  toolCalls: number;
  toolResults: number;
  totalMessages: number;
  tokens: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    total: number;
  };
  cost: number;
}

export interface BashResult {
  output: string;
  exitCode: number | null;
  cancelled: boolean;
  truncated: boolean;
  fullOutputPath?: string;
}

export interface PromptResultData {
  text: string;
  toolResults: unknown[];
  retry: { attempts: number; totalDelayMs: number; maxAttempts: number };
  model?: Model;
}

// ---------------------------------------------------------------------------
// Commands (stdin)
// ---------------------------------------------------------------------------

export type RpcCommand =
  | { id?: string; type: 'prompt'; message: string; images?: ImageContent[]; streamingBehavior?: StreamingBehavior }
  | { id?: string; type: 'steer'; message: string; images?: ImageContent[] }
  | { id?: string; type: 'follow_up'; message: string; images?: ImageContent[] }
  | { id?: string; type: 'abort' }
  | { id?: string; type: 'new_session'; parentSession?: string }
  | { id?: string; type: 'get_state' }
  | { id?: string; type: 'get_messages' }
  | { id?: string; type: 'set_model'; provider: string; modelId: string }
  | { id?: string; type: 'cycle_model' }
  | { id?: string; type: 'get_available_models' }
  | { id?: string; type: 'set_thinking_level'; level: ThinkingLevel }
  | { id?: string; type: 'cycle_thinking_level' }
  | { id?: string; type: 'set_steering_mode'; mode: QueueModeValue }
  | { id?: string; type: 'set_follow_up_mode'; mode: QueueModeValue }
  | { id?: string; type: 'compact'; customInstructions?: string }
  | { id?: string; type: 'set_auto_compaction'; enabled: boolean }
  | { id?: string; type: 'set_auto_retry'; enabled: boolean; maxRetries?: number; baseDelayMs?: number; maxDelayMs?: number }
  | { id?: string; type: 'abort_retry' }
  | { id?: string; type: 'bash'; command: string; timeout?: number }
  | { id?: string; type: 'abort_bash' }
  | { id?: string; type: 'get_session_stats' }
  | { id?: string; type: 'export_html'; outputPath?: string }
  | { id?: string; type: 'switch_session'; sessionPath: string }
  | { id?: string; type: 'fork'; entryId: string }
  | { id?: string; type: 'clone' }
  | { id?: string; type: 'get_fork_messages' }
  | { id?: string; type: 'get_last_assistant_text' }
  | { id?: string; type: 'set_session_name'; name: string }
  | { id?: string; type: 'get_commands' };

export type RpcCommandType = RpcCommand['type'];

// ---------------------------------------------------------------------------
// Responses (stdout) — correlated by `id`
// ---------------------------------------------------------------------------

export interface RpcResponseBase {
  type: 'response';
  command: string;
  id?: string;
}

export interface RpcSuccessResponse<TData = unknown> extends RpcResponseBase {
  success: true;
  data?: TData;
}

export interface RpcErrorResponse extends RpcResponseBase {
  success: false;
  error: string;
}

export type RpcResponse<TData = unknown> = RpcSuccessResponse<TData> | RpcErrorResponse;

// ---------------------------------------------------------------------------
// Events (stdout) — unsolicited, no `id`
// ---------------------------------------------------------------------------

/**
 * Status/lifecycle events emitted by the Zig runtime during a prompt run.
 * The runtime emits message_start/message_end/turn_end/agent_end on
 * error/abort status, and auto_retry_start/auto_retry_end during retries.
 * Future provider streaming may emit additional event shapes; the client
 * forwards every non-response line as a generic event.
 */
export interface RpcEvent {
  type: string;
  [key: string]: unknown;
}

export function isRpcResponse(value: unknown): value is RpcResponse {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as { type?: unknown }).type === 'response'
  );
}

export function isRpcEvent(value: unknown): value is RpcEvent {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { type?: unknown }).type === 'string' &&
    (value as { type?: unknown }).type !== 'response'
  );
}
