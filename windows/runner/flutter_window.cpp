#include "flutter_window.h"

#include <optional>
#include <string>

#include <windows.h>

#include <mmdeviceapi.h>

#include "utils.h"

#include "flutter/generated_plugin_registrant.h"

namespace {

// 系统当前默认的播放（eRender）或录音（eCapture）设备的端点 ID，取不到时为空串。
// 通话用它在 WebRTC 枚举出的设备里找到系统默认的那个；主线程已初始化 COM。
std::string DefaultAudioEndpointId(EDataFlow flow) {
  std::string id;
  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator))) ||
      enumerator == nullptr) {
    return id;
  }
  IMMDevice* device = nullptr;
  if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(flow, eConsole, &device)) &&
      device != nullptr) {
    LPWSTR wide = nullptr;
    if (SUCCEEDED(device->GetId(&wide)) && wide != nullptr) {
      id = Utf8FromUtf16(wide);
      ::CoTaskMemFree(wide);
    }
    device->Release();
  }
  enumerator->Release();
  return id;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "whisper/desktop",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "flash") {
          HWND hwnd = GetHandle();
          if (hwnd != nullptr) {
            FLASHWINFO info = {};
            info.cbSize = sizeof(info);
            info.hwnd = hwnd;
            info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
            info.uCount = 8;
            info.dwTimeout = 0;
            ::FlashWindowEx(&info);
          }
          result->Success();
        } else if (call.method_name() == "defaultAudioDevices") {
          flutter::EncodableMap devices;
          devices[flutter::EncodableValue("output")] =
              flutter::EncodableValue(DefaultAudioEndpointId(eRender));
          devices[flutter::EncodableValue("input")] =
              flutter::EncodableValue(DefaultAudioEndpointId(eCapture));
          result->Success(flutter::EncodableValue(devices));
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 开机自启动（--hidden）：不显示窗口，只留托盘图标；用户从托盘点「显示」。
  bool start_hidden = false;
  for (const std::string& argument : project_.dart_entrypoint_arguments()) {
    if (argument == "--hidden") {
      start_hidden = true;
    }
  }
  flutter_controller_->engine()->SetNextFrameCallback([this, start_hidden]() {
    if (!start_hidden) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  desktop_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
