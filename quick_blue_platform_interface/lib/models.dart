import 'dart:async';
import 'dart:typed_data';

class ScanFilter {
  const ScanFilter({this.serviceUuids = const [], this.manufacturerData});

  final List<String> serviceUuids;
  final Map<int, Uint8List>? manufacturerData;
}

class BlueConnectionState {
  static const disconnected = BlueConnectionState._('disconnected');
  static const connected = BlueConnectionState._('connected');

  final String value;

  const BlueConnectionState._(this.value);

  static BlueConnectionState parse(String value) {
    if (value == disconnected.value) {
      return disconnected;
    } else if (value == connected.value) {
      return connected;
    }
    throw ArgumentError.value(value);
  }
}

enum BleStatus { success, failure }

class BleInputProperty {
  static const disabled = BleInputProperty._('disabled');
  static const notification = BleInputProperty._('notification');
  static const indication = BleInputProperty._('indication');

  final String value;

  const BleInputProperty._(this.value);
}

class BleOutputProperty {
  static const withResponse = BleOutputProperty._('withResponse');
  static const withoutResponse = BleOutputProperty._('withoutResponse');

  final String value;

  const BleOutputProperty._(this.value);
}

class BleL2capSocket {
  BleL2capSocket({required this.sink, required this.stream});

  final EventSink<Uint8List> sink;
  final Stream<BleL2CapSocketEvent> stream;
}

sealed class BleL2CapSocketEvent {
  BleL2CapSocketEvent({required this.deviceId});

  final String deviceId;
}

class BleL2CapSocketEventOpened extends BleL2CapSocketEvent {
  BleL2CapSocketEventOpened({required super.deviceId});
}

class BleL2CapSocketEventData extends BleL2CapSocketEvent {
  BleL2CapSocketEventData({required super.deviceId, required this.data});

  final Uint8List data;
}

class BleL2CapSocketEventClosed extends BleL2CapSocketEvent {
  BleL2CapSocketEventClosed({required super.deviceId});
}

class BleL2CapSocketEventError extends BleL2CapSocketEvent {
  BleL2CapSocketEventError({required super.deviceId, this.error});

  final String? error;
}

class CompanionDevice {
  CompanionDevice({
    required this.id,
    required this.name,
    required this.associationId,
  });

  CompanionDevice.fromMap(Map map)
    : id = map['id'] as String,
      name = map['name'] as String,
      associationId = map['associationId'] as int;

  final String id;
  final String name;
  final int associationId;

  @override
  String toString() =>
      'CompanionDevice(id: $id, name: $name, associationId: $associationId)';
}
