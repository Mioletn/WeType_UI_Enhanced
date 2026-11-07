#ifndef HUSK_WINE_PROBE_H
#define HUSK_WINE_PROBE_H

#include <stdint.h>
#include <stddef.h>

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

/* M6b: the same wineserver, but with the request/reply channel left open so a
 * FEXCore guest syscall can be forwarded to a real server request. Call
 * husk_ws_start() FIRST (it blocks until the handshake completes), then run
 * the guest; husk_ws_call() is safe to call from the guest's host-side syscall
 * handler. 0 means the wineserver channel is live, negative values are errors.
 * The one-shot husk_wine_probe() behaviour is unchanged when this is unused. */
int32_t husk_ws_start(void);
int husk_ws_is_ready(void);

/* Send one 64-byte union generic_request on the retained request fd and wait
 * for the 64-byte reply. req_id is a REQ_* value from server_protocol.h;
 * payload (if any) is the request's fields AFTER the 12-byte request_header.
 * Returns 0 on a complete round trip and writes the NTSTATUS reply into
 * *out_status; negative values mean the channel or the round trip failed. */
int32_t husk_ws_call(int req_id, const void *payload, size_t payload_size,
                     unsigned int *out_status);

#ifdef __cplusplus
}
#endif

#endif
