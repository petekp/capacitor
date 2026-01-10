import type { EncryptedMessage, WebSocketMessage } from './types';

export class HudSession implements DurableObject {
  private connections: Set<WebSocket> = new Set();
  private lastState: EncryptedMessage | null = null;

  constructor(
    private state: DurableObjectState,
    _env: unknown
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/ws') {
      return this.handleWebSocket(request);
    }

    if (url.pathname === '/state' && request.method === 'POST') {
      return this.handleStateUpdate(request);
    }

    if (url.pathname === '/state' && request.method === 'GET') {
      return this.handleGetState();
    }

    return new Response('Not Found', { status: 404 });
  }

  private handleWebSocket(request: Request): Response {
    const upgradeHeader = request.headers.get('Upgrade');
    if (upgradeHeader !== 'websocket') {
      return new Response('Expected WebSocket', { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.state.acceptWebSocket(server);
    this.connections.add(server);

    if (this.lastState) {
      const msg: WebSocketMessage = { type: 'state', data: this.lastState };
      server.send(JSON.stringify(msg));
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleStateUpdate(request: Request): Promise<Response> {
    try {
      const message = (await request.json()) as EncryptedMessage;

      if (!message.nonce || !message.ciphertext) {
        return new Response('Invalid message format', { status: 400 });
      }

      this.lastState = message;
      await this.state.storage.put('lastState', message);

      this.broadcast({ type: 'state', data: message });

      return new Response('OK', {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      });
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }
  }

  private handleGetState(): Response {
    if (!this.lastState) {
      return new Response('No state available', { status: 404 });
    }

    return new Response(JSON.stringify(this.lastState), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  private broadcast(message: WebSocketMessage): void {
    const json = JSON.stringify(message);
    const deadConnections: WebSocket[] = [];

    for (const ws of this.connections) {
      try {
        ws.send(json);
      } catch {
        deadConnections.push(ws);
      }
    }

    for (const ws of deadConnections) {
      this.connections.delete(ws);
    }
  }

  async webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      const data = JSON.parse(message as string) as WebSocketMessage;

      if (data.type === 'pong') {
        return;
      }

      if (data.type === 'command' && data.data) {
        this.broadcast({ type: 'command', data: data.data });
      }
    } catch {
      // Ignore malformed messages
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.connections.delete(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.connections.delete(ws);
  }

  async alarm(): Promise<void> {
    const pingMsg: WebSocketMessage = { type: 'ping' };
    this.broadcast(pingMsg);
    await this.state.storage.setAlarm(Date.now() + 30000);
  }
}
