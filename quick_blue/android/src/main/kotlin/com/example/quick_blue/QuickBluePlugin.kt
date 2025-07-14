package com.example.quick_blue

import FlutterError
import L2CapSocketEventsStreamHandler
import MtuChangedStreamHandler
import PigeonEventSink
import PlatformBleInputProperty
import PlatformBleOutputProperty
import PlatformCharacteristicValueChanged
import PlatformCompanionDevice
import PlatformConnectionState
import PlatformConnectionStateChange
import PlatformL2CapSocketEvent
import PlatformMtuChange
import PlatformScanResult
import PlatformServiceDiscovered
import QuickBlueApi
import QuickBlueFlutterApi
import ScanResultsStreamHandler
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
import androidx.core.app.ActivityCompat.startIntentSenderForResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.*
import java.util.concurrent.Executor

private const val SELECT_DEVICE_REQUEST_CODE = 10011

/** QuickBluePlugin */
@SuppressLint("MissingPermission")
class QuickBluePlugin: FlutterPlugin, PluginRegistry.ActivityResultListener,
  ActivityAware, QuickBlueApi {

  private val scanResultListener = ScanResultListener()
  private val mtuChangedListener = MtuChangedListener()
  private val l2CapSocketEventsListener = L2CapSocketEventsListener()

  private fun setUp(messenger: BinaryMessenger, context: Context) {
    QuickBlueApi.setUp(messenger, this)
    ScanResultsStreamHandler.register(messenger, scanResultListener)
    MtuChangedStreamHandler.register(messenger, mtuChangedListener)
    L2CapSocketEventsStreamHandler.register(messenger, l2CapSocketEventsListener)

    quickBlueFlutterApi = QuickBlueFlutterApi(messenger)
    this.context = context
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    mainThreadHandler = Handler(Looper.getMainLooper())
    bluetoothManager = binding.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    companionDeviceManager = binding.applicationContext.getSystemService(Context.COMPANION_DEVICE_SERVICE) as CompanionDeviceManager

    setUp(binding.binaryMessenger, binding.applicationContext)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d("QuickBluePlugin", "onDetachedFromEngine")
    bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)

    // Disconnect all active devices (call toList to avoid ConcurrentModificationException)
    knownGatts.toList().forEach { gatt ->
      cleanConnection(gatt)
    }

    setUp(binding.binaryMessenger, binding.applicationContext)
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
  private var quickBlueFlutterApi: QuickBlueFlutterApi? = null

  private var activity: Activity? = null

  private val executor: Executor =  Executor { it.run() }
  private val knownGatts = mutableListOf<BluetoothGatt>()
  private val streamDelegates = mutableMapOf<String, L2CapStreamDelegate>()


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
      scanResultListener.onScanError(errorCode)
    }

    override fun onScanResult(callbackType: Int, result: ScanResult) {
      scanResultListener.onScanResult(PlatformScanResult(
        name = result.scanRecord?.deviceName ?: "",
        deviceId = result.device.address,
        manufacturerDataHead = result.manufacturerDataHead ?: byteArrayOf(),
        manufacturerData = byteArrayOf(),
        rssi = result.rssi.toLong(),
        serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString() } ?: emptyList(),
      ))
    }

    override fun onBatchScanResults(results: MutableList<ScanResult>?) {
    }
  }

  private val gattCallback = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
      val gattStatus = when(status) {
        BluetoothGatt.GATT_SUCCESS -> PlatformGattStatus.SUCCESS
        BluetoothGatt.GATT_FAILURE -> PlatformGattStatus.FAILURE
        else -> PlatformGattStatus.FAILURE
      }
      val state = when(newState) {
        BluetoothGatt.STATE_CONNECTED -> PlatformConnectionState.CONNECTED
        BluetoothGatt.STATE_CONNECTING -> PlatformConnectionState.CONNECTING
        BluetoothGatt.STATE_DISCONNECTED -> PlatformConnectionState.DISCONNECTED
        BluetoothGatt.STATE_DISCONNECTING -> PlatformConnectionState.DISCONNECTING
        else -> PlatformConnectionState.UNKNOWN
      }

      // Clear out the connection if something bad happened.
      if (newState == BluetoothGatt.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
        cleanConnection(gatt)
      }

      mainThreadHandler.post {
        quickBlueFlutterApi?.onConnectionStateChange(PlatformConnectionStateChange(
          deviceId = gatt.device.address,
          state = state,
          gattStatus = gattStatus,
        )) {}
      }


      // If we've disconnected, ensure that we also close out the gatt.
      if (newState == BluetoothGatt.STATE_DISCONNECTED) {
        gatt.close()
      }
    }

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
      if (status != BluetoothGatt.GATT_SUCCESS) {
        return
      }

      mainThreadHandler.post {
        gatt.services?.forEach { service ->
          quickBlueFlutterApi?.onServiceDiscovered(
            PlatformServiceDiscovered(
            deviceId = gatt.device.address,
            serviceUuid = service.uuid.toString(),
            characteristics = service.characteristics.map { it.uuid.toString() }
          )) {}
        }
      }
    }

    override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
      if (status != BluetoothGatt.GATT_SUCCESS) {
        mtuChangedListener.onScanError(status)
        return
      }

      mtuChangedListener.onScanResult(PlatformMtuChange(
        deviceId = gatt.device.address,
        mtu = mtu.toLong(),
      ))
    }

    override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
      if (status != BluetoothGatt.GATT_SUCCESS) {
        return
      }
      mainThreadHandler.post {
        quickBlueFlutterApi?.onCharacteristicValueChanged(
          PlatformCharacteristicValueChanged(
            deviceId = gatt.device.address,
            characteristicId = characteristic.uuid.toString(),
            value = characteristic.value,
          )
        ) {}
      }
    }

    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
      mainThreadHandler.post {
        quickBlueFlutterApi?.onCharacteristicValueChanged(
          PlatformCharacteristicValueChanged(
            deviceId = gatt.device.address,
            characteristicId = characteristic.uuid.toString(),
            value = characteristic.value,
          )
        ) {}
      }
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic, status: Int) {
      // TODO(cg): send this as a message
    }
  }

  override fun isBluetoothAvailable(): Boolean {
    return bluetoothManager.adapter.isEnabled
  }

  override fun startScan(
    serviceUuids: List<String>?,
    manufacturerData: Map<Long, ByteArray>?
  ) {
    val filters = serviceUuids?.map {
      val builder = ScanFilter.Builder()
        .setServiceUuid(ParcelUuid.fromString(it))
      if (manufacturerData != null) {
        val id = manufacturerData.keys.first()
        val data = manufacturerData[id]
        builder.setManufacturerData(id.toInt(), data)
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
  }

  override fun stopScan() {
    bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)
  }

  override fun connect(deviceId: String) {
    if (knownGatts.find { it.device.address == deviceId } != null) {
      // Already connected
      return
    }
    val remoteDevice = bluetoothManager.adapter.getRemoteDevice(deviceId)
    connectDevice(remoteDevice)
  }

  override fun disconnect(deviceId: String) {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    cleanConnection(gatt)
  }

  override fun companionAssociate(
      deviceId: String?,
      serviceUuids: List<String>?,
      manufacturerData: Map<Long, ByteArray>?,
      callback: (kotlin.Result<PlatformCompanionDevice?>) -> Unit
  ) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      throw FlutterError("UnsupportedAndroidVersion", "Associating companion devices requires Android API 33 or higher", null)
    }

    val deviceFilter: BluetoothDeviceFilter = BluetoothDeviceFilter.Builder().let {
      if (deviceId != null) {
        it.setAddress(deviceId)
      }

      serviceUuids?.map { uuid ->
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
          callback(Result.success(PlatformCompanionDevice(
            associationInfo.deviceMacAddress.toString(), associationInfo.displayName.toString(), associationInfo.id.toLong(),
          )))
        }

        override fun onFailure(errorMessage: CharSequence?) {
          callback(Result.failure(FlutterError("AssociationFailed", errorMessage.toString(), null)))
        }
      }
    )
  }

  override fun companionDisassociate(associationId: Long) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      throw FlutterError("UnsupportedAndroidVersion", "Associating companion devices requires Android API 33 or higher", null)
    }
    companionDeviceManager.disassociate(associationId.toInt())
  }

  override fun getCompanionAssociations(): List<PlatformCompanionDevice> {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      throw FlutterError("UnsupportedAndroidVersion", "Associating companion devices requires Android API 33 or higher", null)
    }

    return companionDeviceManager.myAssociations.map {
      PlatformCompanionDevice(
        associationId = it.id.toLong(),
        id = it.deviceMacAddress.toString(),
        name = it.displayName.toString(),
      )
    }
  }

  override fun discoverServices(deviceId: String) {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    gatt.discoverServices()
  }

  override fun setNotifiable(
    deviceId: String,
    service: String,
    characteristic: String,
    bleInputProperty: PlatformBleInputProperty
  ) {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    gatt.setNotifiable(service to characteristic, bleInputProperty)  }

  override fun readValue(
    deviceId: String,
    service: String,
    characteristic: String
  ) {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    val readResult = gatt.getCharacteristic(service to characteristic)?.let {
      gatt.readCharacteristic(it)
    }
    if (readResult == true)
      return
    else
      throw FlutterError("Characteristic unavailable", null, null)
  }

  override fun writeValue(
    deviceId: String,
    service: String,
    characteristic: String,
    value: ByteArray,
    bleOutputProperty: PlatformBleOutputProperty
  ) {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    val writeResult = gatt.getCharacteristic(service to characteristic)?.let {
      it.value = value
      gatt.writeCharacteristic(it)
    }
    if (writeResult == true)
      return
    else
      throw FlutterError("Characteristic unavailable", null, null)
  }

  override fun requestMtu(deviceId: String, expectedMtu: Long): Long {
    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    gatt.requestMtu(expectedMtu.toInt())
    return 0
  }

  override fun openL2cap(deviceId: String, psm: Long, callback: (Result<Unit>) -> Unit) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      throw FlutterError("UnsupportedAndroidVersion", "L2CAP requires Android API 29 or higher", null)
    }

    val gatt = knownGatts.find { it.device.address == deviceId }
      ?: throw FlutterError("IllegalArgument", "Unknown deviceId: $deviceId", null)
    val socket = gatt.device.createInsecureL2capChannel(psm.toInt())
    val delegate = L2CapStreamDelegate(socket, openedCallback = {
      callback(Result.success(Unit))
    }, closedCallback =  {
      mainThreadHandler.post {
        l2CapSocketEventsListener.onScanResult(
          PlatformL2CapSocketEvent(
            deviceId = gatt.device.address,
            closed = true,
          )
        )
      }
    }, streamCallback =  {
      mainThreadHandler.post {
        l2CapSocketEventsListener.onScanResult(
          PlatformL2CapSocketEvent(
            deviceId = gatt.device.address,
            data = it,
          )
        )
      }
    }, errorCallback = {
      mainThreadHandler.post {
        l2CapSocketEventsListener.onScanResult(
          PlatformL2CapSocketEvent(
            deviceId = gatt.device.address,
            error = it.message ?: "",
          )
        )
      }
    })

    streamDelegates[gatt.device.address] = delegate
  }

  override fun closeL2cap(deviceId: String) {
    val delegate = streamDelegates[deviceId]
      ?: throw FlutterError("IllegalArgument", "No stream delegate for deviceId: $deviceId", null)
    delegate.close()
    streamDelegates.remove(deviceId)
  }

  override fun writeL2cap(deviceId: String, value: ByteArray) {
    val delegate = streamDelegates[deviceId]
      ?: throw FlutterError("IllegalArgument", "No stream delegate for deviceId: $deviceId", null)
    delegate.write(value)
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

fun BluetoothGatt.setNotifiable(serviceCharacteristic: Pair<String, String>, bleInputProperty: PlatformBleInputProperty) {
  val descriptor = getCharacteristic(serviceCharacteristic).getDescriptor(DESC__CLIENT_CHAR_CONFIGURATION)
  val (value, enable) = when (bleInputProperty) {
    PlatformBleInputProperty.NOTIFICATION -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE to true
    PlatformBleInputProperty.INDICATION -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE to true
    else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE to false
  }
  descriptor.value = value
  setCharacteristicNotification(descriptor.characteristic, enable) && writeDescriptor(descriptor)
}

class ScanResultListener : ScanResultsStreamHandler() {
  private var eventSink: PigeonEventSink<PlatformScanResult>? = null

  override fun onListen(p0: Any?, sink: PigeonEventSink<PlatformScanResult>) {
    eventSink = sink
  }

  fun onScanResult(result: PlatformScanResult) {
    eventSink?.success(result)
  }

  fun onScanError(errorCode: Int) {
    eventSink?.error("ScanError", "Error while scanning", errorCode)
  }

  fun onEventsDone() {
    eventSink?.endOfStream()
    eventSink = null
  }
}

class MtuChangedListener : MtuChangedStreamHandler() {
  private var eventSink: PigeonEventSink<PlatformMtuChange>? = null

  override fun onListen(p0: Any?, sink: PigeonEventSink<PlatformMtuChange>) {
    eventSink = sink
  }

  fun onScanResult(result: PlatformMtuChange) {
    eventSink?.success(result)
  }

  fun onScanError(errorCode: Int) {
    eventSink?.error("ScanError", "", errorCode)
  }

  fun onEventsDone() {
    eventSink?.endOfStream()
    eventSink = null
  }
}

class L2CapSocketEventsListener : L2CapSocketEventsStreamHandler() {
  private var eventSink: PigeonEventSink<PlatformL2CapSocketEvent>? = null

  override fun onListen(p0: Any?, sink: PigeonEventSink<PlatformL2CapSocketEvent>) {
    eventSink = sink
  }

  fun onScanResult(result: PlatformL2CapSocketEvent) {
    eventSink?.success(result)
  }

  fun onScanError(errorCode: Int) {
    eventSink?.error("ScanError", "", errorCode)
  }

  fun onEventsDone() {
    eventSink?.endOfStream()
    eventSink = null
  }
}