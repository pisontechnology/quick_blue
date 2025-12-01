import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

import '../generated_bindings.dart';
import 'native_libraries.dart';

class L2capChannel {
  L2capChannel({
    required this.deviceId,
    required this.psm,
    required this.addressType,
    required this.libc,
    required this.bluetooth,
    required Logger logger,
    this.maxPacketLength = 65535,
  }) : _logger = logger,
       _receiveCapacity = maxPacketLength,
       _mtuRefreshPending = true;

  static const int _pollIntervalMs = 20;
  static const int _eagain = 11;
  static const int _ewouldblock = 11;
  static const int _eintr = 4;
  static const int _eacces = 13;
  static const int _econnreset = 104;
  static const int _eshutdown = 108;
  static const int _epipe = 32;
  static const int _einval = 22;

  final String deviceId;
  final int psm;
  final int addressType;
  final Libc libc;
  final LibBluetooth bluetooth;
  final Logger _logger;
  final int maxPacketLength;

  bool _closed = false;
  bool _isWriting = false;
  int? _fd;
  ffi.Pointer<ffi.Uint8>? _readBuffer;
  int _receiveCapacity;
  int? _peerReceiveMtu;
  int? _peerTransmitMtu;
  bool _mtuRefreshPending;
  Timer? _pollTimer;
  late final StreamController<BleL2CapSocketEvent> _eventController =
      StreamController<BleL2CapSocketEvent>.broadcast();
  late final StreamController<Uint8List> _outgoingController =
      StreamController<Uint8List>();
  StreamSubscription<Uint8List>? _outgoingSubscription;
  final Queue<_PendingFrame> _pendingWrites = Queue<_PendingFrame>();

  Future<BleL2capSocket> open() async {
    _ensureReadBuffer(maxPacketLength);
    try {
      _fd = _createSocket();
      _configureSecurity(_fd!);
      _configureChannelOptions(_fd!);
      _connectSocket(_fd!);
      _refreshMtu(_fd!);
      _configureNonBlocking(_fd!);
    } on Object catch (error, stackTrace) {
      _logger.severe(
        'Failed to establish L2CAP channel for $deviceId',
        error,
        stackTrace,
      );
      _cleanup();
      rethrow;
    }

    _pollTimer = Timer.periodic(
      const Duration(milliseconds: _pollIntervalMs),
      _pollReadable,
    );

    _outgoingSubscription = _outgoingController.stream.listen(
      _enqueueWrite,
      onError: (error, st) {
        _logger.warning(
          'Write error on L2CAP channel for $deviceId',
          error,
          st,
        );
        _close(errorMessage: error.toString());
      },
      onDone: () {
        _close();
      },
    );

    _eventController.add(BleL2CapSocketEventOpened(deviceId: deviceId));

    return BleL2capSocket(
      sink: _L2capSink(_outgoingController.sink, _close),
      stream: _eventController.stream,
    );
  }

  void _configureChannelOptions(int fd) {
    final opts = calloc<l2cap_options>();
    try {
      final desiredMtu = maxPacketLength.clamp(64, 65535).toInt();
      opts.ref
        ..omtu = desiredMtu
        ..imtu = desiredMtu
        ..flush_to = 0
        ..mode = 0
        ..fcs = 0
        ..max_tx = 0
        ..txwin_size = 0;

      final result = libc.setsockopt(
        fd,
        SOL_L2CAP,
        L2CAP_OPTIONS,
        opts.cast(),
        ffi.sizeOf<l2cap_options>(),
      );
      if (result != 0) {
        final err = libc.errno;
        _logger.fine('setsockopt(L2CAP_OPTIONS) failed with errno $err');
      }
    } finally {
      calloc.free(opts);
    }
  }

  int _createSocket() {
    final fd = libc.socket(AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP);
    if (fd < 0) {
      final err = libc.errno;
      throw OSError('socket(AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP)', err);
    }
    return fd;
  }

  void _configureSecurity(int fd) {
    _setSecurityLevel(fd, BT_SECURITY_LOW);
  }

  void _connectSocket(int fd) {
    final addrPtr = calloc<sockaddr_l2>();
    try {
      addrPtr.ref
        ..l2_family = AF_BLUETOOTH
        ..l2_psm = _hostToBluetoothShort(psm)
        ..l2_cid = 0
        ..l2_bdaddr_type = addressType & 0xFF;

      final addrStruct = calloc<bdaddr_t>();
      try {
        final addrCString =
            deviceId.toNativeUtf8(allocator: calloc).cast<ffi.Char>();
        try {
          final parseResult = bluetooth.str2ba(addrCString, addrStruct);
          if (parseResult != 0) {
            throw FormatException('Invalid Bluetooth address: $deviceId');
          }
        } finally {
          calloc.free(addrCString);
        }

        _copyBdaddr(addrPtr.ref, addrStruct.ref);
      } finally {
        calloc.free(addrStruct);
      }

      var currentSecurityLevel = BT_SECURITY_MEDIUM;
      while (true) {
        final currentPsm = addrPtr.ref.l2_psm;
        final connectResult = libc.connect(
          fd,
          addrPtr.cast(),
          ffi.sizeOf<sockaddr_l2>(),
        );
        if (connectResult == 0) {
          break;
        }
        final err = libc.errno;
        if (err == _eintr) {
          continue;
        }
        if ((err == _eacces || err == _einval) &&
            currentSecurityLevel != BT_SECURITY_LOW) {
          currentSecurityLevel = BT_SECURITY_LOW;
          _setSecurityLevel(fd, currentSecurityLevel);
          continue;
        }
        if (err == _einval && currentPsm == 0) {
          continue;
        }
        throw OSError('connect', err);
      }
    } finally {
      calloc.free(addrPtr);
    }
  }

  void _setSecurityLevel(int fd, int level) {
    final secPtr = calloc<bt_security>();
    try {
      secPtr.ref
        ..level = level
        ..key_size = 16;
      final result = libc.setsockopt(
        fd,
        SOL_BLUETOOTH,
        BT_SECURITY,
        secPtr.cast(),
        ffi.sizeOf<bt_security>(),
      );
      if (result != 0) {
        final err = libc.errno;
        throw OSError('setsockopt(BT_SECURITY)', err);
      }
    } finally {
      calloc.free(secPtr);
    }
  }

  void _configureNonBlocking(int fd) {
    final flags = libc.fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
      final err = libc.errno;
      throw OSError('fcntl(F_GETFL)', err);
    }
    final setResult = libc.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    if (setResult < 0) {
      final err = libc.errno;
      throw OSError('fcntl(F_SETFL)', err);
    }
  }

  void _refreshMtu(int fd) {
    final optPtr = calloc<l2cap_options>();
    final optLenPtr = calloc<ffi.UnsignedInt>();
    try {
      optLenPtr.value = ffi.sizeOf<l2cap_options>();
      final result = libc.getsockopt(
        fd,
        SOL_L2CAP,
        L2CAP_OPTIONS,
        optPtr.cast(),
        optLenPtr,
      );
      if (result != 0) {
        final err = libc.errno;
        _logger.fine('getsockopt(L2CAP_OPTIONS) failed with errno $err');
        _mtuRefreshPending = true;
        return;
      }

      var imtu = optPtr.ref.imtu;
      if (imtu <= 0) {
        _mtuRefreshPending = true;
        return;
      }
      if (imtu > 0xFFFF) {
        imtu = 0xFFFF;
      }
      if (imtu > _receiveCapacity) {
        _ensureReadBuffer(imtu);
        _logger.fine('Resized L2CAP read buffer for $deviceId to $imtu bytes');
      }
      _peerReceiveMtu = imtu;

      final rawOmtu = optPtr.ref.omtu;
      if (rawOmtu > 0) {
        _peerTransmitMtu = rawOmtu > 0xFFFF ? 0xFFFF : rawOmtu;
      } else {
        _peerTransmitMtu = null;
      }
      _mtuRefreshPending = false;
    } on Object catch (error, stackTrace) {
      _logger.fine(
        'Unable to query L2CAP MTU for $deviceId',
        error,
        stackTrace,
      );
      _mtuRefreshPending = true;
    } finally {
      calloc
        ..free(optLenPtr)
        ..free(optPtr);
    }
  }

  void _pollReadable(Timer timer) {
    if (_closed || _fd == null) {
      timer.cancel();
      return;
    }
    final fd = _fd!;
    if (_mtuRefreshPending) {
      _refreshMtu(fd);
    }
    final bufferPtr = _readBuffer?.cast<ffi.Void>();
    if (bufferPtr == null) {
      timer.cancel();
      _close();
      return;
    }

    while (!_closed) {
      final received = libc.recv(fd, bufferPtr, _receiveCapacity, MSG_DONTWAIT);
      if (received > 0) {
        final data = Uint8List(received);
        data.setAll(0, _readBuffer!.asTypedList(received));
        _eventController.add(
          BleL2CapSocketEventData(deviceId: deviceId, data: data),
        );
        if (_peerReceiveMtu != null && received > _peerReceiveMtu!) {
          _logger.warning(
            'Received $received bytes from $deviceId exceeding negotiated MTU ${_peerReceiveMtu!}, data may be truncated',
          );
        }
        if (_mtuRefreshPending && received == _receiveCapacity) {
          _refreshMtu(fd);
        }
        continue;
      }
      if (received == 0) {
        timer.cancel();
        _close();
        return;
      }

      final err = libc.errno;
      if (err == _eagain || err == _ewouldblock) {
        break;
      }
      if (err == _eintr) {
        continue;
      }

      timer.cancel();
      _close(errorMessage: 'recv errno $err');
      return;
    }
  }

  void _enqueueWrite(Uint8List data) {
    if (_closed) {
      throw StateError('Cannot write to a closed L2CAP socket');
    }
    _pendingWrites.add(_PendingFrame(Uint8List.fromList(data)));
    if (!_isWriting) {
      _isWriting = true;
      unawaited(_drainWriteQueue());
    }
  }

  Future<void> _drainWriteQueue() async {
    try {
      while (_pendingWrites.isNotEmpty && !_closed) {
        final frame = _pendingWrites.first;
        final completed = _sendFrame(frame);
        if (completed) {
          _pendingWrites.removeFirst();
        } else {
          await Future<void>.delayed(
            const Duration(milliseconds: _pollIntervalMs),
          );
        }
      }
    } on Object catch (error, stackTrace) {
      _logger.severe('Failed to write frame for $deviceId', error, stackTrace);
      _close(errorMessage: error.toString());
    } finally {
      _isWriting = false;
    }
  }

  bool _sendFrame(_PendingFrame frame) {
    if (_fd == null) {
      throw StateError('Socket not open');
    }
    if (frame.offset >= frame.data.length) {
      return true;
    }

    final ptr = calloc<ffi.Uint8>(frame.data.length);
    try {
      ptr.asTypedList(frame.data.length).setAll(0, frame.data);
      var offset = frame.offset;
      while (offset < frame.data.length) {
        final chunkPtr = ptr.elementAt(offset).cast<ffi.Void>();
        final remaining = frame.data.length - offset;
        final chunkLimit = _peerTransmitMtu;
        final chunkLength =
            (chunkLimit != null && chunkLimit > 0 && remaining > chunkLimit)
                ? chunkLimit
                : remaining;
        while (true) {
          final written = libc.send(_fd!, chunkPtr, chunkLength, 0);
          if (written > 0) {
            offset += written;
            break;
          }
          if (written == 0) {
            frame.offset = offset;
            return false;
          }
          final err = libc.errno;
          if (err == _eagain || err == _ewouldblock) {
            frame.offset = offset;
            return false;
          }
          if (err == _eintr) {
            continue;
          }
          if (err == _epipe || err == _econnreset || err == _eshutdown) {
            _close(errorMessage: 'send errno $err');
            return true;
          }
          if (err == _einval && offset == 0) {
            _logger.fine(
              'send returned EINVAL on first chunk for $deviceId, retrying',
            );
            continue;
          }
          throw OSError('send', err);
        }
      }

      frame.offset = offset;
      return true;
    } finally {
      calloc.free(ptr);
    }
  }

  void _close({String? errorMessage}) {
    if (_closed) {
      return;
    }
    _closed = true;
    _pollTimer?.cancel();
    _outgoingSubscription?.cancel();
    _cleanup();
    _pendingWrites.clear();
    if (!_outgoingController.isClosed) {
      unawaited(_outgoingController.close());
    }
    if (errorMessage != null) {
      _eventController.add(
        BleL2CapSocketEventError(deviceId: deviceId, error: errorMessage),
      );
    }
    _eventController.add(BleL2CapSocketEventClosed(deviceId: deviceId));
    unawaited(_eventController.close());
  }

  void _cleanup() {
    if (_fd != null && _fd! >= 0) {
      libc.close(_fd!);
      _fd = null;
    }
    if (_readBuffer != null) {
      calloc.free(_readBuffer!);
      _readBuffer = null;
      _receiveCapacity = maxPacketLength;
    }
    _peerReceiveMtu = null;
    _peerTransmitMtu = null;
    _mtuRefreshPending = true;
  }

  void _copyBdaddr(sockaddr_l2 dest, bdaddr_t src) {
    final destBytes = dest.l2_bdaddr.b;
    final srcBytes = src.b;
    for (var i = 0; i < 6; i++) {
      destBytes[i] = srcBytes[i];
    }
  }

  void _ensureReadBuffer(int capacity) {
    if (_readBuffer != null && capacity <= _receiveCapacity) {
      return;
    }
    if (_readBuffer != null) {
      calloc.free(_readBuffer!);
    }
    _readBuffer = calloc<ffi.Uint8>(capacity);
    _receiveCapacity = capacity;
  }

  int _hostToBluetoothShort(int value) {
    if (value < 0 || value > 0xFFFF) {
      throw RangeError.range(value, 0, 0xFFFF, 'psm');
    }
    if (Endian.host == Endian.little) {
      return value & 0xFFFF;
    }
    return ((value & 0xFF) << 8) | ((value >> 8) & 0xFF);
  }
}

class _PendingFrame {
  _PendingFrame(this.data);

  final Uint8List data;
  int offset = 0;
}

class _L2capSink implements EventSink<Uint8List> {
  _L2capSink(this._delegate, this._onClose);

  final StreamSink<Uint8List> _delegate;
  final void Function({String? errorMessage}) _onClose;

  @override
  void add(Uint8List event) {
    _delegate.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _delegate.addError(error, stackTrace);
  }

  @override
  void close() {
    _delegate.close();
    _onClose();
  }
}
