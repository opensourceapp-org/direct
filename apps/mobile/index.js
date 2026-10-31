import 'react-native-gesture-handler';
import 'react-native-reanimated';
import React from 'react';
import { AppRegistry } from 'react-native';
import { App } from './src/app/App';

function Root() {
  return React.createElement(App, {});
}

AppRegistry.registerComponent('DIRECT', () => Root);
