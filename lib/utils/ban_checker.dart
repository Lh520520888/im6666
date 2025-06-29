import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:openim_common/openim_common.dart';
import '../core/controller/app_controller.dart';
import '../core/controller/im_controller.dart';

class BanChecker {
  static const String _baseUrl = 'http://154.91.179.127'; // 替换为您的新后端地址
  static const String _apiToken = 'openim-admin-secret-key'; // 替换为您的API令牌
  static Timer? _periodicTimer;
  
  // 检查用户是否被封禁
  static Future<bool> checkBanStatus(String userID, {
    String? nickname,
    String? faceURL,
    String? phoneNumber,
    bool showDialog = true,
  }) async {
    try {
      // 获取用户信息，发送给新后端
      final userInfo = {
        'userID': userID,
        'nickname': nickname,
        'faceURL': faceURL,
        'phoneNumber': phoneNumber,
      };
      
      // 向新后端发送请求检查封禁状态
      final response = await http.post(
        Uri.parse('$_baseUrl/api/user/$userID/ban-status'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-token': _apiToken,
        },
        body: jsonEncode(userInfo),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final bool isBanned = data['banned'] == true;
        
        // 如果被封禁且需要显示弹窗
        if (isBanned && showDialog) {
          // 使用Get.dialog确保在任何页面都能显示
          Get.dialog(
            WillPopScope(
              onWillPop: () async => false, // 禁止返回键关闭
              child: AlertDialog(
                title: Text('账号已被封禁'),
                content: Text('您的账号已被管理员封禁。\n原因: ${data['reason'] ?? '违反用户协议'}'),
                actions: [
                  TextButton(
                    child: Text('确认'),
                    onPressed: () {
                      // 关闭对话框并退出登录
                      Get.back();
                      _logout();
                    },
                  ),
                ],
              ),
            ),
            barrierDismissible: false, // 禁止点击外部关闭
          );
        }
        
        return isBanned;
      }
      
      return false;
    } catch (e) {
      Logger.print('检查封禁状态出错: $e');
      return false;
    }
  }
  
  // 开始定期检查
  static void startPeriodicCheck(String userID, {
    String? nickname,
    String? faceURL,
    String? phoneNumber,
  }) {
    // 先停止已存在的定时器
    stopPeriodicCheck();
    
    // 创建新的定时器，每60秒检查一次
    _periodicTimer = Timer.periodic(Duration(seconds: 60), (timer) {
      checkBanStatus(
        userID,
        nickname: nickname,
        faceURL: faceURL,
        phoneNumber: phoneNumber,
      );
    });
    
    // 初始立即检查一次
    checkBanStatus(
      userID,
      nickname: nickname,
      faceURL: faceURL,
      phoneNumber: phoneNumber,
    );
  }
  
  // 停止定期检查
  static void stopPeriodicCheck() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }
  
  // 登出操作
  static void _logout() {
    try {
      // 停止定时检查
      stopPeriodicCheck();
      
      // 获取IM控制器并登出
      final imController = Get.find<IMController>();
      final appController = Get.find<AppController>();
      
      // 执行登出操作
      appController.logout();
    } catch (e) {
      Logger.print('登出出错: $e');
    }
  }
} 