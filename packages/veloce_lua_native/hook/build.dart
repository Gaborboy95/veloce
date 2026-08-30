import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _luaSources = <String>[
  'third_party/lua/src/lapi.c',
  'third_party/lua/src/lauxlib.c',
  'third_party/lua/src/lbaselib.c',
  'third_party/lua/src/lcode.c',
  'third_party/lua/src/lctype.c',
  'third_party/lua/src/ldebug.c',
  'third_party/lua/src/ldo.c',
  'third_party/lua/src/ldump.c',
  'third_party/lua/src/lfunc.c',
  'third_party/lua/src/lgc.c',
  'third_party/lua/src/llex.c',
  'third_party/lua/src/lmathlib.c',
  'third_party/lua/src/lmem.c',
  'third_party/lua/src/lobject.c',
  'third_party/lua/src/lopcodes.c',
  'third_party/lua/src/lparser.c',
  'third_party/lua/src/lstate.c',
  'third_party/lua/src/lstring.c',
  'third_party/lua/src/lstrlib.c',
  'third_party/lua/src/ltable.c',
  'third_party/lua/src/ltablib.c',
  'third_party/lua/src/ltm.c',
  'third_party/lua/src/lundump.c',
  'third_party/lua/src/lutf8lib.c',
  'third_party/lua/src/lvm.c',
  'third_party/lua/src/lzio.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    // Keep Windows on the existing Flutter ffiPlugin path for now.
    if (input.config.code.targetOS != OS.linux) {
      return;
    }

    final builder = CBuilder.library(
      name: 'veloce_lua_native',

      // Code-asset identifier. It does not change the resulting ELF filename.
      assetName: 'veloce_lua_native.dart',

      sources: ['src/veloce_lua.c', ..._luaSources],

      includes: ['third_party/lua/src'],

      defines: {
        'LUA_COMPAT_5_3': null,
        'LUA_USE_LINUX': null,
        '_POSIX_C_SOURCE': '200809L',
      },

      libraries: ['m', 'dl', 'pthread'],

      std: 'c99',
    );

    await builder.run(input: input, output: output);
  });
}
