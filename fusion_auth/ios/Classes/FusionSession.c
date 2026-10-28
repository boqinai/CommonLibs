#include "FusionSession.h"

#include <stdatomic.h>
#include <stdlib.h>

struct FusionSession {
  atomic_ullong generation;
};

FusionSession *FusionSessionCreate(void) {
  FusionSession *session = calloc(1, sizeof(*session));
  if (session != NULL) {
    atomic_init(&session->generation, 0);
  }
  return session;
}

void FusionSessionDestroy(FusionSession *session) { free(session); }

uint64_t FusionSessionBegin(FusionSession *session) {
  if (session == NULL) {
    return 0;
  }
  return atomic_fetch_add(&session->generation, 1) + 1;
}

void FusionSessionInvalidate(FusionSession *session) {
  if (session == NULL) {
    return;
  }
  atomic_fetch_add(&session->generation, 1);
}

uint64_t FusionSessionCurrent(const FusionSession *session) {
  if (session == NULL) {
    return 0;
  }
  return atomic_load(&session->generation);
}

bool FusionSessionIsCurrent(const FusionSession *session, uint64_t generation) {
  return session != NULL && generation != 0 && generation == atomic_load(&session->generation);
}

bool FusionSessionAccept(const FusionSession *session, uint64_t generation, int callbackID) {
  if (callbackID < 0 || callbackID >= FUSION_CB_COUNT) {
    return false;
  }
  return FusionSessionIsCurrent(session, generation);
}

bool FusionSessionInitFailed(FusionSession *session, FusionStartGate *gate, const char *message) {
  bool won = FusionStartGateComplete(gate, "start_failed", message != NULL ? message : "");
  FusionSessionInvalidate(session);
  return won;
}
