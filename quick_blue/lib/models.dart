import 'dart:typed_data';

final _empty = Uint8List.fromList(List.empty());

class BlueScanResult {
  String name;
  String deviceId;
  Uint8List? _manufacturerDataHead;
  Uint8List? _manufacturerData;
  int rssi;
  DateTime advertisedDateTime;
  List<String> serviceUuids = <String>[];

  Uint8List get manufacturerDataHead => _manufacturerDataHead ?? _empty;

  Uint8List get manufacturerData => _manufacturerData ?? manufacturerDataHead;

  BlueScanResult.fromMap(map)
      : name = map['name'],
        deviceId = map['deviceId'],
        _manufacturerDataHead = map['manufacturerDataHead'],
        _manufacturerData = map['manufacturerData'],
        rssi = map['rssi'],
        advertisedDateTime = DateTime.now(),
        serviceUuids = map['serviceUuids']?.cast<String>() ?? <String>[];

  Map toMap() => {
        'name': name,
        'deviceId': deviceId,
        'manufacturerDataHead': _manufacturerDataHead,
        'manufacturerData': _manufacturerData,
        'rssi': rssi,
        'advertisedDateTime': advertisedDateTime,
        'serviceUuids': serviceUuids,
      };
}
