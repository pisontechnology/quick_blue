import 'dart:ffi' as ffi;

import '../generated_bindings.dart';

ffi.DynamicLibrary _openFirstAvailable(List<String> candidates) {
  final errors = <Object>[];
  for (final candidate in candidates) {
    try {
      return ffi.DynamicLibrary.open(candidate);
    } catch (error) {
      errors.add(error);
    }
  }
  throw StateError(
    'Unable to load any of the libraries: ${candidates.join(', ')}. Last error: ${errors.isNotEmpty ? errors.last : 'unknown'}',
  );
}

typedef _FcntlNative = ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Int32);
typedef _FcntlDart = int Function(int, int, int);
typedef _ErrnoLocationNative = ffi.Pointer<ffi.Int32> Function();
typedef _ErrnoLocationDart = ffi.Pointer<ffi.Int32> Function();

class Libc {
  Libc({ffi.DynamicLibrary? dynamicLibrary})
    : this._internal(
        dynamicLibrary ?? _openFirstAvailable(['libc.so.6', 'libc.so']),
      );

  Libc._internal(ffi.DynamicLibrary library)
    : _bindings = bluez_bindings(library),
      _fcntl = library.lookupFunction<_FcntlNative, _FcntlDart>('fcntl'),
      _errnoLocation = _loadErrnoFunction(library);
  final bluez_bindings _bindings;
  final _FcntlDart _fcntl;
  final _ErrnoLocationDart _errnoLocation;

  int socket(int domain, int type, int protocol) =>
      _bindings.socket(domain, type, protocol);

  int connect(int fd, ffi.Pointer<sockaddr> address, int length) =>
      _bindings.connect(fd, address, length);

  int send(int fd, ffi.Pointer<ffi.Void> buffer, int count, int flags) =>
      _bindings.send(fd, buffer, count, flags);

  int recv(int fd, ffi.Pointer<ffi.Void> buffer, int count, int flags) =>
      _bindings.recv(fd, buffer, count, flags);

  int setsockopt(
    int fd,
    int level,
    int optionName,
    ffi.Pointer<ffi.Void> optionValue,
    int optionLength,
  ) => _bindings.setsockopt(fd, level, optionName, optionValue, optionLength);

  int close(int fd) => _bindings.close(fd);

  int fcntl(int fd, int cmd, int arg) => _fcntl(fd, cmd, arg);

  int get errno => _errnoLocation().value;

  static _ErrnoLocationDart _loadErrnoFunction(ffi.DynamicLibrary library) {
    for (final symbol in ['__errno_location']) {
      try {
        return library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
          symbol,
        );
      } catch (_) {
        // Try next candidate.
      }
    }
    throw StateError('Unable to locate __errno_location symbol in libc');
  }
}

class LibBluetooth {
  LibBluetooth({ffi.DynamicLibrary? dynamicLibrary})
    : this._internal(
        dynamicLibrary ??
            _openFirstAvailable(['libbluetooth.so.3', 'libbluetooth.so']),
      );

  LibBluetooth._internal(ffi.DynamicLibrary library)
    : _bindings = bluez_bindings(library);

  final bluez_bindings _bindings;

  int str2ba(ffi.Pointer<ffi.Char> string, ffi.Pointer<bdaddr_t> address) =>
      _bindings.str2ba(string, address);
}
