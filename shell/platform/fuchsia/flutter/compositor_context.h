// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_FUCHSIA_COMPOSITOR_CONTEXT_H_
#define FLUTTER_SHELL_PLATFORM_FUCHSIA_COMPOSITOR_CONTEXT_H_

#include <fuchsia/ui/scenic/cpp/fidl.h>
#include <fuchsia/ui/views/cpp/fidl.h>
#include <lib/fit/function.h>

#include "flutter/flow/compositor_context.h"
#include "flutter/flow/embedded_views.h"
#include "flutter/fml/macros.h"
#include "session_connection.h"

namespace flutter_runner {

// Holds composition specific state and bindings specific to composition on
// Fuchsia.
class CompositorContext final : public flutter::CompositorContext {
 public:
  CompositorContext(std::string debug_label,
                    fuchsia::ui::views::ViewToken view_token,
                    fidl::InterfaceHandle<fuchsia::ui::scenic::Session> session,
                    fml::closure session_error_callback,
                    zx_handle_t vsync_event_handle);

  ~CompositorContext() override;

  void OnSessionMetricsDidChange(const fuchsia::ui::gfx::Metrics& metrics);
  void OnSessionSizeChangeHint(float width_change_factor,
                               float height_change_factor);

 private:
  const std::string debug_label_;
  SessionConnection session_connection_;

  // |flutter::CompositorContext|
  std::unique_ptr<ScopedFrame> AcquireFrame(
      GrContext* gr_context,
      SkCanvas* canvas,
      flutter::ExternalViewEmbedder* view_embedder,
      const SkMatrix& root_surface_transformation,
      bool instrumentation_enabled) override;

  FML_DISALLOW_COPY_AND_ASSIGN(CompositorContext);
};

}  // namespace flutter_runner

#endif  // FLUTTER_SHELL_PLATFORM_FUCHSIA_COMPOSITOR_CONTEXT_H_
