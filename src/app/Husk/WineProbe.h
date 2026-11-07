#ifndef HUSK_WINE_PROBE_H
#define HUSK_WINE_PROBE_H

#include <stdint.h>

/* extern "C" is not optional here: Swift imports these as C symbols
 * (_husk_wine_probe), while a plain declaration inside WineProbe.mm would get
 * C++ linkage and mangle to __Z16husk_wine_probev, so the app link fails with
 * "Undefined symbols ... _husk_wine_probe". */
#ifdef __cplusplus
extern "C" {
#endif

/* Starts Wine's wineserver on a background thread and reports whether it came
 * up: 0 means a socket was created and accepted a connection. Gated on the
 * Documents/husk-wine-probe marker, like the FEXCore probe. */
int32_t husk_wine_probe(void);

const char *husk_wine_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
