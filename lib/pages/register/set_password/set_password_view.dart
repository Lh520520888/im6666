import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';

import '../../../widgets/register_page_bg.dart';
import 'set_password_logic.dart';

class SetPasswordPage extends StatelessWidget {
  final logic = Get.find<SetPasswordLogic>();

  SetPasswordPage({super.key});

  @override
  Widget build(BuildContext context) => RegisterBgView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StrRes.setInfo.toText..style = Styles.ts_0089FF_22sp_semibold,
            29.verticalSpace,
            Center(
              child: Obx(() => GestureDetector(
                    onTap: () => logic.pickImage(),
                    child: Container(
                      width: 100.w,
                      height: 100.w,
                      decoration: BoxDecoration(
                        color: Styles.c_F0F2F6,
                        shape: BoxShape.circle,
                        image: logic.avatarPath.value != null
                            ? DecorationImage(
                                image: FileImage(File(logic.avatarPath.value!)),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: logic.avatarPath.value == null
                          ? Icon(
                              Icons.add_a_photo,
                              size: 40.sp,
                              color: Styles.c_8E9AB0,
                            )
                          : null,
                    ),
                  )),
            ),
            Center(
              child: Padding(
                padding: EdgeInsets.only(top: 8.h, bottom: 20.h),
                child: StrRes.tapToSetAvatar.toText
                  ..style = Styles.ts_8E9AB0_14sp,
              ),
            ),
            InputBox(
              label: StrRes.nickname,
              hintText: StrRes.plsEnterYourNickname,
              controller: logic.nicknameCtrl,
            ),
            17.verticalSpace,
            InputBox.password(
              label: StrRes.password,
              hintText: StrRes.plsEnterPassword,
              controller: logic.pwdCtrl,
              formatHintText: StrRes.loginPwdFormat,
              inputFormatters: [IMUtils.getPasswordFormatter()],
            ),
            17.verticalSpace,
            InputBox.password(
              label: StrRes.confirmPassword,
              hintText: StrRes.plsConfirmPasswordAgain,
              controller: logic.pwdAgainCtrl,
              inputFormatters: [IMUtils.getPasswordFormatter()],
            ),
            100.verticalSpace,
            Obx(() => Button(
                  text: StrRes.registerNow,
                  enabled: logic.enabled.value,
                  onTap: logic.nextStep,
                )),
          ],
        ),
      );
}
