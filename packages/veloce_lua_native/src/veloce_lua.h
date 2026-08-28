#ifndef VELOCE_LUA_H_
#define VELOCE_LUA_H_

#include <stdint.h>

#if defined(_WIN32)
#define VELOCE_LUA_EXPORT __declspec(dllexport)
#else
#define VELOCE_LUA_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct veloce_lua_state veloce_lua_state;
typedef int32_t (*veloce_lua_host_callback)(void *user_data,
                                         veloce_lua_state *state);

enum veloce_lua_type {
  VELOCE_LUA_TYPE_NONE = -1,
  VELOCE_LUA_TYPE_NIL = 0,
  VELOCE_LUA_TYPE_BOOLEAN = 1,
  VELOCE_LUA_TYPE_NUMBER = 3,
  VELOCE_LUA_TYPE_STRING = 4,
  VELOCE_LUA_TYPE_TABLE = 5,
  VELOCE_LUA_TYPE_FUNCTION = 6,
};

VELOCE_LUA_EXPORT veloce_lua_state *veloce_lua_create(veloce_lua_host_callback callback,
                                              void *user_data,
                                              uint64_t memory_limit_bytes);
VELOCE_LUA_EXPORT void veloce_lua_destroy(veloce_lua_state *state);
VELOCE_LUA_EXPORT const char *veloce_lua_version(void);
VELOCE_LUA_EXPORT const char *veloce_lua_last_error(veloce_lua_state *state);

VELOCE_LUA_EXPORT int32_t veloce_lua_eval(veloce_lua_state *state, const char *code,
                                     const char *chunk_name,
                                     int64_t instruction_limit,
                                     int32_t timeout_ms);
VELOCE_LUA_EXPORT int32_t veloce_lua_prepare_global(veloce_lua_state *state,
                                              const char *name);
VELOCE_LUA_EXPORT int32_t veloce_lua_prepare_ref(veloce_lua_state *state, int32_t ref);
VELOCE_LUA_EXPORT int32_t veloce_lua_pcall(veloce_lua_state *state, int32_t argument_count,
                                      int32_t result_count,
                                      int64_t instruction_limit,
                                      int32_t timeout_ms);
VELOCE_LUA_EXPORT int32_t veloce_lua_has_global_function(veloce_lua_state *state,
                                                   const char *name);

VELOCE_LUA_EXPORT int32_t veloce_lua_get_top(veloce_lua_state *state);
VELOCE_LUA_EXPORT int32_t veloce_lua_check_stack(veloce_lua_state *state,
                                           int32_t additional_slots);
VELOCE_LUA_EXPORT void veloce_lua_set_top(veloce_lua_state *state, int32_t index);
VELOCE_LUA_EXPORT int32_t veloce_lua_type_at(veloce_lua_state *state, int32_t index);
VELOCE_LUA_EXPORT int32_t veloce_lua_is_integer(veloce_lua_state *state, int32_t index);
VELOCE_LUA_EXPORT int64_t veloce_lua_to_integer(veloce_lua_state *state, int32_t index,
                                          int32_t *success);
VELOCE_LUA_EXPORT double veloce_lua_to_number(veloce_lua_state *state, int32_t index,
                                        int32_t *success);
VELOCE_LUA_EXPORT int32_t veloce_lua_to_boolean(veloce_lua_state *state, int32_t index);
VELOCE_LUA_EXPORT const char *veloce_lua_to_string(veloce_lua_state *state,
                                             int32_t index,
                                             uint64_t *length);
VELOCE_LUA_EXPORT uint64_t veloce_lua_raw_length(veloce_lua_state *state, int32_t index);

VELOCE_LUA_EXPORT void veloce_lua_push_nil(veloce_lua_state *state);
VELOCE_LUA_EXPORT void veloce_lua_push_boolean(veloce_lua_state *state, int32_t value);
VELOCE_LUA_EXPORT void veloce_lua_push_integer(veloce_lua_state *state, int64_t value);
VELOCE_LUA_EXPORT void veloce_lua_push_number(veloce_lua_state *state, double value);
VELOCE_LUA_EXPORT void veloce_lua_push_string(veloce_lua_state *state, const char *value,
                                        uint64_t length);
VELOCE_LUA_EXPORT void veloce_lua_create_table(veloce_lua_state *state,
                                         int32_t array_capacity,
                                         int32_t map_capacity);
VELOCE_LUA_EXPORT void veloce_lua_raw_set_index(veloce_lua_state *state,
                                          int32_t table_index,
                                          int64_t key);
VELOCE_LUA_EXPORT void veloce_lua_set_field(veloce_lua_state *state, int32_t table_index,
                                      const char *key);
VELOCE_LUA_EXPORT int32_t veloce_lua_next(veloce_lua_state *state, int32_t table_index);
VELOCE_LUA_EXPORT void veloce_lua_push_value(veloce_lua_state *state, int32_t index);

VELOCE_LUA_EXPORT int32_t veloce_lua_ref_at(veloce_lua_state *state, int32_t index);
VELOCE_LUA_EXPORT void veloce_lua_unref(veloce_lua_state *state, int32_t ref);
VELOCE_LUA_EXPORT uint64_t veloce_lua_memory_used(veloce_lua_state *state);

#ifdef __cplusplus
}
#endif

#endif  // VELOCE_LUA_H_
