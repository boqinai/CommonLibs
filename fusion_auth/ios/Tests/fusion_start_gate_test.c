#include "FusionStartGate.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* SDK init throws: the plugin calls release(start_failed) once.
   A following release(cancelled) must not replace that status. */
static void test_sdk_init_exception_returns_start_failed_not_cancelled(void) {
  FusionStartGate *gate = FusionStartGateCreate();
  assert(gate != NULL);
  assert(FusionStartGateArm(gate));
  assert(FusionStartGateComplete(gate, "start_failed", "sdk init exploded"));
  assert(!FusionStartGateComplete(gate, "cancelled", ""));
  assert(strcmp(FusionStartGateCode(gate), "start_failed") == 0);
  assert(strcmp(FusionStartGateMessage(gate), "sdk init exploded") == 0);
  FusionStartGateDestroy(gate);
}

typedef struct {
  FusionStartGate *gate;
  const char *code;
  int won;
} attempt_t;

static void *complete_attempt(void *arg) {
  attempt_t *attempt = arg;
  attempt->won = FusionStartGateComplete(attempt->gate, attempt->code, attempt->code) ? 1 : 0;
  return NULL;
}

static void test_concurrent_complete_once(void) {
  for (int n = 0; n < 50; n++) {
    FusionStartGate *gate = FusionStartGateCreate();
    assert(FusionStartGateArm(gate));
    attempt_t attempts[2] = {
        {gate, "start_failed", 0},
        {gate, "cancelled", 0},
    };
    pthread_t threads[2];
    for (int i = 0; i < 2; i++) {
      assert(pthread_create(&threads[i], NULL, complete_attempt, &attempts[i]) == 0);
    }
    for (int i = 0; i < 2; i++) {
      assert(pthread_join(threads[i], NULL) == 0);
    }
    int wins = attempts[0].won + attempts[1].won;
    assert(wins == 1);
    const char *want = attempts[0].won ? attempts[0].code : attempts[1].code;
    assert(strcmp(FusionStartGateCode(gate), want) == 0);
    FusionStartGateDestroy(gate);
  }
}

int main(void) {
  test_sdk_init_exception_returns_start_failed_not_cancelled();
  test_concurrent_complete_once();
  puts("fusion start gate ok");
  return 0;
}
