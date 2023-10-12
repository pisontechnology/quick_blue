library quick_blue_platform_interface;

import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'models.dart';

export 'method_channel_quick_blue.dart';
export 'models.dart';

typedef OnConnectionChanged = void Function(
  String deviceId,
  BlueConnectionState state,
  BleStatus status,
);

typedef OnServiceDiscovered = void Function(
  String deviceId,
  String serviceId,
  List<String> characteristicIds,
);

typedef OnValueChanged = void Function(
  String deviceId,
  String characteristicId,
  Uint8List value,
);

abstract class QuickBluePlatform extends PlatformInterface {
  QuickBluePlatform() : super(token: _token);

  static final Object _token = Object();

  static late QuickBluePlatform _instance;

  static QuickBluePlatform get instance => _instance;

  static set instance(QuickBluePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> isBluetoothAvailable();

  Future<void> startScan();

  Future<void> stopScan();

  Stream<dynamic> get scanResultStream;

  Future<void> connect(String deviceId);

  Future<void> disconnect(String deviceId);

  OnConnectionChanged? onConnectionChanged;

  Future<void> discoverServices(String deviceId);

  OnServiceDiscovered? onServiceDiscovered;

  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  );

  OnValueChanged? onValueChanged;

  Future<void> readValue(
    String deviceId,
    String service,
    String characteristic,
  );

  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  );

  Future<int> requestMtu(String deviceId, int expectedMtu);

  Future<BleL2capSocket> openL2cap(String deviceId, String psm);
}
