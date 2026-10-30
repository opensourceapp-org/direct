import '@fontsource/geist-sans/400.css';
import '@fontsource/geist-sans/500.css';
import '@fontsource/geist-sans/600.css';
import { AppRegistry } from 'react-native';
import wasmUrl from 'sql.js/dist/sql-wasm.wasm?url';
import { App } from './src/app/App';

const root = document.getElementById('root');

async function start() {
  const wasmBinary = new Uint8Array(await (await fetch(wasmUrl)).arrayBuffer());
  AppRegistry.registerComponent('DIRECT', () => () => <App wasmBinary={wasmBinary} />);
  AppRegistry.runApplication('DIRECT', { rootTag: root });
}

void start();
