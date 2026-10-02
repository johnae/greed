/* A counter */
#include <stdio.h>

struct counter {
    int n;
};

static int add(struct counter *c, int step) {
    if (c == NULL) {
        return -1;
    }
    c->n += step;
    printf("%d items\n", c->n);
    return c->n;
}
