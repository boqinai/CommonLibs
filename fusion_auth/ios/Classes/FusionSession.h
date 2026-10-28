#ifndef FUSION_SESSION_H
#define FUSION_SESSION_H

#include "FusionStartGate.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct FusionSession FusionSession;

/* Every SDK callback the plugin must generation-check. */
typedef enum FusionCallback {
  FUSION_CB_TOKEN_UPDATE = 0,
  FUSION_CB_TOKEN_UPDATE_RESULT,
  FUSION_CB_TOKEN_AUTH_SUCCESS,
  FUSION_CB_TOKEN_AUTH_FAILURE,
  FUSION_CB_VERIFY_SUCCESS,
  FUSION_CB_HALFWAY,
  FUSION_CB_HALFWAY_APPLY,
  FUSION_CB_VERIFY_FAILED,
  FUSION_CB_VERIFY_FAILED_CONTINUE,
  FUSION_CB_TEMPLATE_FINISH,
  FUSION_CB_VERIFY_INTERRUPT,
  FUSION_CB_GET_PHONE,
  FUSION_CB_PROTOCOL,
  FUSION_CB_COUNT
} FusionCallback;

FusionSession *FusionSessionCreate(void);
void FusionSessionDestroy(FusionSession *session);
/* Bumps the generation and returns the id for this request. */
uint64_t FusionSessionBegin(FusionSession *session);
/* Makes every previously issued id stale. */
void FusionSessionInvalidate(FusionSession *session);
uint64_t FusionSessionCurrent(const FusionSession *session);
bool FusionSessionIsCurrent(const FusionSession *session, uint64_t generation);
/* True only for the active generation and a known callback id. */
bool FusionSessionAccept(const FusionSession *session, uint64_t generation, int callbackID);

/*
 * Plugin start() catch path: record start_failed on the gate exactly once,
 * then invalidate the session so a later cancelled cannot replace it and
 * stale SDK callbacks are ignored.
 */
bool FusionSessionInitFailed(FusionSession *session, FusionStartGate *gate, const char *message);

#endif
