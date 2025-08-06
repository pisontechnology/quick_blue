import 'dart:async';
import 'dart:typed_data';

import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

import 'messages.g.dart' as messages;

class QuickBlueAndroid extends QuickBluePlatform {
  QuickBlueAndroid();

  final messages.QuickBlueApi _api = messages.QuickBlueApi();
  messages.QuickBlueFlutterApi? _flutterApi;

  static void registerWith() {
    QuickBluePlatform.instance = QuickBlueAndroid();
  }

  void _ensureInitialized() {
    if (_flutterApi != null) return;
    _flutterApi = _FlutterApi(
      onConnectionChangedCallback: (deviceId, state, status) {
        print('Connection changed: $deviceId, $state, $status');
        onConnectionChanged?.call(deviceId, state, status);
      },
      onServiceDiscoveredCallback: (deviceId, serviceId, characteristicIds) {
        onServiceDiscovered?.call(deviceId, serviceId, characteristicIds);
      },
      onValueChangedCallback: (deviceId, characteristicId, value) {
        onValueChanged?.call(deviceId, characteristicId, value);
      },
    );
    messages.QuickBlueFlutterApi.setUp(_flutterApi);
  }

  @override
  Future<CompanionDevice?> companionAssociate({
    String? deviceId,
    ScanFilter? scanFilter,
  }) async {
    _ensureInitialized();

    final device = await _api.companionAssociate(
      deviceId: deviceId,
      serviceUuids: scanFilter?.serviceUuids,
      manufacturerData: scanFilter?.manufacturerData,
    );
    if (device == null) return null;
    return CompanionDevice(
      id: device.id,
      name: device.name,
      associationId: device.associationId,
    );
  }

  @override
  Future<void> companionDisassociate(int associationId) {
    _ensureInitialized();

    return _api.companionDisassociate(associationId);
  }

  @override
  Future<void> connect(String deviceId) {
    _ensureInitialized();

    return _api.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    _ensureInitialized();

    return _api.disconnect(deviceId);
  }

  @override
  Future<void> discoverServices(String deviceId) {
    _ensureInitialized();

    return _api.discoverServices(deviceId);
  }

  @override
  Future<List<CompanionDevice>?> getCompanionAssociations() async {
    _ensureInitialized();

    final associations = await _api.getCompanionAssociations();
    return associations
        .map((device) {
          return CompanionDevice(
            id: device.id,
            name: device.name,
            associationId: device.associationId,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<bool> isBluetoothAvailable() {
    _ensureInitialized();

    return _api.isBluetoothAvailable();
  }

  @override
  Future<BleL2capSocket> openL2cap(String deviceId, int psm) async {
    _ensureInitialized();

    await _api.openL2cap(deviceId, psm);
    print('L2CAP socket opened for device: $deviceId');

    return BleL2capSocket(
      sink: _L2capSink(api: _api, deviceId: deviceId),
      stream: messages
          .l2CapSocketEvents()
          .where((event) => event.deviceId == deviceId)
          .map((e) {
            if (e.data != null) {
              return BleL2CapSocketEventData(
                deviceId: e.deviceId,
                data: e.data!,
              );
            } else if (e.error != null) {
              return BleL2CapSocketEventError(
                deviceId: e.deviceId,
                error: e.error,
              );
            } else if (e.opened == true) {
              return BleL2CapSocketEventOpened(deviceId: e.deviceId);
            } else if (e.closed == true) {
              return BleL2CapSocketEventClosed(deviceId: e.deviceId);
            }

            throw Exception('Unknown L2CAP event: $e');
          }),
    );
  }

  @override
  Future<void> readValue(
    String deviceId,
    String service,
    String characteristic,
  ) {
    _ensureInitialized();

    return _api.readValue(deviceId, service, characteristic);
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) {
    _ensureInitialized();

    return _api.requestMtu(deviceId, expectedMtu);
  }

  @override
  Stream<BlueScanResult> get scanResultStream => messages.scanResults().map(
    (item) => BlueScanResult(
      deviceId: item.deviceId,
      name: item.name,
      rssi: item.rssi,
      serviceUuids: item.serviceUuids,
      manufacturerData: item.manufacturerData,
    ),
  );

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) {
    _ensureInitialized();

    return _api.setNotifiable(
      deviceId,
      service,
      characteristic,
      bleInputProperty.toPlatformBleInputProperty(),
    );
  }

  @override
  Future<void> startScan({ScanFilter scanFilter = const ScanFilter()}) {
    _ensureInitialized();

    return _api.startScan(
      serviceUuids: scanFilter.serviceUuids,
      manufacturerData: scanFilter.manufacturerData,
    );
  }

  @override
  Future<void> stopScan() {
    _ensureInitialized();

    return _api.stopScan();
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) {
    _ensureInitialized();

    return _api.writeValue(
      deviceId,
      service,
      characteristic,
      value,
      bleOutputProperty.toPlatformBleOutputProperty(),
    );
  }
}

class _L2capSink implements EventSink<Uint8List> {
  _L2capSink({required this.api, required this.deviceId});

  final messages.QuickBlueApi api;
  final String deviceId;

  @override
  void add(Uint8List event) {
    api.writeL2cap(deviceId, event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future close() async {}
}

class _FlutterApi extends messages.QuickBlueFlutterApi {
  _FlutterApi({
    required this.onConnectionChangedCallback,
    required this.onServiceDiscoveredCallback,
    required this.onValueChangedCallback,
  });

  final OnConnectionChanged onConnectionChangedCallback;
  final OnServiceDiscovered onServiceDiscoveredCallback;
  final OnValueChanged onValueChangedCallback;

  @override
  void onCharacteristicValueChanged(
    messages.PlatformCharacteristicValueChanged valueChanged,
  ) {
    onValueChangedCallback.call(
      valueChanged.deviceId,
      valueChanged.characteristicId,
      valueChanged.value,
    );
  }

  @override
  void onConnectionStateChange(
    messages.PlatformConnectionStateChange stateChange,
  ) {
    final state = switch (stateChange.state) {
      messages.PlatformConnectionState.disconnected =>
        BlueConnectionState.disconnected,
      messages.PlatformConnectionState.connected =>
        BlueConnectionState.connected,
      _ => null,
    };
    if (state == null) return;

    onConnectionChangedCallback.call(
      stateChange.deviceId,
      state,
      stateChange.gattStatus.toBleStatus(),
    );
  }

  @override
  void onServiceDiscovered(
    messages.PlatformServiceDiscovered serviceDiscovered,
  ) {
    onServiceDiscoveredCallback.call(
      serviceDiscovered.deviceId,
      serviceDiscovered.serviceUuid,
      serviceDiscovered.characteristics,
    );
  }
}

extension _BleInputPropertyExtension on BleInputProperty {
  messages.PlatformBleInputProperty toPlatformBleInputProperty() {
    if (this == BleInputProperty.disabled) {
      return messages.PlatformBleInputProperty.disabled;
    } else if (this == BleInputProperty.notification) {
      return messages.PlatformBleInputProperty.notification;
    } else if (this == BleInputProperty.indication) {
      return messages.PlatformBleInputProperty.indication;
    } else {
      throw ArgumentError('Unknown BleInputProperty: $this');
    }
  }
}

extension _BleOutputPropertyExtension on BleOutputProperty {
  messages.PlatformBleOutputProperty toPlatformBleOutputProperty() {
    if (this == BleOutputProperty.withResponse) {
      return messages.PlatformBleOutputProperty.withResponse;
    } else if (this == BleOutputProperty.withoutResponse) {
      return messages.PlatformBleOutputProperty.withoutResponse;
    } else {
      throw ArgumentError('Unknown BleOutputProperty: $this');
    }
  }
}

extension _BleStatusExtension on messages.PlatformGattStatus {
  BleStatus toBleStatus() {
    switch (this) {
      case messages.PlatformGattStatus.success:
        return BleStatus.success;
      case messages.PlatformGattStatus.failure:
        return BleStatus.failure;
    }
  }
}
