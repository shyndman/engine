// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_EMBEDDER_TESTS_EMBEDDER_CONFIG_BUILDER_H_
#define FLUTTER_SHELL_PLATFORM_EMBEDDER_TESTS_EMBEDDER_CONFIG_BUILDER_H_

#include "flutter/fml/macros.h"
#include "flutter/fml/unique_object.h"
#include "flutter/shell/platform/embedder/embedder.h"
#include "flutter/shell/platform/embedder/tests/embedder_context.h"
#include "flutter/shell/platform/embedder/tests/embedder_test.h"

namespace flutter {
namespace testing {

struct UniqueEngineTraits {
  static FlutterEngine InvalidValue() { return nullptr; }

  static bool IsValid(const FlutterEngine& value) { return value != nullptr; }

  static void Free(FlutterEngine& engine) {
    auto result = FlutterEngineShutdown(engine);
    FML_CHECK(result == kSuccess);
  }
};

using UniqueEngine = fml::UniqueObject<FlutterEngine, UniqueEngineTraits>;

class EmbedderConfigBuilder {
 public:
  enum class InitializationPreference {
    kInitialize,
    kNoInitialize,
  };

  EmbedderConfigBuilder(EmbedderContext& context,
                        InitializationPreference preference =
                            InitializationPreference::kInitialize);

  ~EmbedderConfigBuilder();

  FlutterProjectArgs& GetProjectArgs();

  void SetSoftwareRendererConfig();

  void SetOpenGLRendererConfig();

  void SetAssetsPath();

  void SetSnapshots();

  void SetIsolateCreateCallbackHook();

  void SetSemanticsCallbackHooks();

  void SetDartEntrypoint(std::string entrypoint);

  void AddCommandLineArgument(std::string arg);

  void SetPlatformTaskRunner(const FlutterTaskRunnerDescription* runner);

  void SetPlatformMessageCallback(
      std::function<void(const FlutterPlatformMessage*)> callback);

  UniqueEngine LaunchEngine();

 private:
  EmbedderContext& context_;
  FlutterProjectArgs project_args_ = {};
  FlutterRendererConfig renderer_config_ = {};
  FlutterSoftwareRendererConfig software_renderer_config_ = {};
  FlutterOpenGLRendererConfig opengl_renderer_config_ = {};
  std::string dart_entrypoint_;
  FlutterCustomTaskRunners custom_task_runners_ = {};
  std::vector<std::string> command_line_arguments_;

  FML_DISALLOW_COPY_AND_ASSIGN(EmbedderConfigBuilder);
};

}  // namespace testing
}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_EMBEDDER_TESTS_EMBEDDER_CONFIG_BUILDER_H_
