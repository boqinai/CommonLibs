#ifndef FUSION_START_GATE_H
#define FUSION_START_GATE_H

#include <stdbool.h>

typedef struct FusionStartGate FusionStartGate;

FusionStartGate *FusionStartGateCreate(void);
void FusionStartGateDestroy(FusionStartGate *gate);
void FusionStartGateReset(FusionStartGate *gate);
bool FusionStartGateArm(FusionStartGate *gate);
/* Completes an armed gate exactly once. The winning code is stored. */
bool FusionStartGateComplete(FusionStartGate *gate, const char *code, const char *message);
const char *FusionStartGateCode(const FusionStartGate *gate);
const char *FusionStartGateMessage(const FusionStartGate *gate);

#endif
