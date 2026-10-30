import { createContext, useContext } from 'react';
import type { DirectController } from './controller';

export const DirectContext = createContext<DirectController | null>(null);

export function useDirect(): DirectController {
  const value = useContext(DirectContext);
  if (!value) throw new Error('DIRECT is still starting.');
  return value;
}
