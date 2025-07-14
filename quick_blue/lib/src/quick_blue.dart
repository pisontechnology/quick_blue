import 'dart:async';
import 'dart:typed_data';

import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

export 'package:quick_blue_platform_interface/models.dart';

export 'quick_blue_android.dart';

QuickBluePlatform get _platform => QuickBluePlatform.instance;

class QuickBlue {
  static Future<bool> isBluetoothAvailable() =>
      _platform.isBluetoothAvailable();

  static Future<void> startScan({ScanFilter scanFilter = const ScanFilter()}) =>
      _platform.startScan(scanFilter: scanFilter);

  static Future<void> stopScan() => _platform.stopScan();

  static Stream<BlueScanResult> get scanResultStream {
    return _platform.scanResultStream;
  }

  static Future<void> connect(String deviceId) => _platform.connect(deviceId);

  static Future<void> disconnect(String deviceId) =>
      _platform.disconnect(deviceId);

  static Future<CompanionDevice?> companionAssociate({
    String? deviceId,
    ScanFilter? scanFilter,
  }) =>
      _platform.companionAssociate(deviceId: deviceId, scanFilter: scanFilter);

  static Future<void> companionDissassociate(int associationId) =>
      _platform.companionDisassociate(associationId);

  static Future<List<CompanionDevice>?> getCompanionAssociations() =>
      _platform.getCompanionAssociations();

  static void setConnectionHandler(OnConnectionChanged? onConnectionChanged) {
    _platform.onConnectionChanged = onConnectionChanged;
  }

  static Future<void> discoverServices(String deviceId) =>
      _platform.discoverServices(deviceId);

  static void setServiceHandler(OnServiceDiscovered? onServiceDiscovered) {
    _platform.onServiceDiscovered = onServiceDiscovered;
  }

  static Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) {
    return _platform.setNotifiable(
      deviceId,
      service,
      characteristic,
      bleInputProperty,
    );
  }

  static void setValueHandler(OnValueChanged? onValueChanged) {
    _platform.onValueChanged = onValueChanged;
  }

  static Future<void> readValue(
    String deviceId,
    String service,
    String characteristic,
  ) {
    return _platform.readValue(deviceId, service, characteristic);
  }

  static Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) {
    return _platform.writeValue(
      deviceId,
      service,
      characteristic,
      value,
      bleOutputProperty,
    );
  }

  static Future<int> requestMtu(String deviceId, int expectedMtu) =>
      _platform.requestMtu(deviceId, expectedMtu);

  static Future<BleL2capSocket> openL2cap(String deviceId, int psm) =>
      _platform.openL2cap(deviceId, psm);
}
