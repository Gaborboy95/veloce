# veloce_lua_native

Private Flutter FFI implementation of the pointer-free script runtime contract
from `veloce_lua_core`. It builds the official Lua 5.4.9 source and `veloce_lua.c`
into one application-owned library; it never searches for a system Lua. The
build omits the Lua `io`, `os`, `debug`, `package/loadlib`, and coroutine
library implementations and opens only the explicitly selected safe libraries.

Use `IsolatedNativeLuaRuntimeFactory` for application plugins. It creates one
Dart isolate and isolate-local `NativeCallable` per runtime generation. A small
native condition-variable rendezvous lets synchronous Lua C API calls be
permission-checked on the host isolate without blocking that host. Only
structured values, callback IDs, plugin IDs, and generation IDs cross isolate
ports. `NativeLuaRuntimeFactory` is the direct owning-isolate variant used by
low-level tests and controlled embeddings.

For a local Windows integration-test build from the repository root:

```powershell
cmake -S packages/veloce_lua_native/src -B build/native `
  -G "Visual Studio 17 2022" -A x64
cmake --build build/native --config Debug
$env:VELOCE_LUA_LIBRARY = (Resolve-Path build/native/Debug/veloce_lua_native.dll)
flutter test packages/veloce_lua_native
```

On Linux, from the repository root:

```bash
cmake -S packages/veloce_lua_native/src -B build/native -G Ninja
cmake --build build/native
export VELOCE_LUA_LIBRARY="$PWD/build/native/libveloce_lua_native.so"
(cd packages/veloce_lua_native && flutter test)
```

Normal Flutter desktop builds compile and bundle the library through the
package's platform CMake files. The official source archive URL and SHA-256 are
pinned in `src/CMakeLists.txt`. Offline/cross builds can unpack that archive and
configure with `-DVELOCE_LUA_SOURCE_DIR=/path/to/lua-5.4.9`.
