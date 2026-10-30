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

declare module '*.wasm?url' {
  const url: string;
  export default url;
}
