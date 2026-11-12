/// 当前窗口和打开的会话，供来信提示音判断是否该响。
library;

class UiFocus {
  /// 正在看的会话；在联系人列表或不在聊天页时为 null。
  String? visibleSessionId;

  /// 应用窗口是否在前台。由 [CallHost] 根据生命周期更新。
  bool windowFocused = true;

  void enterSession(String sessionId) => visibleSessionId = sessionId;

  void leaveSession(String sessionId) {
    if (visibleSessionId == sessionId) visibleSessionId = null;
  }
}
