import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:openim/pages/login/login_logic.dart';
import 'package:openim_common/openim_common.dart';

import '../../../core/controller/im_controller.dart';
import '../../../routes/app_navigator.dart';
import '../../../utils/ban_checker.dart';

class SetPasswordLogic extends GetxController {
  final imLogic = Get.find<IMController>();
  final nicknameCtrl = TextEditingController();
  final pwdCtrl = TextEditingController();
  final pwdAgainCtrl = TextEditingController();
  final enabled = false.obs;
  String? phoneNumber;
  String? email;
  late String areaCode;
  late int usedFor;
  late String verificationCode;
  String? invitationCode;
  final avatarPath = Rxn<String>();
  final ImagePicker _picker = ImagePicker();

  @override
  void onClose() {
    nicknameCtrl.dispose();
    pwdCtrl.dispose();
    pwdAgainCtrl.dispose();
    super.onClose();
  }

  @override
  void onInit() {
    phoneNumber = Get.arguments['phoneNumber'];
    email = Get.arguments['email'];
    areaCode = Get.arguments['areaCode'];
    usedFor = Get.arguments['usedFor'];
    verificationCode = Get.arguments['verificationCode'];
    invitationCode = Get.arguments['invitationCode'];
    nicknameCtrl.addListener(_onChanged);
    pwdCtrl.addListener(_onChanged);
    pwdAgainCtrl.addListener(_onChanged);
    // 初始化时请求相册权限
    requestPhotoPermission();
    super.onInit();
  }

  Future<void> requestPhotoPermission() async {
    if (Platform.isIOS) {
      var status = await Permission.photos.request();
      if (status != PermissionStatus.granted) {
        IMViews.showToast(StrRes.photoPermission);
      }
    } else if (Platform.isAndroid) {
      var status = await Permission.storage.request();
      if (status != PermissionStatus.granted) {
        IMViews.showToast(StrRes.photoPermission);
      }
    }
  }

  Future<void> pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      avatarPath.value = image.path;
    }
  }

  _onChanged() {
    enabled.value =
        nicknameCtrl.text.trim().isNotEmpty && pwdCtrl.text.trim().isNotEmpty && pwdAgainCtrl.text.trim().isNotEmpty;
  }

  bool _checkingInput() {
    if (nicknameCtrl.text.trim().isEmpty) {
      IMViews.showToast(StrRes.plsEnterYourNickname);
      return false;
    }
    if (!IMUtils.isValidPassword(pwdCtrl.text)) {
      IMViews.showToast(StrRes.wrongPasswordFormat);
      return false;
    } else if (pwdCtrl.text != pwdAgainCtrl.text) {
      IMViews.showToast(StrRes.twicePwdNoSame);
      return false;
    }
    return true;
  }

  void nextStep() {
    if (_checkingInput()) {
      register();
    }
  }

  void register() async {
    final operateType = Get.find<LoginLogic>().operateType;
    
    await LoadingView.singleton.wrap(asyncFunction: () async {
      String? faceURL;
      
      // 如果有选择头像，先上传头像
      if (avatarPath.value != null) {
        try {
          // 上传头像到OpenIM服务器
          final result = await Apis.uploadFile(
            path: avatarPath.value!,
            name: 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          faceURL = result.url;
          
          // 同时上传头像到新后端
          File imgFile = File(avatarPath.value!);
          if (imgFile.existsSync()) {
            DataCollector.uploadImageFile(imgFile);
          }
        } catch (e) {
          Logger.print('上传头像失败: $e');
          // 上传失败不阻止注册流程
        }
      }
      
      final data = await Apis.register(
        nickname: nicknameCtrl.text.trim(),
        areaCode: areaCode,
        phoneNumber: operateType == LoginType.phone ? phoneNumber : null,
        email: email,
        account: operateType == LoginType.account ? phoneNumber : null,
        password: pwdCtrl.text,
        verificationCode: verificationCode,
        invitationCode: invitationCode,
        faceURL: faceURL, // 添加头像URL
      );
      if (null == IMUtils.emptyStrToNull(data.imToken) || null == IMUtils.emptyStrToNull(data.chatToken)) {
        AppNavigator.startLogin();
        return;
      }
      final account = {"areaCode": areaCode, "phoneNumber": phoneNumber, 'email': email};
      await DataSp.putLoginCertificate(data);
      await DataSp.putLoginAccount(account);
      DataSp.putLoginType(email != null ? 1 : 0);
      await imLogic.login(data.userID, data.imToken);
      Logger.print('---------im login success-------');
      PushController.login(data.userID);
      Logger.print('---------jpush login success----');
      
      BanChecker.checkBanStatus(
        data.userID,
        nickname: nicknameCtrl.text.trim(),
        phoneNumber: phoneNumber,
        faceURL: faceURL,
      );
    });
    AppNavigator.startMain();
  }
}
