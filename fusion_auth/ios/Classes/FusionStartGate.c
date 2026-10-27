#include "FusionStartGate.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { FUSION_GATE_EMPTY = 0, FUSION_GATE_ARMED = 1, FUSION_GATE_DONE = 2 };

struct FusionStartGate {
  atomic_int state;
  char code[96];
  char message[192];
};

static void copy_field(char *dst, size_t cap, const char *src) {
  if (src == NULL) {
    src = "";
  }
  snprintf(dst, cap, "%s", src);
}

FusionStartGate *FusionStartGateCreate(void) {
  FusionStartGate *gate = calloc(1, sizeof(*gate));
  if (gate != NULL) {
    atomic_init(&gate->state, FUSION_GATE_EMPTY);
  }
  return gate;
}

void FusionStartGateDestroy(FusionStartGate *gate) { free(gate); }

void FusionStartGateReset(FusionStartGate *gate) {
  if (gate == NULL) {
    return;
  }
  atomic_store(&gate->state, FUSION_GATE_EMPTY);
  gate->code[0] = '\0';
  gate->message[0] = '\0';
}

bool FusionStartGateArm(FusionStartGate *gate) {
  if (gate == NULL) {
    return false;
  }
  int expected = FUSION_GATE_EMPTY;
  return atomic_compare_exchange_strong(&gate->state, &expected, FUSION_GATE_ARMED);
}

bool FusionStartGateComplete(FusionStartGate *gate, const char *code, const char *message) {
  if (gate == NULL) {
    return false;
  }
  int expected = FUSION_GATE_ARMED;
  if (!atomic_compare_exchange_strong(&gate->state, &expected, FUSION_GATE_DONE)) {
    return false;
  }
  copy_field(gate->code, sizeof gate->code, code);
  copy_field(gate->message, sizeof gate->message, message);
  return true;
}

const char *FusionStartGateCode(const FusionStartGate *gate) {
  return gate == NULL ? "" : gate->code;
}

const char *FusionStartGateMessage(const FusionStartGate *gate) {
  return gate == NULL ? "" : gate->message;
}
