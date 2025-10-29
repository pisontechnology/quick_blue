
# quick_blue

**A cross-platform (Android/iOS/macOS/Windows/Linux) BluetoothLE plugin for Flutter**

> **Note:** This repository is now actively maintained by [Pison Technology](https://pison.com) and community contributors. It was originally forked from [woodemi/quick_blue](https://github.com/woodemi/quick_blue). Please file issues and pull requests here.

> **Federated plugin:** Uses a [federated plugin](https://docs.flutter.dev/development/packages-and-plugins/developing-packages#federated-plugins) structure for platform support.

---

## Table of Contents

- [Features](#features)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Platform Notes](#platform-notes)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- Scan, connect, and communicate with Bluetooth LE peripherals
- Cross-platform: Android, iOS, macOS, Windows, Linux
- Federated plugin structure for extensibility
- Data transfer, notifications, MTU requests, and more

---

## Getting Started

Add to your `pubspec.yaml`:

```yaml
dependencies:
    quick_blue: ^<latest_version>
```

Import and use in your Dart code:

```dart
import 'package:quick_blue/quick_blue.dart';
```

See the [example app](quick_blue/example/README.md) for a full usage demonstration.

---


## Usage

- [Scan BLE peripheral](#scan-ble-peripheral)
- [Connect BLE peripheral](#connect-ble-peripheral)
- [Discover services of BLE peripheral](#discover-services-of-ble-peripheral)
- [Transfer data between BLE central & peripheral](#transfer-data-between-ble-central--peripheral)

| API                | Android | iOS | macOS | Windows | Linux |
|--------------------|:-------:|:---:|:-----:|:-------:|:-----:|
| isBluetoothAvailable |   ✔️   | ✔️  |  ✔️   |   ✔️    |  ✔️   |
| startScan/stopScan   |   ✔️   | ✔️  |  ✔️   |   ✔️    |  ✔️   |
| connect/disconnect   |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |
| discoverServices     |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |
| setNotifiable        |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |
| readValue            |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |
| writeValue           |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |
| requestMtu           |   ✔️   | ✔️  |  ✔️   |   ✔️    |       |

---


---

## Platform Notes

### Android
- Ensure you have the correct permissions in your `AndroidManifest.xml` (see [quick_blue/android/src/main/AndroidManifest.xml](quick_blue/android/src/main/AndroidManifest.xml)).
- Some device-specific quirks may apply (see [issues](https://github.com/pisontechnology/quick_blue/issues)).

### iOS/macOS
- Some common service/characteristic UUIDs may be shortened. Be careful when comparing UUIDs.
- See [Apple Bluetooth documentation](https://developer.apple.com/bluetooth/).

### Windows
- See [Microsoft Bluetooth samples](https://docs.microsoft.com/en-us/samples/microsoft/windows-universal-samples/bluetoothle).
- There may be version restrictions for connection without pairing.

### Linux
- Uses BlueZ. See [BlueZ documentation](http://www.bluez.org/).

---

## General useful Bluetooth information

- [Bluetooth Developer Blog: 4 Essential Tools](https://www.bluetooth.com/blog/4-essential-tools-for-every-bluetooth-low-energy-developer/)
- [LightBlue app (iOS/macOS)](https://itunes.apple.com/us/app/lightblue-explorer-bluetooth/id557428110)
- [Nordic nRF Connect app (iOS/Android/Desktop)](https://www.nordicsemi.com/eng/Products/Bluetooth-low-energy/nRF-Connect-for-desktop)
- [Ellisys sniffers](http://www.ellisys.com/products/btcompare.php), [Teledyne LeCroy](http://teledynelecroy.com/frontline/), [Spanalytics PANalyzr](https://www.spanalytics.com/panalyzr)
- [TI CC2540 USB dongle sniffer](http://www.ti.com/tool/CC2540EMK-USB), [Nordic nRF sniffer](https://www.nordicsemi.com/Software-and-tools/Development-Tools/nRF-Sniffer-for-Bluetooth-LE), [Ubertooth One](http://ubertooth.sourceforge.net/hardware/one/)

---



---

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines, or open an issue to discuss your ideas or report bugs.

For questions and support, open an [issue](https://github.com/pisontechnology/quick_blue/issues) or start a [discussion](https://github.com/pisontechnology/quick_blue/discussions).

---

## License

This project is licensed under the terms of the [LICENSE](quick_blue/LICENSE) file.