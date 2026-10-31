/**
 * @jest-environment jsdom
 */
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { Button } from './system';
import { ThemeProvider } from '../../theme/ThemeProvider';

test('primary button calls its action', () => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement('div');
  document.body.appendChild(host);
  const root: Root = createRoot(host);
  const onPress = jest.fn();
  act(() => {
    root.render(
      <ThemeProvider>
        <Button label="Create identity" onPress={onPress} />
      </ThemeProvider>,
    );
  });
  const button = host.querySelector('button');
  expect(button?.textContent).toContain('Create identity');
  act(() => {
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  expect(onPress).toHaveBeenCalledTimes(1);
  act(() => root.unmount());
});
