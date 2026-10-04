#include "flutter_window.h"

#include <optional>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

// Keeps the "rcb/window_chrome" channel alive for the life of the process.
// The project chat's own window (a second copy of this .exe) uses it to set
// its title and size and to bring itself forward.
static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_window_chrome;

static int ReadInt(const flutter::EncodableValue& v) {
  if (const auto* i = std::get_if<int32_t>(&v)) return *i;
  if (const auto* l = std::get_if<int64_t>(&v)) return static_cast<int>(*l);
  if (const auto* d = std::get_if<double>(&v)) return static_cast<int>(*d);
  return 0;
}

static void SetupWindowChrome(flutter::FlutterEngine* engine,
                              flutter::FlutterView* view) {
  g_window_chrome =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          engine->messenger(), "rcb/window_chrome",
          &flutter::StandardMethodCodec::GetInstance());
  g_window_chrome->SetMethodCallHandler(
      [view](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd =
            view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
        if (call.method_name() == "focus") {
          if (hwnd) {
            if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
          }
          result->Success();
          return;
        }
        if (call.method_name() != "setChrome") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (hwnd && args) {
          auto t = args->find(flutter::EncodableValue("title"));
          if (t != args->end()) {
            if (const auto* s = std::get_if<std::string>(&t->second)) {
              int len = MultiByteToWideChar(CP_UTF8, 0, s->c_str(), -1,
                                            nullptr, 0);
              if (len > 0) {
                std::wstring w(len, L'\0');
                MultiByteToWideChar(CP_UTF8, 0, s->c_str(), -1, &w[0], len);
                SetWindowTextW(hwnd, w.c_str());
              }
            }
          }
          auto wv = args->find(flutter::EncodableValue("width"));
          auto hv = args->find(flutter::EncodableValue("height"));
          if (wv != args->end() && hv != args->end()) {
            const double scale = GetDpiForWindow(hwnd) / 96.0;
            int pw = static_cast<int>(ReadInt(wv->second) * scale);
            int ph = static_cast<int>(ReadInt(hv->second) * scale);
            HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            MONITORINFO mi;
            mi.cbSize = sizeof(mi);
            int x = 100, y = 100;
            if (GetMonitorInfo(mon, &mi)) {
              const int ww = mi.rcWork.right - mi.rcWork.left;
              const int wh = mi.rcWork.bottom - mi.rcWork.top;
              if (pw > ww) pw = ww;
              if (ph > wh) ph = wh;
              // Toward the right of the screen, where a chat usually sits.
              x = mi.rcWork.right - pw - 24;
              y = mi.rcWork.top + (wh - ph) / 2;
            }
            if (pw > 0 && ph > 0) {
              SetWindowPos(hwnd, nullptr, x, y, pw, ph,
                           SWP_NOZORDER | SWP_NOACTIVATE);
            }
          }
        }
        result->Success();
      });
}

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
  SetupWindowChrome(flutter_controller_->engine(),
                    flutter_controller_->view());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
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
