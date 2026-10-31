export * from 'react-native-web';

import { View } from 'react-native-web';

export function codegenNativeComponent<T>(): T {
  return View as T;
}

export const TurboModuleRegistry = {
  get: () => null,
  getEnforcing: () => ({}),
};
