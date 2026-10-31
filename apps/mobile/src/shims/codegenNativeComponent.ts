import { View } from 'react-native-web';

export default function codegenNativeComponent<T>(): T {
  return View as T;
}
