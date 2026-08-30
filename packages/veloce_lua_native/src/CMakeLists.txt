cmake_minimum_required(VERSION 3.14)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(veloce_lua_native_core LANGUAGES C)
endif()

set(VELOCE_LUA_SOURCE_DIR "" CACHE PATH
    "Optional unpacked Lua 5.4.9 source directory for offline builds")
if(VELOCE_LUA_SOURCE_DIR)
  set(LUA_SRC_DIR "${VELOCE_LUA_SOURCE_DIR}/src")
else()
  include(FetchContent)
  FetchContent_Declare(
    lua_source
    URL https://www.lua.org/ftp/lua-5.4.9.tar.gz
    URL_HASH SHA256=2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  FetchContent_MakeAvailable(lua_source)
  set(LUA_SRC_DIR "${lua_source_SOURCE_DIR}/src")
endif()

if(NOT EXISTS "${LUA_SRC_DIR}/lua.h")
  message(FATAL_ERROR "Lua 5.4 source not found at ${LUA_SRC_DIR}")
endif()
set(LUA_SOURCES
  ${LUA_SRC_DIR}/lapi.c
  ${LUA_SRC_DIR}/lauxlib.c
  ${LUA_SRC_DIR}/lbaselib.c
  ${LUA_SRC_DIR}/lcode.c
  ${LUA_SRC_DIR}/lctype.c
  ${LUA_SRC_DIR}/ldebug.c
  ${LUA_SRC_DIR}/ldo.c
  ${LUA_SRC_DIR}/ldump.c
  ${LUA_SRC_DIR}/lfunc.c
  ${LUA_SRC_DIR}/lgc.c
  ${LUA_SRC_DIR}/llex.c
  ${LUA_SRC_DIR}/lmathlib.c
  ${LUA_SRC_DIR}/lmem.c
  ${LUA_SRC_DIR}/lobject.c
  ${LUA_SRC_DIR}/lopcodes.c
  ${LUA_SRC_DIR}/lparser.c
  ${LUA_SRC_DIR}/lstate.c
  ${LUA_SRC_DIR}/lstring.c
  ${LUA_SRC_DIR}/lstrlib.c
  ${LUA_SRC_DIR}/ltable.c
  ${LUA_SRC_DIR}/ltablib.c
  ${LUA_SRC_DIR}/ltm.c
  ${LUA_SRC_DIR}/lundump.c
  ${LUA_SRC_DIR}/lutf8lib.c
  ${LUA_SRC_DIR}/lvm.c
  ${LUA_SRC_DIR}/lzio.c
)

add_library(veloce_lua_native SHARED veloce_lua.c ${LUA_SOURCES})
target_include_directories(veloce_lua_native PRIVATE ${LUA_SRC_DIR})
target_compile_features(veloce_lua_native PRIVATE c_std_99)
target_compile_definitions(veloce_lua_native PRIVATE LUA_COMPAT_5_3)
set_target_properties(veloce_lua_native PROPERTIES
  OUTPUT_NAME "veloce_lua_native"
  C_VISIBILITY_PRESET hidden
)

if(UNIX AND NOT APPLE)
  find_package(Threads REQUIRED)
  target_compile_definitions(veloce_lua_native PRIVATE LUA_USE_LINUX)
  target_link_libraries(veloce_lua_native PRIVATE m dl Threads::Threads)
endif()
