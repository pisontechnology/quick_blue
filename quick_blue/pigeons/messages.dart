import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    input: 'pigeons/messages.dart',
    kotlinOut: 'android/src/main/kotlin/com/example/quick_blue/Messages.g.kt',
    dartOut: 'lib/src/messages.g.dart',
    dartTestOut: 'test/messages_test.g.dart',
  ),
)
enum PlatformBleInputProperty { disabled, notification, indication }

enum PlatformBleOutputProperty { withResponse, withoutResponse }

class PlatformCompanionDevice {
  PlatformCompanionDevice({
    required this.id,
    required this.name,
    required this.associationId,
  });

  final String id;
  final String name;
  final int associationId;
}

@HostApi()
abstract class QuickBlueApi {
  bool isBluetoothAvailable();
  void startScan({
    List<String>? serviceUuids,
    Map<int, Uint8List>? manufacturerData,
  });
  void stopScan();
  void connect(String deviceId);
  void disconnect(String deviceId);
  @async
  PlatformCompanionDevice? companionAssociate({
    String? deviceId,
    List<String>? serviceUuids,
    Map<int, Uint8List>? manufacturerData,
  });
  void companionDisassociate(int associationId);
  List<PlatformCompanionDevice> getCompanionAssociations();
  void discoverServices(String deviceId);
  void setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    PlatformBleInputProperty bleInputProperty,
  );
  void readValue(String deviceId, String service, String characteristic);
  void writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    PlatformBleOutputProperty bleOutputProperty,
  );
  int requestMtu(String deviceId, int expectedMtu);

  @async
  void openL2cap(String deviceId, int psm);
  void closeL2cap(String deviceId);
  void writeL2cap(String deviceId, Uint8List value);
}

class PlatformScanResult {
  PlatformScanResult({
    required this.name,
    required this.deviceId,
    required this.manufacturerDataHead,
    required this.manufacturerData,
    required this.rssi,
    required this.serviceUuids,
  });

  final String name;
  final String deviceId;
  final Uint8List manufacturerDataHead;
  final Uint8List manufacturerData;
  final int rssi;
  final List<String> serviceUuids;
}

enum PlatformConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  unknown,
}

enum PlatformGattStatus { success, failure }

class PlatformConnectionStateChange {
  PlatformConnectionStateChange({
    required this.deviceId,
    required this.state,
    required this.gattStatus,
  });

  final String deviceId;
  final PlatformConnectionState state;
  final PlatformGattStatus gattStatus;
}

class PlatformServiceDiscovered {
  PlatformServiceDiscovered({
    required this.deviceId,
    required this.serviceUuid,
    required this.characteristics,
  });

  final String deviceId;
  final String serviceUuid;
  final List<String> characteristics;
}

class PlatformMtuChange {
  PlatformMtuChange({required this.deviceId, required this.mtu});

  final String deviceId;
  final int mtu;
}

class PlatformCharacteristicValueChanged {
  PlatformCharacteristicValueChanged({
    required this.deviceId,
    required this.characteristicId,
    required this.value,
  });

  final String deviceId;
  final String characteristicId;
  final Uint8List value;
}

class PlatformL2CapSocketEvent {
  PlatformL2CapSocketEvent({
    required this.deviceId,
    this.data,
    this.error,
    this.opened,
    this.closed,
  });

  final String deviceId;
  final Uint8List? data;
  final String? error;
  final bool? opened;
  final bool? closed;
}

@EventChannelApi()
abstract class QuickBlueEventApi {
  PlatformScanResult scanResults();
  PlatformMtuChange mtuChanged();
  PlatformL2CapSocketEvent l2CapSocketEvents();
}

@FlutterApi()
abstract class QuickBlueFlutterApi {
  void onConnectionStateChange(PlatformConnectionStateChange stateChange);
  void onServiceDiscovered(PlatformServiceDiscovered serviceDiscovered);
  void onMtuChanged(PlatformMtuChange mtuChange);
  void onCharacteristicValueChanged(
    PlatformCharacteristicValueChanged valueChanged,
  );
  void onL2CapSocketEvent(PlatformL2CapSocketEvent event);
}
