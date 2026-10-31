import Svg, { Circle, Path, Rect } from 'react-native-svg';

export type IconName = 'plus' | 'search' | 'back' | 'close' | 'send' | 'paperclip' | 'chat' | 'contacts' | 'network' | 'settings' | 'shield' | 'device';

export function Icon({ name, color, size = 18 }: { name: IconName; color: string; size?: number }) {
  const common = { stroke: color, strokeWidth: 1.5, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const, fill: 'none' };
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      {name === 'plus' ? <Path d="M12 5v14M5 12h14" {...common} /> : null}
      {name === 'search' ? (
        <>
          <Circle cx="11" cy="11" r="6" {...common} />
          <Path d="M16 16l4 4" {...common} />
        </>
      ) : null}
      {name === 'back' ? <Path d="M15 6l-6 6 6 6" {...common} /> : null}
      {name === 'close' ? <Path d="M6 6l12 12M18 6L6 18" {...common} /> : null}
      {name === 'send' ? <Path d="M5 12h14M13 6l6 6-6 6" {...common} /> : null}
      {name === 'paperclip' ? <Path d="M8 12.5l6.2-6.2a3 3 0 114.2 4.2l-7.4 7.5a4.2 4.2 0 01-6-6L12 5" {...common} /> : null}
      {name === 'chat' ? <Path d="M5 6.5h14v9H8l-3 2.5v-11.5z" {...common} /> : null}
      {name === 'contacts' ? (
        <>
          <Circle cx="9" cy="9" r="3" {...common} />
          <Circle cx="16" cy="10" r="2.2" {...common} />
          <Path d="M4.5 18c.6-2.4 2.4-3.5 4.5-3.5s3.9 1.1 4.5 3.5M14 14.6c1.2-.4 2.4-.3 3.4.4 1 .8 1.5 1.8 1.8 3" {...common} />
        </>
      ) : null}
      {name === 'network' ? (
        <>
          <Circle cx="6" cy="12" r="2" {...common} />
          <Circle cx="18" cy="7" r="2" {...common} />
          <Circle cx="18" cy="17" r="2" {...common} />
          <Path d="M8 12h8M16.2 8.4l-3.2 2.4M16.2 15.6l-3.2-2.4" {...common} />
        </>
      ) : null}
      {name === 'settings' ? (
        <>
          <Circle cx="12" cy="12" r="3" {...common} />
          <Path d="M12 4.5v2M12 17.5v2M4.5 12h2M17.5 12h2M6.4 6.4l1.4 1.4M16.2 16.2l1.4 1.4M17.6 6.4l-1.4 1.4M7.8 16.2l-1.4 1.4" {...common} />
        </>
      ) : null}
      {name === 'shield' ? <Path d="M12 3.5l7 2.5v6.2c0 4-2.8 6.6-7 8.3-4.2-1.7-7-4.3-7-8.3V6l7-2.5z" {...common} /> : null}
      {name === 'device' ? <Rect x="7" y="3.5" width="10" height="17" rx="2" {...common} /> : null}
    </Svg>
  );
}
