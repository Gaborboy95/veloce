cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "veloce_lua_native")
project(${PROJECT_NAME} LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/native")

set(veloce_lua_native_bundled_libraries
  "$<TARGET_FILE:veloce_lua_native>"
  PARENT_SCOPE
)

