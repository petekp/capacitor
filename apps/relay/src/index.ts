import type { Env } from './types';

export { HudSession } from './durable';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/health') {
      return new Response('OK', { status: 200 });
    }

    const match = url.pathname.match(/^\/api\/v1\/(state|ws)\/([a-zA-Z0-9-]+)$/);
    if (!match) {
      return new Response('Not Found', { status: 404 });
    }

    const [, action, deviceId] = match;

    const id = env.HUD_SESSION.idFromName(deviceId);
    const stub = env.HUD_SESSION.get(id);

    const internalUrl = new URL(request.url);
    internalUrl.pathname = action === 'ws' ? '/ws' : '/state';

    return stub.fetch(new Request(internalUrl.toString(), request));
  },
};
