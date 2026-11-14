#ifndef RUNNER_APP_AUTOSTART_H_
#define RUNNER_APP_AUTOSTART_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <windows.h>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterAutostartChannel(flutter::FlutterEngine* engine, HWND window);

#endif
