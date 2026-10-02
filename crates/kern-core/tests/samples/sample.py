# A counter
import os

class Counter:
    """Counts things."""

    def __init__(self, start: int = 0):
        self.n = start

    def add(self, *items, step=1):
        for item in items:
            if item is not None:
                self.n += step
        return f"{self.n} items in {os.getcwd()}"

print(Counter(2).add("a", None, True))
