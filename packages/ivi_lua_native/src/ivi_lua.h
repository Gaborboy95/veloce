#ifndef IVI_LUA_H_
#define IVI_LUA_H_

#include <stdint.h>

#if defined(_WIN32)
#define IVI_LUA_EXPORT __declspec(dllexport)
#else
#define IVI_LUA_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ivi_lua_state ivi_lua_state;
typedef int32_t (*ivi_lua_host_callback)(void *user_data,
                                         ivi_lua_state *state);

enum ivi_lua_type {
  IVI_LUA_TYPE_NONE = -1,
  IVI_LUA_TYPE_NIL = 0,
  IVI_LUA_TYPE_BOOLEAN = 1,
  IVI_LUA_TYPE_NUMBER = 3,
  IVI_LUA_TYPE_STRING = 4,
  IVI_LUA_TYPE_TABLE = 5,
  IVI_LUA_TYPE_FUNCTION = 6,
};

IVI_LUA_EXPORT ivi_lua_state *ivi_lua_create(ivi_lua_host_callback callback,
                                              void *user_data,
                                              uint64_t memory_limit_bytes);
IVI_LUA_EXPORT void ivi_lua_destroy(ivi_lua_state *state);
IVI_LUA_EXPORT const char *ivi_lua_version(void);
IVI_LUA_EXPORT const char *ivi_lua_last_error(ivi_lua_state *state);

IVI_LUA_EXPORT int32_t ivi_lua_eval(ivi_lua_state *state, const char *code,
                                     const char *chunk_name,
                                     int64_t instruction_limit,
                                     int32_t timeout_ms);
IVI_LUA_EXPORT int32_t ivi_lua_prepare_global(ivi_lua_state *state,
                                              const char *name);
IVI_LUA_EXPORT int32_t ivi_lua_prepare_ref(ivi_lua_state *state, int32_t ref);
IVI_LUA_EXPORT int32_t ivi_lua_pcall(ivi_lua_state *state, int32_t argument_count,
                                      int32_t result_count,
                                      int64_t instruction_limit,
                                      int32_t timeout_ms);
IVI_LUA_EXPORT int32_t ivi_lua_has_global_function(ivi_lua_state *state,
                                                   const char *name);

IVI_LUA_EXPORT int32_t ivi_lua_get_top(ivi_lua_state *state);
IVI_LUA_EXPORT int32_t ivi_lua_check_stack(ivi_lua_state *state,
                                           int32_t additional_slots);
IVI_LUA_EXPORT void ivi_lua_set_top(ivi_lua_state *state, int32_t index);
IVI_LUA_EXPORT int32_t ivi_lua_type_at(ivi_lua_state *state, int32_t index);
IVI_LUA_EXPORT int32_t ivi_lua_is_integer(ivi_lua_state *state, int32_t index);
IVI_LUA_EXPORT int64_t ivi_lua_to_integer(ivi_lua_state *state, int32_t index,
                                          int32_t *success);
IVI_LUA_EXPORT double ivi_lua_to_number(ivi_lua_state *state, int32_t index,
                                        int32_t *success);
IVI_LUA_EXPORT int32_t ivi_lua_to_boolean(ivi_lua_state *state, int32_t index);
IVI_LUA_EXPORT const char *ivi_lua_to_string(ivi_lua_state *state,
                                             int32_t index,
                                             uint64_t *length);
IVI_LUA_EXPORT uint64_t ivi_lua_raw_length(ivi_lua_state *state, int32_t index);

IVI_LUA_EXPORT void ivi_lua_push_nil(ivi_lua_state *state);
IVI_LUA_EXPORT void ivi_lua_push_boolean(ivi_lua_state *state, int32_t value);
IVI_LUA_EXPORT void ivi_lua_push_integer(ivi_lua_state *state, int64_t value);
IVI_LUA_EXPORT void ivi_lua_push_number(ivi_lua_state *state, double value);
IVI_LUA_EXPORT void ivi_lua_push_string(ivi_lua_state *state, const char *value,
                                        uint64_t length);
IVI_LUA_EXPORT void ivi_lua_create_table(ivi_lua_state *state,
                                         int32_t array_capacity,
                                         int32_t map_capacity);
IVI_LUA_EXPORT void ivi_lua_raw_set_index(ivi_lua_state *state,
                                          int32_t table_index,
                                          int64_t key);
IVI_LUA_EXPORT void ivi_lua_set_field(ivi_lua_state *state, int32_t table_index,
                                      const char *key);
IVI_LUA_EXPORT int32_t ivi_lua_next(ivi_lua_state *state, int32_t table_index);
IVI_LUA_EXPORT void ivi_lua_push_value(ivi_lua_state *state, int32_t index);

IVI_LUA_EXPORT int32_t ivi_lua_ref_at(ivi_lua_state *state, int32_t index);
IVI_LUA_EXPORT void ivi_lua_unref(ivi_lua_state *state, int32_t ref);
IVI_LUA_EXPORT uint64_t ivi_lua_memory_used(ivi_lua_state *state);

#ifdef __cplusplus
}
#endif

#endif  // IVI_LUA_H_
