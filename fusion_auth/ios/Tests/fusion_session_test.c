#include "FusionSession.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void test_init_failure_is_start_failed(void) {
  FusionSession *session = FusionSessionCreate();
  FusionStartGate *gate = FusionStartGateCreate();
  assert(session != NULL && gate != NULL);
  FusionStartGateReset(gate);
  assert(FusionStartGateArm(gate));
  uint64_t generation = FusionSessionBegin(session);
  assert(FusionSessionIsCurrent(session, generation));
  assert(FusionSessionInitFailed(session, gate, "sdk init exploded"));
  assert(strcmp(FusionStartGateCode(gate), "start_failed") == 0);
  assert(strcmp(FusionStartGateMessage(gate), "sdk init exploded") == 0);
  assert(!FusionStartGateComplete(gate, "cancelled", ""));
  assert(strcmp(FusionStartGateCode(gate), "start_failed") == 0);
  assert(!FusionSessionIsCurrent(session, generation));
  for (int callback = 0; callback < FUSION_CB_COUNT; callback++) {
    assert(!FusionSessionAccept(session, generation, callback));
  }
  FusionSessionDestroy(session);
  FusionStartGateDestroy(gate);
}

static void test_generation_rejects_previous_request(void) {
  FusionSession *session = FusionSessionCreate();
  uint64_t first = FusionSessionBegin(session);
  assert(FusionSessionAccept(session, first, FUSION_CB_VERIFY_SUCCESS));
  FusionSessionInvalidate(session);
  assert(!FusionSessionIsCurrent(session, first));
  uint64_t second = FusionSessionBegin(session);
  assert(second != first);
  assert(FusionSessionIsCurrent(session, second));
  assert(!FusionSessionIsCurrent(session, first));
  for (int callback = 0; callback < FUSION_CB_COUNT; callback++) {
    assert(!FusionSessionAccept(session, first, callback));
    assert(FusionSessionAccept(session, second, callback));
  }
  assert(!FusionSessionAccept(session, second, FUSION_CB_COUNT));
  assert(!FusionSessionAccept(session, second, -1));
  FusionSessionDestroy(session);
}

static char *read_file(const char *path) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    return NULL;
  }
  assert(fseek(file, 0, SEEK_END) == 0);
  long size = ftell(file);
  assert(size > 0);
  rewind(file);
  char *buf = malloc((size_t)size + 1);
  assert(buf != NULL);
  assert(fread(buf, 1, (size_t)size, file) == (size_t)size);
  buf[size] = '\0';
  fclose(file);
  return buf;
}

static void require_contains(const char *src, const char *needle) {
  if (strstr(src, needle) == NULL) {
    fprintf(stderr, "plugin is missing %s\n", needle);
    assert(0);
  }
}

/* The ObjC plugin must run the same init-failure helper and check every callback. */
static void test_plugin_source_guards_every_callback(void) {
  char *plugin = read_file("fusion_auth/ios/Classes/FusionAuthPlugin.m");
  assert(plugin != NULL);
  require_contains(plugin, "FusionSessionInitFailed");
  require_contains(plugin, "FusionSessionBegin");
  require_contains(plugin, "FUSION_CB_TOKEN_UPDATE");
  require_contains(plugin, "FUSION_CB_TOKEN_UPDATE_RESULT");
  require_contains(plugin, "FUSION_CB_TOKEN_AUTH_SUCCESS");
  require_contains(plugin, "FUSION_CB_TOKEN_AUTH_FAILURE");
  require_contains(plugin, "FUSION_CB_VERIFY_SUCCESS");
  require_contains(plugin, "FUSION_CB_HALFWAY");
  require_contains(plugin, "FUSION_CB_HALFWAY_APPLY");
  require_contains(plugin, "FUSION_CB_VERIFY_FAILED");
  require_contains(plugin, "FUSION_CB_VERIFY_FAILED_CONTINUE");
  require_contains(plugin, "FUSION_CB_TEMPLATE_FINISH");
  require_contains(plugin, "FUSION_CB_VERIFY_INTERRUPT");
  require_contains(plugin, "FUSION_CB_GET_PHONE");
  require_contains(plugin, "FUSION_CB_PROTOCOL");
  free(plugin);
}

int main(void) {
  test_init_failure_is_start_failed();
  test_generation_rejects_previous_request();
  test_plugin_source_guards_every_callback();
  printf("fusion session ok\n");
  return 0;
}
