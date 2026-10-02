// Package kern counts things.
package kern

import "fmt"

type Counter struct {
	n int
}

func (c *Counter) Add(items ...string) error {
	for _, item := range items {
		if item != "" {
			c.n += 1
		}
	}
	return fmt.Errorf("%d items\n", c.n)
}
