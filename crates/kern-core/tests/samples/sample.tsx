// A counter component
type Props = { start: number };

export function Count({ start }: Props) {
  const label: string = `from ${start}`;
  return <Button title={label} onClick={() => start + 1}>Count</Button>;
}
