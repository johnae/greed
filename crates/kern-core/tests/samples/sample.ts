// A counter
interface Countable {
  count(): number;
}

type Items<T> = readonly T[];

export class Counter<T> implements Countable {
  private n = 0;

  add(items: Items<T>, step: number = 1): this {
    this.n += items.length * step;
    return this;
  }

  count(): number {
    return this.n;
  }
}
