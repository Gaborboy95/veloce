#include "ivi_lua.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#define IVI_HOST_EMERGENCY_BYTES (16ULL * 1024ULL * 1024ULL)

struct ivi_lua_state {
  lua_State *lua;
  ivi_lua_host_callback callback;
  void *user_data;
  uint64_t memory_limit;
  uint64_t memory_used;
  int host_operation_depth;
  int64_t remaining_instructions;
  uint64_t deadline_ms;
  char *last_error;
};

static uint64_t ivi_monotonic_ms(void) {
#if defined(_WIN32)
  LARGE_INTEGER frequency;
  LARGE_INTEGER counter;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  return (uint64_t)((counter.QuadPart * 1000) / frequency.QuadPart);
#else
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return (uint64_t)value.tv_sec * 1000ULL +
         (uint64_t)value.tv_nsec / 1000000ULL;
#endif
}

static void ivi_clear_error(ivi_lua_state *state) {
  free(state->last_error);
  state->last_error = NULL;
}

static void ivi_set_error(ivi_lua_state *state, const char *message) {
  ivi_clear_error(state);
  if (message == NULL) {
    return;
  }
  const size_t length = strlen(message);
  state->last_error = (char *)malloc(length + 1);
  if (state->last_error != NULL) {
    memcpy(state->last_error, message, length + 1);
  }
}

static void *ivi_allocator(void *user_data, void *pointer, size_t old_size,
                           size_t new_size) {
  ivi_lua_state *state = (ivi_lua_state *)user_data;
  if (new_size == 0) {
    if (pointer != NULL) {
      state->memory_used = old_size > state->memory_used
                               ? 0
                               : state->memory_used - old_size;
      free(pointer);
    }
    return NULL;
  }

  const uint64_t base = old_size > state->memory_used
                            ? 0
                            : state->memory_used - old_size;
  const uint64_t effective_limit =
      state->memory_limit == 0
          ? 0
          : state->memory_limit +
                (state->host_operation_depth > 0 ? IVI_HOST_EMERGENCY_BYTES
                                                 : 0);
  if (effective_limit > 0 &&
      (base >= effective_limit ||
       (uint64_t)new_size > effective_limit - base)) {
    return NULL;
  }

  void *replacement = realloc(pointer, new_size);
  if (replacement != NULL) {
    state->memory_used = base + new_size;
  }
  return replacement;
}

static ivi_lua_state *ivi_state_from_lua(lua_State *lua) {
  return *(ivi_lua_state **)lua_getextraspace(lua);
}

static void ivi_budget_hook(lua_State *lua, lua_Debug *debug) {
  (void)debug;
  ivi_lua_state *state = ivi_state_from_lua(lua);
  state->remaining_instructions -= 1000;
  if (state->remaining_instructions <= 0) {
    luaL_error(lua, "Lua instruction budget exceeded");
  }
  if (state->deadline_ms > 0 && ivi_monotonic_ms() > state->deadline_ms) {
    luaL_error(lua, "Lua execution deadline exceeded");
  }
}

static void ivi_start_budget(ivi_lua_state *state, int64_t instruction_limit,
                             int32_t timeout_ms) {
  state->remaining_instructions = instruction_limit;
  state->deadline_ms =
      timeout_ms <= 0 ? 0 : ivi_monotonic_ms() + (uint64_t)timeout_ms;
  if (instruction_limit > 0 || timeout_ms > 0) {
    if (instruction_limit <= 0) {
      state->remaining_instructions = INT64_MAX;
    }
    lua_sethook(state->lua, ivi_budget_hook, LUA_MASKCOUNT, 1000);
  }
}

static void ivi_stop_budget(ivi_lua_state *state) {
  lua_sethook(state->lua, NULL, 0, 0);
  state->remaining_instructions = 0;
  state->deadline_ms = 0;
}

static int ivi_traceback(lua_State *lua) {
  const char *message = lua_tostring(lua, 1);
  if (message == NULL) {
    message = "Lua error (non-string error object)";
  }
  luaL_traceback(lua, lua, message, 1);
  return 1;
}

static int ivi_run_protected(ivi_lua_state *state, int argument_count,
                             int result_count, int64_t instruction_limit,
                             int32_t timeout_ms) {
  lua_State *lua = state->lua;
  const int function_index = lua_gettop(lua) - argument_count;
  lua_pushcfunction(lua, ivi_traceback);
  lua_insert(lua, function_index);
  ivi_start_budget(state, instruction_limit, timeout_ms);
  const int status =
      lua_pcall(lua, argument_count, result_count, function_index);
  ivi_stop_budget(state);
  if (status != LUA_OK) {
    ivi_set_error(state, lua_tostring(lua, -1));
  } else {
    ivi_clear_error(state);
  }
  lua_remove(lua, function_index);
  return status;
}

static int ivi_host_trampoline(lua_State *lua) {
  ivi_lua_state *state = ivi_state_from_lua(lua);
  if (state == NULL || state->callback == NULL) {
    lua_pushboolean(lua, 0);
    lua_pushliteral(lua, "host API dispatcher is unavailable");
    return 2;
  }
  state->host_operation_depth++;
  const int results = state->callback(state->user_data, state);
  state->host_operation_depth--;
  return results;
}

static void ivi_remove_global(lua_State *lua, const char *name) {
  lua_pushnil(lua);
  lua_setglobal(lua, name);
}

static void ivi_open_safe_libraries(lua_State *lua) {
  luaL_requiref(lua, LUA_GNAME, luaopen_base, 1);
  lua_pop(lua, 1);
  luaL_requiref(lua, LUA_TABLIBNAME, luaopen_table, 1);
  lua_pop(lua, 1);
  luaL_requiref(lua, LUA_STRLIBNAME, luaopen_string, 1);
  lua_pop(lua, 1);
  luaL_requiref(lua, LUA_MATHLIBNAME, luaopen_math, 1);
  lua_pop(lua, 1);
  luaL_requiref(lua, LUA_UTF8LIBNAME, luaopen_utf8, 1);
  lua_pop(lua, 1);

  ivi_remove_global(lua, "dofile");
  ivi_remove_global(lua, "loadfile");
  ivi_remove_global(lua, "load");
  ivi_remove_global(lua, "print");
  ivi_remove_global(lua, "warn");
  ivi_remove_global(lua, "collectgarbage");
}

ivi_lua_state *ivi_lua_create(ivi_lua_host_callback callback, void *user_data,
                              uint64_t memory_limit_bytes) {
  ivi_lua_state *state = (ivi_lua_state *)calloc(1, sizeof(ivi_lua_state));
  if (state == NULL) {
    return NULL;
  }
  state->callback = callback;
  state->user_data = user_data;
  state->memory_limit = memory_limit_bytes;
  state->lua = lua_newstate(ivi_allocator, state);
  if (state->lua == NULL) {
    free(state);
    return NULL;
  }
  *(ivi_lua_state **)lua_getextraspace(state->lua) = state;
  ivi_open_safe_libraries(state->lua);
  lua_pushcfunction(state->lua, ivi_host_trampoline);
  lua_setglobal(state->lua, "_ivi_host_call");
  return state;
}

void ivi_lua_destroy(ivi_lua_state *state) {
  if (state == NULL) {
    return;
  }
  ivi_clear_error(state);
  if (state->lua != NULL) {
    lua_close(state->lua);
  }
  free(state);
}

const char *ivi_lua_version(void) { return LUA_RELEASE; }

const char *ivi_lua_last_error(ivi_lua_state *state) {
  return state == NULL ? NULL : state->last_error;
}

int32_t ivi_lua_eval(ivi_lua_state *state, const char *code,
                     const char *chunk_name, int64_t instruction_limit,
                     int32_t timeout_ms) {
  if (state == NULL || code == NULL) {
    return LUA_ERRRUN;
  }
  const int status = luaL_loadbufferx(state->lua, code, strlen(code),
                                      chunk_name == NULL ? "plugin" : chunk_name,
                                      "t");
  if (status != LUA_OK) {
    ivi_set_error(state, lua_tostring(state->lua, -1));
    return status;
  }
  return ivi_run_protected(state, 0, 0, instruction_limit, timeout_ms);
}

int32_t ivi_lua_prepare_global(ivi_lua_state *state, const char *name) {
  if (state == NULL || name == NULL) {
    return 0;
  }
  state->host_operation_depth++;
  const int type = lua_getglobal(state->lua, name);
  state->host_operation_depth--;
  if (type != LUA_TFUNCTION) {
    lua_pop(state->lua, 1);
    return 0;
  }
  return 1;
}

int32_t ivi_lua_prepare_ref(ivi_lua_state *state, int32_t ref) {
  if (state == NULL) {
    return 0;
  }
  lua_rawgeti(state->lua, LUA_REGISTRYINDEX, ref);
  if (!lua_isfunction(state->lua, -1)) {
    lua_pop(state->lua, 1);
    return 0;
  }
  return 1;
}

int32_t ivi_lua_pcall(ivi_lua_state *state, int32_t argument_count,
                      int32_t result_count, int64_t instruction_limit,
                      int32_t timeout_ms) {
  if (state == NULL) {
    return LUA_ERRRUN;
  }
  return ivi_run_protected(state, argument_count, result_count,
                           instruction_limit, timeout_ms);
}

int32_t ivi_lua_has_global_function(ivi_lua_state *state, const char *name) {
  if (state == NULL || name == NULL) {
    return 0;
  }
  state->host_operation_depth++;
  lua_getglobal(state->lua, name);
  state->host_operation_depth--;
  const int result = lua_isfunction(state->lua, -1);
  lua_pop(state->lua, 1);
  return result;
}

int32_t ivi_lua_get_top(ivi_lua_state *state) {
  return state == NULL ? 0 : lua_gettop(state->lua);
}

int32_t ivi_lua_check_stack(ivi_lua_state *state, int32_t additional_slots) {
  if (state == NULL || additional_slots < 0) {
    return 0;
  }
  state->host_operation_depth++;
  const int result = lua_checkstack(state->lua, additional_slots);
  state->host_operation_depth--;
  return result;
}

void ivi_lua_set_top(ivi_lua_state *state, int32_t index) {
  if (state != NULL) {
    lua_settop(state->lua, index);
  }
}

int32_t ivi_lua_type_at(ivi_lua_state *state, int32_t index) {
  return state == NULL ? LUA_TNONE : lua_type(state->lua, index);
}

int32_t ivi_lua_is_integer(ivi_lua_state *state, int32_t index) {
  return state != NULL && lua_isinteger(state->lua, index);
}

int64_t ivi_lua_to_integer(ivi_lua_state *state, int32_t index,
                           int32_t *success) {
  if (state == NULL) {
    if (success != NULL) *success = 0;
    return 0;
  }
  return lua_tointegerx(state->lua, index, success);
}

double ivi_lua_to_number(ivi_lua_state *state, int32_t index,
                         int32_t *success) {
  if (state == NULL) {
    if (success != NULL) *success = 0;
    return 0;
  }
  return lua_tonumberx(state->lua, index, success);
}

int32_t ivi_lua_to_boolean(ivi_lua_state *state, int32_t index) {
  return state != NULL && lua_toboolean(state->lua, index);
}

const char *ivi_lua_to_string(ivi_lua_state *state, int32_t index,
                              uint64_t *length) {
  if (state == NULL) {
    if (length != NULL) *length = 0;
    return NULL;
  }
  size_t native_length = 0;
  const char *value = lua_tolstring(state->lua, index, &native_length);
  if (length != NULL) *length = (uint64_t)native_length;
  return value;
}

uint64_t ivi_lua_raw_length(ivi_lua_state *state, int32_t index) {
  return state == NULL ? 0 : (uint64_t)lua_rawlen(state->lua, index);
}

void ivi_lua_push_nil(ivi_lua_state *state) {
  if (state != NULL) lua_pushnil(state->lua);
}

void ivi_lua_push_boolean(ivi_lua_state *state, int32_t value) {
  if (state != NULL) lua_pushboolean(state->lua, value);
}

void ivi_lua_push_integer(ivi_lua_state *state, int64_t value) {
  if (state != NULL) lua_pushinteger(state->lua, (lua_Integer)value);
}

void ivi_lua_push_number(ivi_lua_state *state, double value) {
  if (state != NULL) lua_pushnumber(state->lua, (lua_Number)value);
}

void ivi_lua_push_string(ivi_lua_state *state, const char *value,
                         uint64_t length) {
  if (state != NULL && value != NULL) {
    state->host_operation_depth++;
    lua_pushlstring(state->lua, value, (size_t)length);
    state->host_operation_depth--;
  }
}

void ivi_lua_create_table(ivi_lua_state *state, int32_t array_capacity,
                          int32_t map_capacity) {
  if (state != NULL) {
    state->host_operation_depth++;
    lua_createtable(state->lua, array_capacity, map_capacity);
    state->host_operation_depth--;
  }
}

void ivi_lua_raw_set_index(ivi_lua_state *state, int32_t table_index,
                           int64_t key) {
  if (state != NULL) {
    state->host_operation_depth++;
    lua_rawseti(state->lua, table_index, (lua_Integer)key);
    state->host_operation_depth--;
  }
}

void ivi_lua_set_field(ivi_lua_state *state, int32_t table_index,
                       const char *key) {
  if (state != NULL && key != NULL) {
    state->host_operation_depth++;
    lua_setfield(state->lua, table_index, key);
    state->host_operation_depth--;
  }
}

int32_t ivi_lua_next(ivi_lua_state *state, int32_t table_index) {
  return state == NULL ? 0 : lua_next(state->lua, table_index);
}

void ivi_lua_push_value(ivi_lua_state *state, int32_t index) {
  if (state != NULL) lua_pushvalue(state->lua, index);
}

int32_t ivi_lua_ref_at(ivi_lua_state *state, int32_t index) {
  if (state == NULL || !lua_isfunction(state->lua, index)) {
    return LUA_NOREF;
  }
  lua_pushvalue(state->lua, index);
  state->host_operation_depth++;
  const int reference = luaL_ref(state->lua, LUA_REGISTRYINDEX);
  state->host_operation_depth--;
  return reference;
}

void ivi_lua_unref(ivi_lua_state *state, int32_t ref) {
  if (state != NULL) luaL_unref(state->lua, LUA_REGISTRYINDEX, ref);
}

uint64_t ivi_lua_memory_used(ivi_lua_state *state) {
  return state == NULL ? 0 : state->memory_used;
}
