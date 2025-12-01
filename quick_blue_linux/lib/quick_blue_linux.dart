import 'dart:async';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

import 'generated_bindings.dart';
import 'src/l2cap_channel.dart';
import 'src/native_libraries.dart';

class QuickBlueLinux extends QuickBluePlatform {
  QuickBlueLinux();

  static void registerWith() {
    QuickBluePlatform.instance = QuickBlueLinux();
  }

  bool isInitialized = false;

  final BlueZClient _client = BlueZClient();
  final Logger _logger = Logger('QuickBlueLinux');
  late final Libc _libc = Libc();
  LibBluetooth? _libBluetooth;

  final Map<String, BlueZDevice> _devices = <String, BlueZDevice>{};
  final Map<String, StreamSubscription<List<String>>>
  _devicePropertySubscriptions = <String, StreamSubscription<List<String>>>{};
  final Map<String, Map<String, StreamSubscription<List<String>>>>
  _notificationSubscriptions =
      <String, Map<String, StreamSubscription<List<String>>>>{};
  final Map<String, bool> _lastConnectionState = <String, bool>{};

  StreamSubscription<BlueZDevice>? _deviceAddedSubscription;
  StreamSubscription<BlueZDevice>? _deviceRemovedSubscription;

  BlueZAdapter? _activeAdapter;

  final StreamController<BlueScanResult> _scanResultController =
      StreamController<BlueScanResult>.broadcast();

  @override
  Stream<BlueScanResult> get scanResultStream => _scanResultController.stream;

  Future<void> _ensureInitialized() async {
    if (isInitialized) {
      return;
    }

    await _client.connect();

    _activeAdapter ??= _client.adapters.firstWhereOrNull(
      (adapter) => adapter.powered,
    );

    _deviceAddedSubscription ??= _client.deviceAdded.listen(
      _onDeviceAdd,
      onError: (error, stackTrace) {
        _logger.warning('Device add stream error', error, stackTrace);
      },
    );
    _deviceRemovedSubscription ??= _client.deviceRemoved.listen(
      _onDeviceRemoved,
      onError: (error, stackTrace) {
        _logger.warning('Device remove stream error', error, stackTrace);
      },
    );

    for (final device in _client.devices) {
      _devices[device.address] = device;
    }

    isInitialized = true;
  }

  @override
  Future<bool> isBluetoothAvailable() async {
    await _ensureInitialized();
    return _activeAdapter != null;
  }

  @override
  Future<void> startScan({ScanFilter scanFilter = const ScanFilter()}) async {
    await _ensureInitialized();

    final adapter = _activeAdapter;
    if (adapter == null) {
      throw StateError('No active Bluetooth adapter available');
    }

    await adapter.startDiscovery();
    for (final device in _client.devices) {
      _onDeviceAdd(device);
    }
  }

  @override
  Future<void> stopScan() async {
    await _ensureInitialized();
    final adapter = _activeAdapter;
    if (adapter == null) {
      return;
    }
    await adapter.stopDiscovery();
  }

  void _onDeviceAdd(BlueZDevice device) {
    _devices[device.address] = device;
    _scanResultController.add(
      BlueScanResult(
        deviceId: device.address,
        name: device.alias,
        manufacturerDataHead: device.manufacturerDataHead,
        rssi: device.rssi,
        serviceUuids: device.uuids
            .map((uuid) => _formatUuid(uuid))
            .toList(growable: false),
      ),
    );
  }

  void _onDeviceRemoved(BlueZDevice device) {
    unawaited(_clearDeviceState(device.address, removeDevice: true));
  }

  @override
  Future<void> connect(String deviceId) async {
    await _ensureInitialized();
    final device = _getDeviceOrThrow(deviceId);

    try {
      await _ensureConnectedDevice(device);
      _emitConnectionState(
        deviceId,
        BlueConnectionState.connected,
        BleStatus.success,
      );
    } on Object catch (error, stackTrace) {
      _logger.severe('Failed to connect to $deviceId', error, stackTrace);
      _emitConnectionState(
        deviceId,
        BlueConnectionState.disconnected,
        BleStatus.failure,
      );
      rethrow;
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await _ensureInitialized();
    final device = _getDeviceOrThrow(deviceId);

    try {
      await device.disconnect();
    } on BlueZNotConnectedException {
      // Already disconnected, ignore.
    } on Object catch (error, stackTrace) {
      _logger.severe('Failed to disconnect from $deviceId', error, stackTrace);
      rethrow;
    } finally {
      _emitConnectionState(
        deviceId,
        BlueConnectionState.disconnected,
        BleStatus.success,
      );
      unawaited(_clearDeviceState(deviceId, removeDevice: false));
    }
  }

  @override
  Future<void> discoverServices(String deviceId) async {
    await _ensureInitialized();
    final device = _getDeviceOrThrow(deviceId);

    await _ensureConnectedDevice(device);
    await _waitForServicesResolved(device);
    _emitServiceDiscovery(device);
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    await _ensureInitialized();
    final resolved = await _resolveCharacteristic(
      deviceId,
      service,
      characteristic,
    );
    final device = resolved.device;
    final targetCharacteristic = resolved.characteristic;

    final key = _characteristicKey(service, characteristic);

    if (bleInputProperty == BleInputProperty.disabled) {
      if (targetCharacteristic.notifying) {
        await targetCharacteristic.stopNotify();
      }
      await _removeNotificationSubscription(deviceId, key);
      return;
    }

    final requiredFlag =
        bleInputProperty == BleInputProperty.indication
            ? BlueZGattCharacteristicFlag.indicate
            : BlueZGattCharacteristicFlag.notify;
    if (!targetCharacteristic.flags.contains(requiredFlag)) {
      throw StateError(
        'Characteristic $characteristic on $service does not support ${bleInputProperty.value}',
      );
    }

    if (!targetCharacteristic.notifying) {
      try {
        await targetCharacteristic.startNotify();
      } on BlueZAlreadyExistsException {
        // Notifications already active, ignore.
      }
    }

    await _removeNotificationSubscription(deviceId, key);

    final subscription = targetCharacteristic.propertiesChanged.listen(
      (changed) {
        if (changed.contains('Value')) {
          _emitCharacteristicValue(device.address, targetCharacteristic);
        }
        if (changed.contains('Notifying') && !targetCharacteristic.notifying) {
          unawaited(_removeNotificationSubscription(device.address, key));
        }
      },
      onError: (error, stackTrace) {
        _logger.warning(
          'Notification stream error for $deviceId ($service/$characteristic)',
          error,
          stackTrace,
        );
      },
    );

    final deviceSubscriptions = _notificationSubscriptions.putIfAbsent(
      deviceId,
      () => <String, StreamSubscription<List<String>>>{},
    );
    deviceSubscriptions[key] = subscription;

    _emitCharacteristicValue(device.address, targetCharacteristic);
  }

  @override
  Future<void> readValue(
    String deviceId,
    String service,
    String characteristic,
  ) async {
    await _ensureInitialized();
    final resolved = await _resolveCharacteristic(
      deviceId,
      service,
      characteristic,
    );
    final device = resolved.device;
    final targetCharacteristic = resolved.characteristic;

    final data = await targetCharacteristic.readValue();
    _emitCharacteristicValue(
      device.address,
      targetCharacteristic,
      overrideValue: data,
    );
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    await _ensureInitialized();
    final resolved = await _resolveCharacteristic(
      deviceId,
      service,
      characteristic,
    );
    final targetCharacteristic = resolved.characteristic;

    final writeType =
        bleOutputProperty == BleOutputProperty.withResponse
            ? BlueZGattCharacteristicWriteType.request
            : BlueZGattCharacteristicWriteType.command;

    await targetCharacteristic.writeValue(value, type: writeType);
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    await _ensureInitialized();
    final device = _getDeviceOrThrow(deviceId);

    await _ensureConnectedDevice(device);
    await _waitForServicesResolved(device);

    _logger.fine(
      'MTU request for $deviceId with expectation $expectedMtu - BlueZ negotiates automatically.',
    );
    return expectedMtu;
  }

  @override
  Future<BleL2capSocket> openL2cap(String deviceId, int psm) async {
    await _ensureInitialized();

    final device =
        _devices[deviceId] ??
        _client.devices.firstWhereOrNull((d) => d.address == deviceId);

    if (device == null) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Device not known');
    }

    _devices[deviceId] = device;

    final bluetooth = _libBluetooth ??= LibBluetooth();

    final channel = L2capChannel(
      deviceId: deviceId,
      psm: psm,
      addressType: _resolveAddressType(device),
      libc: _libc,
      bluetooth: bluetooth,
      logger: _logger,
    );

    try {
      return await channel.open();
    } on Object catch (error, stackTrace) {
      _logger.severe(
        'Unable to open L2CAP channel to $deviceId',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<List<CompanionDevice>?> getCompanionAssociations() async {
    return const <CompanionDevice>[];
  }

  @override
  Future<CompanionDevice?> companionAssociate({
    String? deviceId,
    ScanFilter? scanFilter,
  }) async {
    return null;
  }

  @override
  Future<void> companionDisassociate(int associationId) async {}

  int _resolveAddressType(BlueZDevice device) {
    final addressType = device.addressType;
    if (addressType == BlueZAddressType.random) {
      return BDADDR_LE_RANDOM;
    }
    return BDADDR_LE_PUBLIC;
  }

  BlueZDevice _getDeviceOrThrow(String deviceId) {
    final device =
        _devices[deviceId] ??
        _client.devices.firstWhereOrNull((d) => d.address == deviceId);
    if (device == null) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Device not found');
    }
    _devices[deviceId] = device;
    return device;
  }

  Future<void> _ensureConnectedDevice(BlueZDevice device) async {
    if (device.connected) {
      await _watchDeviceProperties(device);
      return;
    }

    try {
      await device.connect();
    } on BlueZAlreadyConnectedException {
      // Already connected, nothing to do.
    } on BlueZInProgressException {
      await _waitForConnected(device);
    }

    await _waitForConnected(device);
    await _watchDeviceProperties(device);
  }

  Future<void> _watchDeviceProperties(BlueZDevice device) async {
    final deviceId = device.address;
    final existing = _devicePropertySubscriptions.remove(deviceId);
    if (existing != null) {
      await existing.cancel();
    }

    final subscription = device.propertiesChanged.listen(
      (properties) {
        if (properties.contains('Connected')) {
          final state =
              device.connected
                  ? BlueConnectionState.connected
                  : BlueConnectionState.disconnected;
          _emitConnectionState(deviceId, state, BleStatus.success);
          if (!device.connected) {
            unawaited(_clearNotificationSubscriptions(deviceId));
          }
        }

        if (properties.contains('ServicesResolved') &&
            device.servicesResolved) {
          _emitServiceDiscovery(device);
        }
      },
      onError: (error, stackTrace) {
        _logger.warning(
          'Property stream error for $deviceId',
          error,
          stackTrace,
        );
      },
    );

    _devicePropertySubscriptions[deviceId] = subscription;
  }

  void _emitServiceDiscovery(BlueZDevice device) {
    final handler = onServiceDiscovered;
    if (handler == null) {
      return;
    }

    for (final service in device.gattServices) {
      final serviceId = _formatUuid(service.uuid);
      final characteristics = service.characteristics
          .map((characteristic) => _formatUuid(characteristic.uuid))
          .toList(growable: false);
      handler(device.address, serviceId, characteristics);
    }
  }

  Future<void> _waitForConnected(
    BlueZDevice device, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (device.connected) {
      return;
    }

    final completer = Completer<void>();
    late final StreamSubscription<List<String>> subscription;
    subscription = device.propertiesChanged.listen(
      (properties) {
        if (properties.contains('Connected') &&
            device.connected &&
            !completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    try {
      await completer.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _waitForServicesResolved(
    BlueZDevice device, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (device.servicesResolved) {
      return;
    }

    final completer = Completer<void>();
    late final StreamSubscription<List<String>> subscription;
    subscription = device.propertiesChanged.listen(
      (properties) {
        if (properties.contains('ServicesResolved') &&
            device.servicesResolved &&
            !completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    try {
      await completer.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<_ResolvedCharacteristic> _resolveCharacteristic(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    final device = _getDeviceOrThrow(deviceId);
    await _ensureConnectedDevice(device);
    await _waitForServicesResolved(device);

    final canonicalService = _canonicalizeUuid(serviceId);
    final canonicalCharacteristic = _canonicalizeUuid(characteristicId);

    final service = device.gattServices.firstWhereOrNull(
      (candidate) => _bluezUuidToCanonical(candidate.uuid) == canonicalService,
    );
    if (service == null) {
      throw StateError('Service $serviceId not found on $deviceId');
    }

    final characteristic = service.characteristics.firstWhereOrNull(
      (candidate) =>
          _bluezUuidToCanonical(candidate.uuid) == canonicalCharacteristic,
    );
    if (characteristic == null) {
      throw StateError(
        'Characteristic $characteristicId not found on $serviceId for $deviceId',
      );
    }

    return _ResolvedCharacteristic(
      device: device,
      characteristic: characteristic,
    );
  }

  void _emitCharacteristicValue(
    String deviceId,
    BlueZGattCharacteristic characteristic, {
    List<int>? overrideValue,
  }) {
    final handler = onValueChanged;
    if (handler == null) {
      return;
    }

    final value = Uint8List.fromList(overrideValue ?? characteristic.value);
    handler(deviceId, _formatUuid(characteristic.uuid), value);
  }

  void _emitConnectionState(
    String deviceId,
    BlueConnectionState state,
    BleStatus status,
  ) {
    final handler = onConnectionChanged;
    if (handler == null) {
      return;
    }

    final isConnected = state == BlueConnectionState.connected;
    final lastState = _lastConnectionState[deviceId];
    if (status == BleStatus.success && lastState == isConnected) {
      return;
    }

    _lastConnectionState[deviceId] = isConnected;
    handler(deviceId, state, status);
  }

  Future<void> _clearDeviceState(
    String deviceId, {
    required bool removeDevice,
  }) async {
    if (removeDevice) {
      _devices.remove(deviceId);
    }

    _lastConnectionState.remove(deviceId);

    await _clearNotificationSubscriptions(deviceId);

    final subscription = _devicePropertySubscriptions.remove(deviceId);
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  Future<void> _clearNotificationSubscriptions(String deviceId) async {
    final subscriptions = _notificationSubscriptions.remove(deviceId);
    if (subscriptions == null) {
      return;
    }
    for (final subscription in subscriptions.values) {
      await subscription.cancel();
    }
  }

  Future<void> _removeNotificationSubscription(
    String deviceId,
    String key,
  ) async {
    final subscriptions = _notificationSubscriptions[deviceId];
    if (subscriptions == null) {
      return;
    }
    final subscription = subscriptions.remove(key);
    if (subscription != null) {
      await subscription.cancel();
    }
    if (subscriptions.isEmpty) {
      _notificationSubscriptions.remove(deviceId);
    }
  }

  String _characteristicKey(String serviceId, String characteristicId) {
    final serviceCanonical = _canonicalizeUuid(serviceId);
    final characteristicCanonical = _canonicalizeUuid(characteristicId);
    return '$serviceCanonical|$characteristicCanonical';
  }

  String _canonicalizeUuid(String uuid) {
    final cleaned = uuid.replaceAll('-', '').toLowerCase();
    if (cleaned.length == 4) {
      return '0000${cleaned}00001000800000805f9b34fb';
    }
    if (cleaned.length == 8) {
      return '${cleaned}00001000800000805f9b34fb';
    }
    if (cleaned.length == 32) {
      return cleaned;
    }
    throw ArgumentError.value(uuid, 'uuid', 'Unsupported UUID format');
  }

  String _bluezUuidToCanonical(BlueZUUID uuid) {
    return uuid.toString().replaceAll('-', '').toLowerCase();
  }

  String _formatUuid(BlueZUUID uuid) {
    return _canonicalToDashed(_bluezUuidToCanonical(uuid));
  }

  String _canonicalToDashed(String canonical) {
    if (canonical.length != 32) {
      return canonical;
    }
    return '${canonical.substring(0, 8)}-${canonical.substring(8, 12)}-${canonical.substring(12, 16)}-${canonical.substring(16, 20)}-${canonical.substring(20)}';
  }
}

class _ResolvedCharacteristic {
  _ResolvedCharacteristic({required this.device, required this.characteristic});

  final BlueZDevice device;
  final BlueZGattCharacteristic characteristic;
}

extension BlueZDeviceExtension on BlueZDevice {
  Uint8List get manufacturerDataHead {
    if (manufacturerData.isEmpty) return Uint8List(0);

    final sorted =
        manufacturerData.entries.toList()..sort((a, b) => a.key.id - b.key.id);
    return Uint8List.fromList(sorted.first.value);
  }
}
