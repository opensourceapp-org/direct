declare module 'sql.js';

declare module 'react-native-web' {
  import type { ComponentType } from 'react';
  export const View: ComponentType<Record<string, unknown>>;
}

declare module 'react-dom/client' {
  import type { ReactNode } from 'react';
  export interface Root {
    render(children: ReactNode): void;
    unmount(): void;
  }
  export function createRoot(container: Element): Root;
}

declare module 'ws' {
  import type { IncomingMessage } from 'node:http';
  import type { Duplex } from 'node:stream';
  export class WebSocketServer {
    constructor(options: { noServer: true } | { server: unknown });
    handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer, callback: (socket: {
      readyState: number;
      send(data: string): void;
      ping(): void;
      on(event: 'message', listener: (raw: unknown) => void): void;
      on(event: 'close', listener: () => void): void;
    }) => void): void;
    close(): void;
    on(event: 'connection', listener: (socket: {
      readyState: number;
      send(data: string): void;
      ping(): void;
      on(event: 'message', listener: (raw: unknown) => void): void;
      on(event: 'close', listener: () => void): void;
    }) => void): void;
  }
}

declare module '*.wasm?url' {
  const url: string;
  export default url;
}
