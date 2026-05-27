/**
 * Line-oriented transport between the browser workbench and the bridge server
 * (`frontend/server.mjs`), which in turn spawns the real
 * `pi-zig --mode rpc --session <file>` process and pipes its stdio.
 *
 * The browser cannot spawn processes, so a WebSocket carries newline-delimited
 * JSON in both directions:
 *   - browser -> server: one RPC command object per message (no trailing \n).
 *   - server -> browser: one backend stdout JSON object per message.
 */

export type TransportStatus = 'connecting' | 'open' | 'closed' | 'error';

export interface Transport {
  send(line: string): void;
  onMessage(handler: (line: string) => void): void;
  onStatus(handler: (status: TransportStatus, detail?: string) => void): void;
  status(): TransportStatus;
  close(): void;
}

/** Resolve the bridge WebSocket URL from the current page location. */
export function defaultBridgeUrl(): string {
  if (typeof window === 'undefined') return 'ws://127.0.0.1:8787/rpc';
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  // The Vite dev server proxies /rpc to the bridge; in preview/standalone the
  // bridge serves the page directly, so same-origin works in both cases.
  return `${proto}//${window.location.host}/rpc`;
}

export class WebSocketTransport implements Transport {
  private socket: WebSocket | null = null;
  private messageHandlers: Array<(line: string) => void> = [];
  private statusHandlers: Array<(status: TransportStatus, detail?: string) => void> = [];
  private currentStatus: TransportStatus = 'connecting';
  private url: string;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private closedByUser = false;

  constructor(url: string = defaultBridgeUrl()) {
    this.url = url;
    this.connect();
  }

  private connect(): void {
    this.setStatus('connecting');
    let socket: WebSocket;
    try {
      socket = new WebSocket(this.url);
    } catch (err) {
      this.setStatus('error', err instanceof Error ? err.message : String(err));
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;

    socket.addEventListener('open', () => this.setStatus('open'));
    socket.addEventListener('message', (event) => {
      const data = typeof event.data === 'string' ? event.data : '';
      for (const line of data.split('\n')) {
        const trimmed = line.trim();
        if (trimmed.length === 0) continue;
        for (const handler of this.messageHandlers) handler(trimmed);
      }
    });
    socket.addEventListener('error', () => {
      this.setStatus('error', 'WebSocket error');
    });
    socket.addEventListener('close', () => {
      this.setStatus('closed');
      if (!this.closedByUser) this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    if (this.closedByUser || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 1200);
  }

  private setStatus(status: TransportStatus, detail?: string): void {
    this.currentStatus = status;
    for (const handler of this.statusHandlers) handler(status, detail);
  }

  send(line: string): void {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(line);
    }
  }

  onMessage(handler: (line: string) => void): void {
    this.messageHandlers.push(handler);
  }

  onStatus(handler: (status: TransportStatus, detail?: string) => void): void {
    this.statusHandlers.push(handler);
    handler(this.currentStatus);
  }

  status(): TransportStatus {
    return this.currentStatus;
  }

  close(): void {
    this.closedByUser = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.socket?.close();
  }
}
