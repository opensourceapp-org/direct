export function formatWhen(value: number): string {
  const date = new Date(value);
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

export function deliveryLabel(status: string, transport: string | null): string {
  if (status === 'pending' && transport === 'relay') return 'Pending · relay';
  if (status === 'pending') return 'Pending';
  if (status === 'delivered') return 'Delivered';
  if (status === 'read') return 'Read';
  if (status === 'expired') return 'Expired';
  if (status === 'failed') return 'Not sent';
  return status;
}
