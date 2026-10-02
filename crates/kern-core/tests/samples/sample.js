// A counter
import { readFile } from "fs";

export class Counter {
  #n = 0;

  add(...items) {
    for (const item of items) {
      if (item !== null) this.#n += 1;
    }
    return `${this.#n} items`;
  }
}

const view = <div className="count">{new Counter().add(1, true)}</div>;
