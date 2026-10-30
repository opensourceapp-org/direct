import { useMemo } from 'react';
import QRCode from 'qrcode';
import { useTheme } from '../theme/ThemeProvider';

export function QrCode({ value, size = 168 }: { value: string; size?: number }) {
  const theme = useTheme();
  const cells = useMemo(() => {
    const code = QRCode.create(value, { errorCorrectionLevel: 'M' });
    const rects: { x: number; y: number }[] = [];
    for (let y = 0; y < code.modules.size; y += 1) {
      for (let x = 0; x < code.modules.size; x += 1) {
        if (code.modules.get(x, y)) rects.push({ x, y });
      }
    }
    return { size: code.modules.size, rects };
  }, [value]);
  return (
    <svg width={size} height={size} viewBox={`0 0 ${cells.size} ${cells.size}`} shapeRendering="crispEdges" role="img" aria-label="Identity QR code">
      <rect width={cells.size} height={cells.size} fill={theme.background} />
      {cells.rects.map((cell) => (
        <rect key={`${cell.x}:${cell.y}`} x={cell.x} y={cell.y} width={1} height={1} fill={theme.foreground} />
      ))}
    </svg>
  );
}
