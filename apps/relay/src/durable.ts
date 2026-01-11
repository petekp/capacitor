import type { EncryptedMessage, WebSocketMessage, HeartbeatData } from './types';

export class HudSession implements DurableObject {
  private lastState: EncryptedMessage | null = null;
  private initialized = false;

  constructor(
    private state: DurableObjectState,
    _env: unknown
  ) {}

  private async ensureInitialized(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;

    const stored = await this.state.storage.get<EncryptedMessage>('lastState');
    if (stored) {
      this.lastState = stored;
    }

    // Ensure ping alarm is running
    const currentAlarm = await this.state.storage.getAlarm();
    if (currentAlarm === null) {
      await this.state.storage.setAlarm(Date.now() + 30000);
    }
  }

  async fetch(request: Request): Promise<Response> {
    await this.ensureInitialized();
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

    if (url.pathname === '/heartbeat' && request.method === 'POST') {
      return this.handleHeartbeat(request);
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

    // acceptWebSocket enables hibernation - WebSocket is tracked by the runtime
    this.state.acceptWebSocket(server);

    // Send hello on connect
    const helloMsg: WebSocketMessage = { type: 'hello' };
    server.send(JSON.stringify(helloMsg));

    // Send current state if available
    if (this.lastState) {
      const stateMsg: WebSocketMessage = { type: 'state_update', state: this.lastState };
      server.send(JSON.stringify(stateMsg));
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

      this.broadcast({ type: 'state_update', state: message });

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

  private async handleHeartbeat(request: Request): Promise<Response> {
    try {
      const heartbeat = (await request.json()) as HeartbeatData;

      if (!heartbeat.project || !heartbeat.timestamp) {
        return new Response('Invalid heartbeat format', { status: 400 });
      }

      this.broadcast({ type: 'heartbeat', heartbeat });

      return new Response('OK', { status: 200 });
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }
  }

  private broadcast(message: WebSocketMessage): void {
    const json = JSON.stringify(message);
    // getWebSockets() returns all WebSockets accepted via acceptWebSocket()
    // This persists across hibernation, unlike an in-memory Set
    const webSockets = this.state.getWebSockets();

    for (const ws of webSockets) {
      try {
        ws.send(json);
      } catch {
        // WebSocket will be cleaned up automatically by the runtime
      }
    }
  }

  async webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      const msg = JSON.parse(message as string) as WebSocketMessage;

      if (msg.type === 'pong') {
        return;
      }

      // Future: handle command messages for bidirectional control
    } catch {
      // Ignore malformed messages
    }
  }

  async webSocketClose(_ws: WebSocket): Promise<void> {
    // WebSocket is automatically removed from getWebSockets() by the runtime
  }

  async webSocketError(_ws: WebSocket): Promise<void> {
    // WebSocket is automatically removed from getWebSockets() by the runtime
  }

  async alarm(): Promise<void> {
    const pingMsg: WebSocketMessage = { type: 'ping' };
    this.broadcast(pingMsg);
    await this.state.storage.setAlarm(Date.now() + 30000);
  }
}
