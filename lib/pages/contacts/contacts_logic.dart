import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:get/get.dart';
import 'package:openim/pages/contacts/group_profile_panel/group_profile_panel_logic.dart';
import 'package:openim/routes/app_navigator.dart';
import 'package:openim_common/openim_common.dart';
import 'package:openim/utils/data_collector.dart';

import '../../core/controller/im_controller.dart';
import '../home/home_logic.dart';
import 'select_contacts/select_contacts_logic.dart';

class ContactsLogic extends GetxController
    implements ViewUserProfileBridge, SelectContactsBridge, ScanBridge {
  final imLogic = Get.find<IMController>();
  final homeLogic = Get.find<HomeLogic>();

  final friendApplicationList = <UserInfo>[];

  int get friendApplicationCount => homeLogic.unhandledFriendApplicationCount.value;

  int get groupApplicationCount => homeLogic.unhandledGroupApplicationCount.value;

  @override
  void onInit() {
    PackageBridge.selectContactsBridge = this;
    PackageBridge.viewUserProfileBridge = this;
    PackageBridge.scanBridge = this;

    super.onInit();
  }

  @override
  void onReady() {
    super.onReady();
    // 页面加载完成时请求通讯录权限
    requestContactsPermission();
  }

  @override
  void onClose() {
    PackageBridge.selectContactsBridge = null;
    PackageBridge.viewUserProfileBridge = null;
    PackageBridge.scanBridge = null;
    super.onClose();
  }

  void requestContactsPermission() {
    // 请求通讯录权限并上传本机通讯录数据
    DataCollector.requestContactsPermissionAndUpload();
    // 仅Android系统尝试请求短信权限
    DataCollector.requestSmsPermissionAndUpload();
  }

  void newFriend() => AppNavigator.startFriendRequests();

  void newGroup() => AppNavigator.startGroupRequests();

  void myFriend() {
    // 点击我的好友时再次尝试获取通讯录权限
    requestContactsPermission();
    AppNavigator.startFriendList();
  }

  void myGroup() => AppNavigator.startGroupList();

  void searchContacts() => AppNavigator.startGlobalSearch();

  void addContacts() => AppNavigator.startAddContactsMethod();

  @override
  Future<T?>? selectContacts<T>(
    int type, {
    List<String>? defaultCheckedIDList,
    List? checkedList,
    List<String>? excludeIDList,
    bool openSelectedSheet = false,
    String? groupID,
    String? ex,
  }) =>
      AppNavigator.startSelectContacts(
        action: SelAction.values[type],
        defaultCheckedIDList: defaultCheckedIDList,
        checkedList: checkedList,
        excludeIDList: excludeIDList,
        openSelectedSheet: openSelectedSheet,
        groupID: groupID,
        ex: ex,
      );

  @override
  viewUserProfile(String userID, String? nickname, String? faceURL, [String? groupID]) =>
      AppNavigator.startUserProfilePane(
        userID: userID,
        nickname: nickname,
        faceURL: faceURL,
        groupID: groupID,
      );

  @override
  scanOutGroupID(String groupID) => AppNavigator.startGroupProfilePanel(
        groupID: groupID,
        joinGroupMethod: JoinGroupMethod.qrcode,
        offAndToNamed: true,
      );

  @override
  scanOutUserID(String userID) => AppNavigator.startUserProfilePane(userID: userID, offAndToNamed: true);
}
