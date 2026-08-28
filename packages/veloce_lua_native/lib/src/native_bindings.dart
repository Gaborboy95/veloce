// ignore_for_file: library_private_types_in_public_api

import 'dart:ffi';
import 'dart:io';

final class _VeloceLuaState extends Opaque {}

typedef VeloceLuaStatePointer = Pointer<_VeloceLuaState>;

typedef NativeHostCallback =
    Int32 Function(Pointer<Void>, VeloceLuaStatePointer);

final class NativeLuaBindings {
  NativeLuaBindings(this.library)
    : create = library
          .lookupFunction<
            Pointer<_VeloceLuaState> Function(
              Pointer<NativeFunction<NativeHostCallback>>,
              Pointer<Void>,
              Uint64,
            ),
            Pointer<_VeloceLuaState> Function(
              Pointer<NativeFunction<NativeHostCallback>>,
              Pointer<Void>,
              int,
            )
          >('veloce_lua_create'),
      destroy = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>),
            void Function(Pointer<_VeloceLuaState>)
          >('veloce_lua_destroy'),
      version = library
          .lookupFunction<Pointer<Char> Function(), Pointer<Char> Function()>(
            'veloce_lua_version',
          ),
      lastError = library
          .lookupFunction<
            Pointer<Char> Function(Pointer<_VeloceLuaState>),
            Pointer<Char> Function(Pointer<_VeloceLuaState>)
          >('veloce_lua_last_error'),
      eval = library
          .lookupFunction<
            Int32 Function(
              Pointer<_VeloceLuaState>,
              Pointer<Char>,
              Pointer<Char>,
              Int64,
              Int32,
            ),
            int Function(
              Pointer<_VeloceLuaState>,
              Pointer<Char>,
              Pointer<Char>,
              int,
              int,
            )
          >('veloce_lua_eval'),
      prepareGlobal = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Pointer<Char>),
            int Function(Pointer<_VeloceLuaState>, Pointer<Char>)
          >('veloce_lua_prepare_global'),
      prepareRef = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_prepare_ref'),
      pcall = library
          .lookupFunction<
            Int32 Function(
              Pointer<_VeloceLuaState>,
              Int32,
              Int32,
              Int64,
              Int32,
            ),
            int Function(Pointer<_VeloceLuaState>, int, int, int, int)
          >('veloce_lua_pcall'),
      hasGlobalFunction = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Pointer<Char>),
            int Function(Pointer<_VeloceLuaState>, Pointer<Char>)
          >('veloce_lua_has_global_function'),
      getTop = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>),
            int Function(Pointer<_VeloceLuaState>)
          >('veloce_lua_get_top'),
      checkStack = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_check_stack'),
      setTop = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32),
            void Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_set_top'),
      typeAt = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_type_at'),
      isInteger = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_is_integer'),
      toInteger = library
          .lookupFunction<
            Int64 Function(Pointer<_VeloceLuaState>, Int32, Pointer<Int32>),
            int Function(Pointer<_VeloceLuaState>, int, Pointer<Int32>)
          >('veloce_lua_to_integer'),
      toNumber = library
          .lookupFunction<
            Double Function(Pointer<_VeloceLuaState>, Int32, Pointer<Int32>),
            double Function(Pointer<_VeloceLuaState>, int, Pointer<Int32>)
          >('veloce_lua_to_number'),
      toBoolean = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_to_boolean'),
      toStringValue = library
          .lookupFunction<
            Pointer<Char> Function(
              Pointer<_VeloceLuaState>,
              Int32,
              Pointer<Uint64>,
            ),
            Pointer<Char> Function(
              Pointer<_VeloceLuaState>,
              int,
              Pointer<Uint64>,
            )
          >('veloce_lua_to_string'),
      rawLength = library
          .lookupFunction<
            Uint64 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_raw_length'),
      pushNil = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>),
            void Function(Pointer<_VeloceLuaState>)
          >('veloce_lua_push_nil'),
      pushBoolean = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32),
            void Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_push_boolean'),
      pushInteger = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int64),
            void Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_push_integer'),
      pushNumber = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Double),
            void Function(Pointer<_VeloceLuaState>, double)
          >('veloce_lua_push_number'),
      pushString = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Pointer<Char>, Uint64),
            void Function(Pointer<_VeloceLuaState>, Pointer<Char>, int)
          >('veloce_lua_push_string'),
      createTable = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32, Int32),
            void Function(Pointer<_VeloceLuaState>, int, int)
          >('veloce_lua_create_table'),
      rawSetIndex = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32, Int64),
            void Function(Pointer<_VeloceLuaState>, int, int)
          >('veloce_lua_raw_set_index'),
      setField = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32, Pointer<Char>),
            void Function(Pointer<_VeloceLuaState>, int, Pointer<Char>)
          >('veloce_lua_set_field'),
      next = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_next'),
      pushValue = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32),
            void Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_push_value'),
      refAt = library
          .lookupFunction<
            Int32 Function(Pointer<_VeloceLuaState>, Int32),
            int Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_ref_at'),
      unref = library
          .lookupFunction<
            Void Function(Pointer<_VeloceLuaState>, Int32),
            void Function(Pointer<_VeloceLuaState>, int)
          >('veloce_lua_unref'),
      memoryUsed = library
          .lookupFunction<
            Uint64 Function(Pointer<_VeloceLuaState>),
            int Function(Pointer<_VeloceLuaState>)
          >('veloce_lua_memory_used');

  factory NativeLuaBindings.open({String? libraryPath}) {
    if (libraryPath != null) {
      return NativeLuaBindings(DynamicLibrary.open(libraryPath));
    }
    if (Platform.isWindows) {
      return NativeLuaBindings(DynamicLibrary.open('veloce_lua_native.dll'));
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return NativeLuaBindings(DynamicLibrary.open('libveloce_lua_native.so'));
    }
    throw UnsupportedError(
      'veloce_lua_native currently supports Windows, Linux, and Android.',
    );
  }

  final DynamicLibrary library;
  final Pointer<_VeloceLuaState> Function(
    Pointer<NativeFunction<NativeHostCallback>>,
    Pointer<Void>,
    int,
  )
  create;
  final void Function(Pointer<_VeloceLuaState>) destroy;
  final Pointer<Char> Function() version;
  final Pointer<Char> Function(Pointer<_VeloceLuaState>) lastError;
  final int Function(
    Pointer<_VeloceLuaState>,
    Pointer<Char>,
    Pointer<Char>,
    int,
    int,
  )
  eval;
  final int Function(Pointer<_VeloceLuaState>, Pointer<Char>) prepareGlobal;
  final int Function(Pointer<_VeloceLuaState>, int) prepareRef;
  final int Function(Pointer<_VeloceLuaState>, int, int, int, int) pcall;
  final int Function(Pointer<_VeloceLuaState>, Pointer<Char>) hasGlobalFunction;
  final int Function(Pointer<_VeloceLuaState>) getTop;
  final int Function(Pointer<_VeloceLuaState>, int) checkStack;
  final void Function(Pointer<_VeloceLuaState>, int) setTop;
  final int Function(Pointer<_VeloceLuaState>, int) typeAt;
  final int Function(Pointer<_VeloceLuaState>, int) isInteger;
  final int Function(Pointer<_VeloceLuaState>, int, Pointer<Int32>) toInteger;
  final double Function(Pointer<_VeloceLuaState>, int, Pointer<Int32>) toNumber;
  final int Function(Pointer<_VeloceLuaState>, int) toBoolean;
  final Pointer<Char> Function(Pointer<_VeloceLuaState>, int, Pointer<Uint64>)
  toStringValue;
  final int Function(Pointer<_VeloceLuaState>, int) rawLength;
  final void Function(Pointer<_VeloceLuaState>) pushNil;
  final void Function(Pointer<_VeloceLuaState>, int) pushBoolean;
  final void Function(Pointer<_VeloceLuaState>, int) pushInteger;
  final void Function(Pointer<_VeloceLuaState>, double) pushNumber;
  final void Function(Pointer<_VeloceLuaState>, Pointer<Char>, int) pushString;
  final void Function(Pointer<_VeloceLuaState>, int, int) createTable;
  final void Function(Pointer<_VeloceLuaState>, int, int) rawSetIndex;
  final void Function(Pointer<_VeloceLuaState>, int, Pointer<Char>) setField;
  final int Function(Pointer<_VeloceLuaState>, int) next;
  final void Function(Pointer<_VeloceLuaState>, int) pushValue;
  final int Function(Pointer<_VeloceLuaState>, int) refAt;
  final void Function(Pointer<_VeloceLuaState>, int) unref;
  final int Function(Pointer<_VeloceLuaState>) memoryUsed;
}
