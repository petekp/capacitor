export interface ProjectState {
  state: 'working' | 'ready' | 'idle' | 'compacting' | 'waiting';
  workingOn?: string;
  nextStep?: string;
  devServerPort?: number;
  contextPercent?: number;
  lastUpdated: string;
}

export interface HudState {
  projects: Record<string, ProjectState>;
  activeProject?: string;
  updatedAt: string;
}

export interface EncryptedMessage {
  nonce: string;
  ciphertext: string;
}

export interface WebSocketMessage {
  type: 'state_update' | 'hello' | 'ping' | 'pong' | 'command' | 'heartbeat';
  state?: EncryptedMessage;
  deviceId?: string;
  heartbeat?: HeartbeatData;
}

export interface HeartbeatData {
  project: string;
  timestamp: string;
}

export interface Env {
  HUD_SESSION: DurableObjectNamespace;
}
