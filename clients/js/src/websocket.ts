import type { AsobiWebSocketOptions, WsMessage, WsEventType } from "./types.js";

type WsCallback = (payload: Record<string, unknown>) => void;
type CidResolver = {
  resolve: (payload: Record<string, unknown>) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

export class AsobiWebSocket {
  private readonly url: string;
  private readonly token: string;
  private readonly reconnect: boolean;
  private readonly reconnectInterval: number;
  private readonly maxReconnectAttempts: number;
  private readonly heartbeatInterval: number;

  private ws: WebSocket | null = null;
  private listeners = new Map<string, Set<WsCallback>>();
  private pendingReplies = new Map<string, CidResolver>();
  private cidCounter = 0;
  private reconnectAttempts = 0;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private closed = false;

  constructor(options: AsobiWebSocketOptions) {
    this.url = options.url;
    this.token = options.token;
    this.reconnect = options.reconnect ?? true;
    this.reconnectInterval = options.reconnectInterval ?? 3000;
    this.maxReconnectAttempts = options.maxReconnectAttempts ?? 10;
    this.heartbeatInterval = options.heartbeatInterval ?? 30000;
  }

  connect(): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      this.closed = false;
      this.ws = new WebSocket(this.url);

      this.ws.onopen = () => {
        this.reconnectAttempts = 0;
        this.startHeartbeat();
        this.send("session.connect", { token: this.token })
          .then(resolve)
          .catch(reject);
      };

      this.ws.onmessage = (event) => {
        this.handleMessage(event.data as string);
      };

      this.ws.onclose = () => {
        this.stopHeartbeat();
        this.emit("_close", {});
        if (this.reconnect && !this.closed && this.reconnectAttempts < this.maxReconnectAttempts) {
          this.reconnectAttempts++;
          setTimeout(() => this.connect(), this.reconnectInterval);
        }
      };

      this.ws.onerror = () => {
        this.emit("_error", {});
      };
    });
  }

  close(): void {
    this.closed = true;
    this.stopHeartbeat();
    this.ws?.close();
  }

  send(type: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const cid = String(++this.cidCounter);
      const msg: WsMessage = { type, payload, cid };

      const timer = setTimeout(() => {
        this.pendingReplies.delete(cid);
        reject(new Error(`Timeout waiting for reply to ${type} (cid: ${cid})`));
      }, 10000);

      this.pendingReplies.set(cid, { resolve, reject, timer });
      this.ws!.send(JSON.stringify(msg));
    });
  }

  sendFire(type: string, payload: Record<string, unknown> = {}): void {
    const msg: WsMessage = { type, payload };
    this.ws?.send(JSON.stringify(msg));
  }

  on(event: WsEventType | string, callback: WsCallback): () => void {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, new Set());
    }
    this.listeners.get(event)!.add(callback);
    return () => this.listeners.get(event)?.delete(callback);
  }

  off(event: string, callback: WsCallback): void {
    this.listeners.get(event)?.delete(callback);
  }

  private handleMessage(raw: string): void {
    let msg: WsMessage;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (msg.cid && this.pendingReplies.has(msg.cid)) {
      const pending = this.pendingReplies.get(msg.cid)!;
      this.pendingReplies.delete(msg.cid);
      clearTimeout(pending.timer);

      if (msg.type === "error") {
        pending.reject(new Error(String(msg.payload.reason ?? "unknown_error")));
      } else {
        pending.resolve(msg.payload);
      }
      return;
    }

    this.emit(msg.type, msg.payload);
  }

  private emit(event: string, payload: Record<string, unknown>): void {
    this.listeners.get(event)?.forEach((cb) => cb(payload));
    this.listeners.get("*")?.forEach((cb) => cb({ type: event, ...payload }));
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      this.sendFire("session.heartbeat");
    }, this.heartbeatInterval);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }
}
