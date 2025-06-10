package com.example.quick_blue

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.*
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat.startIntentSenderForResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.*
import java.util.concurrent.Executor

private const val TAG = "QuickBluePlugin"
private const val SELECT_DEVICE_REQUEST_CODE = 10011

/** QuickBluePlugin */
@SuppressLint("MissingPermission")
class QuickBluePlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.ActivityResultListener,
  ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var method : MethodChannel
  private lateinit var eventScanResult : EventChannel
  private lateinit var messageConnector: BasicMessageChannel<Any>

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    method = MethodChannel(flutterPluginBinding.binaryMessenger, "quick_blue/method")
    eventScanResult = EventChannel(flutterPluginBinding.binaryMessenger, "quick_blue/event.scanResult")
    messageConnector = BasicMessageChannel(flutterPluginBinding.binaryMessenger, "quick_blue/message.connector", StandardMessageCodec.INSTANCE)

    method.setMethodCallHandler(this)
    eventScanResult.setStreamHandler(this)

    context = flutterPluginBinding.applicationContext
    mainThreadHandler = Handler(Looper.getMainLooper())
    bluetoothManager = flutterPluginBinding.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    companionDeviceManager = flutterPluginBinding.applicationContext.getSystemService(Context.COMPANION_DEVICE_SERVICE) as CompanionDeviceManager
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)

    // Disconnect all active devices (call toList to avoid ConcurrentModificationException)
    knownGatts.toList().forEach { gatt ->
      cleanConnection(gatt)
    }

    eventScanResult.setStreamHandler(null)
    method.setMethodCallHandler(null)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    when (requestCode) {
      SELECT_DEVICE_REQUEST_CODE -> when(resultCode) {
        Activity.RESULT_OK -> {
          // TODO(cg): unlikely we need to do anything here; handling the association is
          //           managed within onAssociationCreated.
          return true
        }
      }
    }
    return false
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  private lateinit var context: Context
  private lateinit var mainThreadHandler: Handler
  private lateinit var bluetoothManager: BluetoothManager
  private lateinit var companionDeviceManager: CompanionDeviceManager

  private var activity: Activity? = null

  private val executor: Executor =  Executor { it.run() }
  private val knownGatts = mutableListOf<BluetoothGatt>()
  private val streamDelegates = mutableMapOf<String, L2CapStreamDelegate>()

  private fun sendMessage(messageChannel: BasicMessageChannel<Any>, message: Map<String, Any>) {
    mainThreadHandler.post { messageChannel.send(message) }
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "isBluetoothAvailable" -> {
        result.success(bluetoothManager.adapter.isEnabled)
      }
      "startScan" -> {
        val filterServiceUuids = call.argument<List<String>>("serviceUuids")
        val filterManufacturerData = call.argument<Map<Int, ByteArray>>("manufacturerData")

        val filters = filterServiceUuids?.map {
          val builder = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid.fromString(it))
          if (filterManufacturerData != null) {
            val id = filterManufacturerData.keys.first()
            val data = filterManufacturerData[id]
            builder.setManufacturerData(id, data)
          }
          builder.build()
        }
        val settings = ScanSettings.Builder()
          .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
          .setMatchMode(ScanSettings.MATCH_MODE_STICKY)
          .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
          .setReportDelay(0L)
          .build()
        bluetoothManager.adapter.bluetoothLeScanner?.startScan(filters, settings, scanCallback)
        result.success(null)
      }
      "stopScan" -> {
        bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)
        result.success(null)
      }
      "companionAssociate" -> {
        val filterDeviceId = call.argument<String>("deviceId")
        val filterServiceUuids = call.argument<List<String>>("serviceUuids")

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
          result.error("UnsupportedAndroidVersion", "Associating companion devices requires Android API 33 or higher", null)
          return
        }

        val deviceFilter: BluetoothDeviceFilter = BluetoothDeviceFilter.Builder().let {
          if (filterDeviceId != null) {
            it.setAddress(filterDeviceId)
          }

          filterServiceUuids?.map { uuid ->
            it.addServiceUuid(ParcelUuid.fromString(uuid), null)
          }
          it.build()
        }
        val pairingRequest: AssociationRequest = AssociationRequest.Builder()
          .addDeviceFilter(deviceFilter)
          .setSingleDevice(true)
          .build()

        companionDeviceManager.associate(pairingRequest,
          executor,
          object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) {
                startIntentSenderForResult(activity!!,
                    intentSender, SELECT_DEVICE_REQUEST_CODE, null, 0, 0, 0, null)
            }

            override fun onAssociationCreated(associationInfo: AssociationInfo) {
              var associationId = associationInfo.id
              var macAddress = associationInfo.deviceMacAddress
              var displayName = associationInfo.displayName

              result.success(mapOf(
                "associationId" to associationId,
                "id" to macAddress.toString(),
                "name" to displayName
              ))
            }

            override fun onFailure(errorMessage: CharSequence?) {
              result.error("AssociationFailed", errorMessage.toString(), null)
            }
          }
        )
      }
      "companionDisassociate" -> {
        val associationId = call.argument<Int>("associationId")!!
        companionDeviceManager.disassociate(associationId)
        result.success(null)
      }
      "companionListAssociations" -> {
        val data = companionDeviceManager.myAssociations.map {
          mapOf(
            "associationId" to it.id,
            "id" to it.deviceMacAddress.toString(),
            "name" to it.displayName,
          )
        }
        result.success(data)
      }
      "connect" -> {
        val deviceId = call.argument<String>("deviceId")!!
        if (knownGatts.find { it.device.address == deviceId } != null) {
          return result.success(null)
        }
        val remoteDevice = bluetoothManager.adapter.getRemoteDevice(deviceId)
        connectDevice(remoteDevice)
        result.success(null)
        // TODO connecting
      }
      "disconnect" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        cleanConnection(gatt)
        result.success(null)
        //FIXME If `disconnect` is called before BluetoothGatt.STATE_CONNECTED
        // there will be no `disconnected` message any more
      }
      "discoverServices" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        gatt.discoverServices()
        result.success(null)
      }
      "setNotifiable" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val bleInputProperty = call.argument<String>("bleInputProperty")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        gatt.setNotifiable(service to characteristic, bleInputProperty)
        result.success(null)
      }
      "requestMtu" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val expectedMtu = call.argument<Int>("expectedMtu")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        gatt.requestMtu(expectedMtu)
        result.success(null)
      }
      "readValue" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        val readResult = gatt.getCharacteristic(service to characteristic)?.let {
          gatt.readCharacteristic(it)
        }
        if (readResult == true)
          result.success(null)
        else
          result.error("Characteristic unavailable", null, null)
      }
      "writeValue" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val value = call.argument<ByteArray>("value")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        val writeResult = gatt.getCharacteristic(service to characteristic)?.let {
          it.value = value
          gatt.writeCharacteristic(it)
        }
        if (writeResult == true)
          result.success(null)
        else
          result.error("Characteristic unavailable", null, null)
      }
      "openL2cap" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val psm = call.argument<Int>("psm")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
          ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        val socket = gatt.device.createInsecureL2capChannel(psm)
        val delegate = L2CapStreamDelegate(socket, openedCallback = {
          sendMessage(messageConnector, mapOf(
                  "deviceId" to gatt.device.address,
                  "l2capStatus" to "opened"
          ))
        }, closedCallback =  {
          sendMessage(messageConnector, mapOf(
                  "deviceId" to gatt.device.address,
                  "l2capStatus" to "closed"
          ))
        }, streamCallback =  {
          sendMessage(messageConnector, mapOf(
                  "deviceId" to gatt.device.address,
                  "l2capStatus" to "stream",
                  "data" to it
          ))
        }, errorCallback = {
          sendMessage(messageConnector, mapOf(
                  "deviceId" to gatt.device.address,
                  "l2capStatus" to "error",
                  "error" to (it.message ?: ""),
          ))
        })

        streamDelegates[gatt.device.address] = delegate
        result.success(null)
      }
      "closeL2cap" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val delegate = streamDelegates[deviceId]
                ?: return result.error("IllegalArgument", "No stream delegate for deviceId: $deviceId", null)
        delegate.close()
        streamDelegates.remove(deviceId)
        result.success(null)
      }
      "_l2cap_write" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val data = call.argument<ByteArray>("data")!!
        val delegate = streamDelegates[deviceId]
                ?: return result.error("IllegalArgument", "No stream delegate for deviceId: $deviceId", null)
        delegate.write(data)
        result.success(null)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun connectDevice(bluetoothDevice: BluetoothDevice) {
    val gatt = bluetoothDevice.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    knownGatts.add(gatt)
  }

  private fun cleanConnection(gatt: BluetoothGatt) {
    knownGatts.remove(gatt)
    val delegate = streamDelegates[gatt.device.address]
    if (delegate != null) {
      delegate.close()
      streamDelegates.remove(gatt.device.address)
    }
    gatt.disconnect()
  }

  private val scanCallback = object : ScanCallback() {
    override fun onScanFailed(errorCode: Int) {
      Log.d(TAG, "onScanFailed: $errorCode")
    }

    override fun onScanResult(callbackType: Int, result: ScanResult) {
      scanResultSink?.success(mapOf<String, Any>(
              "name" to (result.scanRecord?.deviceName ?: ""),
              "deviceId" to result.device.address,
              "manufacturerDataHead" to (result.manufacturerDataHead ?: byteArrayOf()),
              "rssi" to result.rssi,
              "serviceUuids" to (result.scanRecord?.serviceUuids?.map { it.uuid.toString() } ?: emptyList())
      ))
    }

    override fun onBatchScanResults(results: MutableList<ScanResult>?) {
    }
  }

  private var scanResultSink: EventChannel.EventSink? = null

  override fun onListen(args: Any?, eventSink: EventChannel.EventSink?) {
    val map = args as? Map<String, Any> ?: return
    when (map["name"]) {
      "scanResult" -> scanResultSink = eventSink
    }
  }

  override fun onCancel(args: Any?) {
    val map = args as? Map<String, Any> ?: return
    when (map["name"]) {
      "scanResult" -> scanResultSink = null
    }
  }

  private val gattCallback = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
      val gattStatus = when(status) {
        BluetoothGatt.GATT_SUCCESS -> "success"
        BluetoothGatt.GATT_FAILURE -> "failure"
        else -> "failure"
      }
      val connectionState = when(newState) {
        BluetoothGatt.STATE_CONNECTED -> "connected"
        BluetoothGatt.STATE_CONNECTING -> "connecting"
        BluetoothGatt.STATE_DISCONNECTED -> "disconnected"
        BluetoothGatt.STATE_DISCONNECTING -> "disconnecting"
        else -> "unknown"
      }
      // Clear out the connection if something bad happened.
      if (newState == BluetoothGatt.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
        cleanConnection(gatt)
      }

      sendMessage(messageConnector, mapOf(
        "deviceId" to gatt.device.address,
        "ConnectionState" to connectionState,
        "status" to gattStatus
      ))

      // If we've disconnected, ensure that we also close out the gatt.
      if (newState == BluetoothGatt.STATE_DISCONNECTED) {
        gatt.close()
      }
    }

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
      if (status != BluetoothGatt.GATT_SUCCESS) return
      gatt.services?.forEach { service ->
        sendMessage(messageConnector, mapOf(
          "deviceId" to gatt.device.address,
          "ServiceState" to "discovered",
          "service" to service.uuid.toString(),
          "characteristics" to service.characteristics.map { it.uuid.toString() }
        ))
      }
    }

    override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
      if (status == BluetoothGatt.GATT_SUCCESS) {
        sendMessage(messageConnector, mapOf(
          "mtuConfig" to mtu
        ))
      }
    }

    override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
      sendMessage(messageConnector, mapOf(
        "deviceId" to gatt.device.address,
        "characteristicValue" to mapOf(
          "characteristic" to characteristic.uuid.toString(),
          "value" to characteristic.value
        )
      ))
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic, status: Int) {
      // TODO(cg): send this as a message
    }

    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
      sendMessage(messageConnector, mapOf(
        "deviceId" to gatt.device.address,
        "characteristicValue" to mapOf(
          "characteristic" to characteristic.uuid.toString(),
          "value" to characteristic.value
        )
      ))
    }
  }
}

class L2CapStreamDelegate(private val socket: BluetoothSocket, val openedCallback: () -> Unit,
                          val closedCallback: () -> Unit, val streamCallback: (ByteArray) -> Unit,
                          val errorCallback: (Exception) -> Unit) {
  private val handlerThread = HandlerThread("L2CapThread")
  private val handler: Handler

  private val handlerReadThread = HandlerThread("L2CapReadThread")
  private val handlerRead: Handler

  init {
    handlerThread.start()
    handlerReadThread.start()

    handler = Handler(handlerThread.looper)
    handlerRead = Handler(handlerReadThread.looper)

    handler.post {
      try {
        socket.connect()
      } catch (e: Exception) {
        errorCallback(e)
        handlerThread.quit()
        handlerReadThread.quit()
        return@post
      }
      openedCallback()
      read()
    }
  }

  fun write(data: ByteArray) {
    handler.post {
      try {
        socket.outputStream.write(data)
      } catch (e: Exception) {
        errorCallback(e)
      }
    }
  }

  fun close() {
    handlerThread.quit()
    handlerReadThread.quit()
    socket.close()
    closedCallback()
  }


  private fun read() {
    handlerRead.post {
      try {
        val data = ByteArray(8192)

        while (socket.isConnected) {
          val bytesRead = socket.inputStream.read(data)
          if (bytesRead != -1) {
            streamCallback(data.copyOfRange(0, bytesRead))
          }
        }
      } catch (e: Exception) {
        errorCallback(e)
      }
    }
  }
}

val ScanResult.manufacturerDataHead: ByteArray?
  get() {
    val sparseArray = scanRecord?.manufacturerSpecificData ?: return null
    if (sparseArray.size() == 0) return null

    return sparseArray.keyAt(0).toShort().toByteArray() + sparseArray.valueAt(0)
  }

fun Short.toByteArray(byteOrder: ByteOrder = ByteOrder.LITTLE_ENDIAN): ByteArray =
        ByteBuffer.allocate(2 /*Short.SIZE_BYTES*/).order(byteOrder).putShort(this).array()

fun BluetoothGatt.getCharacteristic(serviceCharacteristic: Pair<String, String>) =
        getService(UUID.fromString(serviceCharacteristic.first)).getCharacteristic(UUID.fromString(serviceCharacteristic.second))

private val DESC__CLIENT_CHAR_CONFIGURATION = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

fun BluetoothGatt.setNotifiable(serviceCharacteristic: Pair<String, String>, bleInputProperty: String) {
  val descriptor = getCharacteristic(serviceCharacteristic).getDescriptor(DESC__CLIENT_CHAR_CONFIGURATION)
  val (value, enable) = when (bleInputProperty) {
    "notification" -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE to true
    "indication" -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE to true
    else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE to false
  }
  descriptor.value = value
  setCharacteristicNotification(descriptor.characteristic, enable) && writeDescriptor(descriptor)
}