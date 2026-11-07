#ifndef HUSK_WINE_PROBE_H
#define HUSK_WINE_PROBE_H

#include <stdint.h>

/* Starts Wine's wineserver on a background thread and reports whether it came
 * up: 0 means a socket was created and accepted a connection. Gated on the
 * Documents/husk-wine-probe marker, like the FEXCore probe. */
int32_t husk_wine_probe(void);

const char *husk_wine_last_error(void);

#endif
