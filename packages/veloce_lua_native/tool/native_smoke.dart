import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:veloce_lua_native/src/native_bindings.dart';

int _hostCallback(Pointer<Void> _, VeloceLuaStatePointer state) => 0;

void main(List<String> arguments) {
  if (arguments.length != 1) {
    throw ArgumentError('Usage: dart run tool/native_smoke.dart <library>');
  }
  final bindings = NativeLuaBindings.open(libraryPath: arguments.single);
  final callback = Pointer.fromFunction<NativeHostCallback>(_hostCallback, 0);
  final state = bindings.create(callback, nullptr, 8 * 1024 * 1024);
  if (state == nullptr) {
    throw StateError('Could not create Lua state.');
  }

  try {
    using((arena) {
      const script = '''
assert(io == nil and os == nil and debug == nil and package == nil)
assert(print == nil and load == nil and loadfile == nil and dofile == nil)
function answer()
  return 40 + 2
end
''';
      final code = script.toNativeUtf8(allocator: arena).cast<Char>();
      final name = '@native_smoke.lua'
          .toNativeUtf8(allocator: arena)
          .cast<Char>();
      final status = bindings.eval(state, code, name, 100000, 1000);
      if (status != 0) {
        final error = bindings.lastError(state).cast<Utf8>().toDartString();
        throw StateError(error);
      }
      final function = 'answer'.toNativeUtf8(allocator: arena).cast<Char>();
      if (bindings.prepareGlobal(state, function) == 0) {
        throw StateError('answer is not a function');
      }
      final callStatus = bindings.pcall(state, 0, 1, 100000, 1000);
      if (callStatus != 0) {
        final error = bindings.lastError(state).cast<Utf8>().toDartString();
        throw StateError(error);
      }
      final success = arena<Int32>();
      final answer = bindings.toInteger(state, -1, success);
      if (success.value == 0 || answer != 42) {
        throw StateError('Expected 42, got $answer.');
      }
      bindings.setTop(state, 0);
    });
    // ignore: avoid_print
    print(
      '${bindings.version().cast<Utf8>().toDartString()} smoke test passed.',
    );
  } finally {
    bindings.destroy(state);
  }
}
