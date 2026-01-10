# HUD Relay Architecture

A minimal, low-latency relay for syncing Claude HUD state between desktop and mobile.

## Design Goals

1. **Sub-100ms latency** for state updates
2. **Bidirectional** - mobile can send commands back to desktop
3. **Secure** - E2E encryption, zero-knowledge relay
4. **Simple** - only sync HUD state, not full terminal output
5. **Cheap** - leverage Cloudflare's free/cheap tier

## Architecture Overview

```
┌─────────────────┐                      ┌─────────────────┐
│  Desktop        │                      │  Mobile         │
│  ┌───────────┐  │                      │  ┌───────────┐  │
│  │ Claude    │  │                      │  │ HUD App   │  │
│  │ Code Hook │──┼──┐              ┌────┼──│ (Swift)   │  │
│  └───────────┘  │  │              │    │  └───────────┘  │
│                 │  │              │    │                 │
│  ┌───────────┐  │  │   WebSocket  │    │                 │
│  │ HUD       │  │  │   ┌──────┐   │    │                 │
│  │ Desktop   │──┼──┼───│Relay │───┼────┤                 │
│  │ (Swift)   │  │  │   └──────┘   │    │                 │
│  └───────────┘  │  │              │    │                 │
└─────────────────┘  │              │    └─────────────────┘
                     │              │
                     └──────────────┘
                     Cloudflare Edge
```

## Components

### 1. Relay Server (Cloudflare Worker + Durable Object)

- **Worker**: Routes requests, handles WebSocket upgrades
- **Durable Object**: Per-user state, WebSocket connections, message relay

### 2. Desktop Publisher (Claude Code Hook)

- Runs on `Stop`, `PostToolUse` events
- Publishes state to relay via HTTP POST
- Encrypted before leaving device

### 3. Mobile Subscriber (Swift WebSocket Client)

- Maintains WebSocket connection to relay
- Receives real-time state updates
- Can send commands back (future)

## Data Model

### State Payload (what gets synced)

```typescript
interface HudState {
  // Per-project state
  projects: {
    [projectPath: string]: {
      state: 'working' | 'ready' | 'idle' | 'compacting' | 'waiting';
      workingOn?: string;
      nextStep?: string;
      devServerPort?: number;
      contextPercent?: number;
      lastUpdated: string; // ISO timestamp
    };
  };

  // Global state
  activeProject?: string;
  updatedAt: string;
}
```

### Encrypted Message Format

```typescript
interface EncryptedMessage {
  nonce: string;      // 24 bytes, base64
  ciphertext: string; // encrypted HudState, base64
}
```

## Security Model

### Pairing Flow

1. Desktop generates keypair, displays QR code containing:
   - Relay URL
   - Device ID (random UUID)
   - Public key

2. Mobile scans QR, generates own keypair

3. Both derive shared secret via X25519 key exchange

4. All subsequent messages encrypted with XChaCha20-Poly1305

### Zero-Knowledge Relay

- Relay only sees encrypted blobs
- Device ID is random, not tied to identity
- No authentication required (possession of key = authorization)

## API Design

### HTTP Endpoints (Worker)

```
POST /api/v1/state/:deviceId
  Body: EncryptedMessage
  -> Broadcasts to connected WebSocket clients

GET /api/v1/ws/:deviceId
  -> Upgrades to WebSocket connection
```

### WebSocket Messages

```typescript
// Server -> Client
{ type: 'state', data: EncryptedMessage }
{ type: 'ping' }

// Client -> Server
{ type: 'command', data: EncryptedMessage } // Future: send commands
{ type: 'pong' }
```

## File Structure

```
apps/relay/
├── ARCHITECTURE.md      # This file
├── wrangler.toml        # Cloudflare config
├── package.json
├── src/
│   ├── index.ts         # Worker entry point
│   ├── durable.ts       # Durable Object class
│   └── types.ts         # Shared types
└── test/
    └── relay.test.ts
```

## Deployment

```bash
cd apps/relay
npm install
npx wrangler deploy
```

## Cost Estimate

At Cloudflare's pricing (as of 2025):
- **Workers**: 10M requests/month free, then $0.30/million
- **Durable Objects**:
  - Requests: $0.15/million after 1M free
  - Duration: $12.50/million GB-seconds after 400K free
  - Storage: $0.20/GB after 1GB free

For a single user with ~1000 state updates/day:
- ~30K requests/month → **Free tier**
- Minimal storage (latest state only) → **Free tier**

## Future Enhancements

1. **Commands from mobile** - Send prompts, approve tool use
2. **Multiple devices** - Sync between phone, tablet, watch
3. **Offline queue** - Buffer updates when mobile is offline
4. **Smart notifications** - Only push when state = ready
