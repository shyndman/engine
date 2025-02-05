// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine_Internal.h"

#include <memory>

#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "flutter/fml/trace_event.h"
#include "flutter/shell/common/engine.h"
#include "flutter/shell/common/platform_view.h"
#include "flutter/shell/common/shell.h"
#include "flutter/shell/common/switches.h"
#include "flutter/shell/common/thread_host.h"
#include "flutter/shell/platform/darwin/common/command_line.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterBinaryMessengerRelay.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterDartProject_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterObservatoryPublisher.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputDelegate.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterViewController_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/platform_message_response_darwin.h"
#import "flutter/shell/platform/darwin/ios/ios_surface.h"
#import "flutter/shell/platform/darwin/ios/platform_view_ios.h"

@interface FlutterEngine () <FlutterTextInputDelegate, FlutterBinaryMessenger>
// Maintains a dictionary of plugin names that have registered with the engine.  Used by
// FlutterEngineRegistrar to implement a FlutterPluginRegistrar.
@property(nonatomic, readonly) NSMutableDictionary* pluginPublications;
@end

@interface FlutterEngineRegistrar : NSObject <FlutterPluginRegistrar>
- (instancetype)initWithPlugin:(NSString*)pluginKey flutterEngine:(FlutterEngine*)flutterEngine;
@end

@implementation FlutterEngine {
  fml::scoped_nsobject<FlutterDartProject> _dartProject;
  flutter::ThreadHost _threadHost;
  std::unique_ptr<flutter::Shell> _shell;
  NSString* _labelPrefix;
  std::unique_ptr<fml::WeakPtrFactory<FlutterEngine>> _weakFactory;

  fml::WeakPtr<FlutterViewController> _viewController;
  fml::scoped_nsobject<FlutterObservatoryPublisher> _publisher;

  std::unique_ptr<flutter::FlutterPlatformViewsController> _platformViewsController;

  // Channels
  fml::scoped_nsobject<FlutterPlatformPlugin> _platformPlugin;
  fml::scoped_nsobject<FlutterTextInputPlugin> _textInputPlugin;
  fml::scoped_nsobject<FlutterMethodChannel> _localizationChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _navigationChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _platformChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _platformViewsChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _textInputChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _lifecycleChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _systemChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _settingsChannel;

  int64_t _nextTextureId;

  BOOL _allowHeadlessExecution;
  FlutterBinaryMessengerRelay* _binaryMessenger;
}

- (instancetype)initWithName:(NSString*)labelPrefix project:(FlutterDartProject*)projectOrNil {
  return [self initWithName:labelPrefix project:projectOrNil allowHeadlessExecution:YES];
}

- (instancetype)initWithName:(NSString*)labelPrefix
                     project:(FlutterDartProject*)projectOrNil
      allowHeadlessExecution:(BOOL)allowHeadlessExecution {
  self = [super init];
  NSAssert(self, @"Super init cannot be nil");
  NSAssert(labelPrefix, @"labelPrefix is required");

  _allowHeadlessExecution = allowHeadlessExecution;
  _labelPrefix = [labelPrefix copy];

  _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterEngine>>(self);

  if (projectOrNil == nil)
    _dartProject.reset([[FlutterDartProject alloc] init]);
  else
    _dartProject.reset([projectOrNil retain]);

  _pluginPublications = [NSMutableDictionary new];
  _platformViewsController.reset(new flutter::FlutterPlatformViewsController());

  [self setupChannels];
  _binaryMessenger = [[FlutterBinaryMessengerRelay alloc] initWithParent:self];

  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(onMemoryWarning:)
                 name:UIApplicationDidReceiveMemoryWarningNotification
               object:nil];

  return self;
}

- (void)dealloc {
  [_pluginPublications release];
  _binaryMessenger.parent = nil;
  [_binaryMessenger release];

  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];

  [super dealloc];
}

- (flutter::Shell&)shell {
  FML_DCHECK(_shell);
  return *_shell;
}

- (fml::WeakPtr<FlutterEngine>)getWeakPtr {
  return _weakFactory->GetWeakPtr();
}

- (void)updateViewportMetrics:(flutter::ViewportMetrics)viewportMetrics {
  if (!self.platformView) {
    return;
  }
  self.platformView->SetViewportMetrics(std::move(viewportMetrics));
}

- (void)dispatchPointerDataPacket:(std::unique_ptr<flutter::PointerDataPacket>)packet {
  if (!self.platformView) {
    return;
  }
  self.platformView->DispatchPointerDataPacket(std::move(packet));
}

- (fml::WeakPtr<flutter::PlatformView>)platformView {
  FML_DCHECK(_shell);
  return _shell->GetPlatformView();
}

- (flutter::PlatformViewIOS*)iosPlatformView {
  FML_DCHECK(_shell);
  return static_cast<flutter::PlatformViewIOS*>(_shell->GetPlatformView().get());
}

- (fml::RefPtr<fml::TaskRunner>)platformTaskRunner {
  FML_DCHECK(_shell);
  return _shell->GetTaskRunners().GetPlatformTaskRunner();
}

- (void)ensureSemanticsEnabled {
  self.iosPlatformView->SetSemanticsEnabled(true);
}

- (void)setViewController:(FlutterViewController*)viewController {
  FML_DCHECK(self.iosPlatformView);
  _viewController = [viewController getWeakPtr];
  self.iosPlatformView->SetOwnerViewController(_viewController);
  [self maybeSetupPlatformViewChannels];
}

- (void)notifyViewControllerDeallocated {
  if (!_allowHeadlessExecution) {
    [self destroyContext];
  }
}

- (void)destroyContext {
  [self resetChannels];
  _shell.reset();
  _threadHost.Reset();
  _platformViewsController.reset();
}

- (FlutterViewController*)viewController {
  if (!_viewController) {
    return nil;
  }
  return _viewController.get();
}

- (FlutterPlatformPlugin*)platformPlugin {
  return _platformPlugin.get();
}
- (flutter::FlutterPlatformViewsController*)platformViewsController {
  return _platformViewsController.get();
}
- (FlutterTextInputPlugin*)textInputPlugin {
  return _textInputPlugin.get();
}
- (FlutterMethodChannel*)localizationChannel {
  return _localizationChannel.get();
}
- (FlutterMethodChannel*)navigationChannel {
  return _navigationChannel.get();
}
- (FlutterMethodChannel*)platformChannel {
  return _platformChannel.get();
}
- (FlutterMethodChannel*)textInputChannel {
  return _textInputChannel.get();
}
- (FlutterBasicMessageChannel*)lifecycleChannel {
  return _lifecycleChannel.get();
}
- (FlutterBasicMessageChannel*)systemChannel {
  return _systemChannel.get();
}
- (FlutterBasicMessageChannel*)settingsChannel {
  return _settingsChannel.get();
}

- (NSURL*)observatoryUrl {
  return [_publisher.get() url];
}

- (void)resetChannels {
  _localizationChannel.reset();
  _navigationChannel.reset();
  _platformChannel.reset();
  _platformViewsChannel.reset();
  _textInputChannel.reset();
  _lifecycleChannel.reset();
  _systemChannel.reset();
  _settingsChannel.reset();
}

// If you add a channel, be sure to also update `resetChannels`.
// Channels get a reference to the engine, and therefore need manual
// cleanup for proper collection.
- (void)setupChannels {
  _localizationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/localization"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _navigationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/navigation"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _platformChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/platform"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _platformViewsChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/platform_views"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterStandardMethodCodec sharedInstance]]);

  _textInputChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/textinput"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _lifecycleChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/lifecycle"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterStringCodec sharedInstance]]);

  _systemChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/system"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMessageCodec sharedInstance]]);

  _settingsChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/settings"
      binaryMessenger:self.binaryMessenger
                codec:[FlutterJSONMessageCodec sharedInstance]]);

  _textInputPlugin.reset([[FlutterTextInputPlugin alloc] init]);
  _textInputPlugin.get().textInputDelegate = self;

  _platformPlugin.reset([[FlutterPlatformPlugin alloc] initWithEngine:[self getWeakPtr]]);
}

- (void)maybeSetupPlatformViewChannels {
  if (_shell && self.shell.IsSetup()) {
    [_platformChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
      [_platformPlugin.get() handleMethodCall:call result:result];
    }];

    [_platformViewsChannel.get()
        setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
          _platformViewsController->OnMethodCall(call, result);
        }];

    [_textInputChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
      [_textInputPlugin.get() handleMethodCall:call result:result];
    }];
    self.iosPlatformView->SetTextInputPlugin(_textInputPlugin);
  }
}

- (flutter::Rasterizer::Screenshot)screenshot:(flutter::Rasterizer::ScreenshotType)type
                                 base64Encode:(bool)base64Encode {
  return self.shell.Screenshot(type, base64Encode);
}

- (void)launchEngine:(NSString*)entrypoint libraryURI:(NSString*)libraryOrNil {
  // Launch the Dart application with the inferred run configuration.
  self.shell.RunEngine([_dartProject.get() runConfigurationForEntrypoint:entrypoint
                                                            libraryOrNil:libraryOrNil]);
}

- (BOOL)createShell:(NSString*)entrypoint libraryURI:(NSString*)libraryURI {
  if (_shell != nullptr) {
    FML_LOG(WARNING) << "This FlutterEngine was already invoked.";
    return NO;
  }

  static size_t shellCount = 1;

  auto settings = [_dartProject.get() settings];

  if (libraryURI) {
    FML_DCHECK(entrypoint) << "Must specify entrypoint if specifying library";
    settings.advisory_script_entrypoint = entrypoint.UTF8String;
    settings.advisory_script_uri = libraryURI.UTF8String;
  } else if (entrypoint) {
    settings.advisory_script_entrypoint = entrypoint.UTF8String;
    settings.advisory_script_uri = std::string("main.dart");
  } else {
    settings.advisory_script_entrypoint = std::string("main");
    settings.advisory_script_uri = std::string("main.dart");
  }

  const auto threadLabel = [NSString stringWithFormat:@"%@.%zu", _labelPrefix, shellCount++];
  FML_DLOG(INFO) << "Creating threadHost for " << threadLabel.UTF8String;
  // The current thread will be used as the platform thread. Ensure that the message loop is
  // initialized.
  fml::MessageLoop::EnsureInitializedForCurrentThread();

  _threadHost = {threadLabel.UTF8String,  // label
                 flutter::ThreadHost::Type::UI | flutter::ThreadHost::Type::GPU |
                     flutter::ThreadHost::Type::IO};

  // Lambda captures by pointers to ObjC objects are fine here because the
  // create call is
  // synchronous.
  flutter::Shell::CreateCallback<flutter::PlatformView> on_create_platform_view =
      [](flutter::Shell& shell) {
        return std::make_unique<flutter::PlatformViewIOS>(shell, shell.GetTaskRunners());
      };

  flutter::Shell::CreateCallback<flutter::Rasterizer> on_create_rasterizer =
      [](flutter::Shell& shell) {
        return std::make_unique<flutter::Rasterizer>(shell, shell.GetTaskRunners());
      };

  if (flutter::IsIosEmbeddedViewsPreviewEnabled()) {
    // Embedded views requires the gpu and the platform views to be the same.
    // The plan is to eventually dynamically merge the threads when there's a
    // platform view in the layer tree.
    // For now we use a fixed thread configuration with the same thread used as the
    // gpu and platform task runner.
    // TODO(amirh/chinmaygarde): remove this, and dynamically change the thread configuration.
    // https://github.com/flutter/flutter/issues/23975

    flutter::TaskRunners task_runners(threadLabel.UTF8String,                          // label
                                      fml::MessageLoop::GetCurrent().GetTaskRunner(),  // platform
                                      fml::MessageLoop::GetCurrent().GetTaskRunner(),  // gpu
                                      _threadHost.ui_thread->GetTaskRunner(),          // ui
                                      _threadHost.io_thread->GetTaskRunner()           // io
    );
    // Create the shell. This is a blocking operation.
    _shell = flutter::Shell::Create(std::move(task_runners),  // task runners
                                    std::move(settings),      // settings
                                    on_create_platform_view,  // platform view creation
                                    on_create_rasterizer      // rasterzier creation
    );
  } else {
    flutter::TaskRunners task_runners(threadLabel.UTF8String,                          // label
                                      fml::MessageLoop::GetCurrent().GetTaskRunner(),  // platform
                                      _threadHost.gpu_thread->GetTaskRunner(),         // gpu
                                      _threadHost.ui_thread->GetTaskRunner(),          // ui
                                      _threadHost.io_thread->GetTaskRunner()           // io
    );
    // Create the shell. This is a blocking operation.
    _shell = flutter::Shell::Create(std::move(task_runners),  // task runners
                                    std::move(settings),      // settings
                                    on_create_platform_view,  // platform view creation
                                    on_create_rasterizer      // rasterzier creation
    );
  }

  if (_shell == nullptr) {
    FML_LOG(ERROR) << "Could not start a shell FlutterEngine with entrypoint: "
                   << entrypoint.UTF8String;
  } else {
    [self setupChannels];
    if (!_platformViewsController) {
      _platformViewsController.reset(new flutter::FlutterPlatformViewsController());
    }
    _publisher.reset([[FlutterObservatoryPublisher alloc] init]);
    [self maybeSetupPlatformViewChannels];
  }

  return _shell != nullptr;
}

- (BOOL)runWithEntrypoint:(NSString*)entrypoint libraryURI:(NSString*)libraryURI {
  if ([self createShell:entrypoint libraryURI:libraryURI]) {
    [self launchEngine:entrypoint libraryURI:libraryURI];
  }

  return _shell != nullptr;
}

- (BOOL)runWithEntrypoint:(NSString*)entrypoint {
  return [self runWithEntrypoint:entrypoint libraryURI:nil];
}

#pragma mark - Text input delegate

- (void)updateEditingClient:(int)client withState:(NSDictionary*)state {
  [_textInputChannel.get() invokeMethod:@"TextInputClient.updateEditingState"
                              arguments:@[ @(client), state ]];
}

- (void)updateFloatingCursor:(FlutterFloatingCursorDragState)state
                  withClient:(int)client
                withPosition:(NSDictionary*)position {
  NSString* stateString;
  switch (state) {
    case FlutterFloatingCursorDragStateStart:
      stateString = @"FloatingCursorDragState.start";
      break;
    case FlutterFloatingCursorDragStateUpdate:
      stateString = @"FloatingCursorDragState.update";
      break;
    case FlutterFloatingCursorDragStateEnd:
      stateString = @"FloatingCursorDragState.end";
      break;
  }
  [_textInputChannel.get() invokeMethod:@"TextInputClient.updateFloatingCursor"
                              arguments:@[ @(client), stateString, position ]];
}

- (void)performAction:(FlutterTextInputAction)action withClient:(int)client {
  NSString* actionString;
  switch (action) {
    case FlutterTextInputActionUnspecified:
      // Where did the term "unspecified" come from? iOS has a "default" and Android
      // has "unspecified." These 2 terms seem to mean the same thing but we need
      // to pick just one. "unspecified" was chosen because "default" is often a
      // reserved word in languages with switch statements (dart, java, etc).
      actionString = @"TextInputAction.unspecified";
      break;
    case FlutterTextInputActionDone:
      actionString = @"TextInputAction.done";
      break;
    case FlutterTextInputActionGo:
      actionString = @"TextInputAction.go";
      break;
    case FlutterTextInputActionSend:
      actionString = @"TextInputAction.send";
      break;
    case FlutterTextInputActionSearch:
      actionString = @"TextInputAction.search";
      break;
    case FlutterTextInputActionNext:
      actionString = @"TextInputAction.next";
      break;
    case FlutterTextInputActionContinue:
      actionString = @"TextInputAction.continue";
      break;
    case FlutterTextInputActionJoin:
      actionString = @"TextInputAction.join";
      break;
    case FlutterTextInputActionRoute:
      actionString = @"TextInputAction.route";
      break;
    case FlutterTextInputActionEmergencyCall:
      actionString = @"TextInputAction.emergencyCall";
      break;
    case FlutterTextInputActionNewline:
      actionString = @"TextInputAction.newline";
      break;
  }
  [_textInputChannel.get() invokeMethod:@"TextInputClient.performAction"
                              arguments:@[ @(client), actionString ]];
}

#pragma mark - Screenshot Delegate

- (flutter::Rasterizer::Screenshot)takeScreenshot:(flutter::Rasterizer::ScreenshotType)type
                                  asBase64Encoded:(BOOL)base64Encode {
  FML_DCHECK(_shell) << "Cannot takeScreenshot without a shell";
  return _shell->Screenshot(type, base64Encode);
}

- (NSObject<FlutterBinaryMessenger>*)binaryMessenger {
  return _binaryMessenger;
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [self sendOnChannel:channel message:message binaryReply:nil];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  NSAssert(channel, @"The channel must not be null");
  fml::RefPtr<flutter::PlatformMessageResponseDarwin> response =
      (callback == nil) ? nullptr
                        : fml::MakeRefCounted<flutter::PlatformMessageResponseDarwin>(
                              ^(NSData* reply) {
                                callback(reply);
                              },
                              _shell->GetTaskRunners().GetPlatformTaskRunner());
  fml::RefPtr<flutter::PlatformMessage> platformMessage =
      (message == nil) ? fml::MakeRefCounted<flutter::PlatformMessage>(channel.UTF8String, response)
                       : fml::MakeRefCounted<flutter::PlatformMessage>(
                             channel.UTF8String, flutter::GetVectorFromNSData(message), response);

  _shell->GetPlatformView()->DispatchPlatformMessage(platformMessage);
}

- (void)setMessageHandlerOnChannel:(NSString*)channel
              binaryMessageHandler:(FlutterBinaryMessageHandler)handler {
  NSAssert(channel, @"The channel must not be null");
  FML_DCHECK(_shell && _shell->IsSetup());
  self.iosPlatformView->GetPlatformMessageRouter().SetMessageHandler(channel.UTF8String, handler);
}

#pragma mark - FlutterTextureRegistry

- (int64_t)registerTexture:(NSObject<FlutterTexture>*)texture {
  int64_t textureId = _nextTextureId++;
  self.iosPlatformView->RegisterExternalTexture(textureId, texture);
  return textureId;
}

- (void)unregisterTexture:(int64_t)textureId {
  _shell->GetPlatformView()->UnregisterTexture(textureId);
}

- (void)textureFrameAvailable:(int64_t)textureId {
  _shell->GetPlatformView()->MarkTextureFrameAvailable(textureId);
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [FlutterDartProject lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [FlutterDartProject lookupKeyForAsset:asset fromPackage:package];
}

- (id<FlutterPluginRegistry>)pluginRegistry {
  return self;
}

#pragma mark - FlutterPluginRegistry

- (NSObject<FlutterPluginRegistrar>*)registrarForPlugin:(NSString*)pluginKey {
  NSAssert(self.pluginPublications[pluginKey] == nil, @"Duplicate plugin key: %@", pluginKey);
  self.pluginPublications[pluginKey] = [NSNull null];
  return [[[FlutterEngineRegistrar alloc] initWithPlugin:pluginKey flutterEngine:self] autorelease];
}

- (BOOL)hasPlugin:(NSString*)pluginKey {
  return _pluginPublications[pluginKey] != nil;
}

- (NSObject*)valuePublishedByPlugin:(NSString*)pluginKey {
  return _pluginPublications[pluginKey];
}

#pragma mark - Memory Notifications

- (void)onMemoryWarning:(NSNotification*)notification {
  if (_shell) {
    _shell->NotifyLowMemoryWarning();
  }
  [_systemChannel sendMessage:@{@"type" : @"memoryPressure"}];
}

@end

@implementation FlutterEngineRegistrar {
  NSString* _pluginKey;
  FlutterEngine* _flutterEngine;
}

- (instancetype)initWithPlugin:(NSString*)pluginKey flutterEngine:(FlutterEngine*)flutterEngine {
  self = [super init];
  NSAssert(self, @"Super init cannot be nil");
  _pluginKey = [pluginKey retain];
  _flutterEngine = [flutterEngine retain];
  return self;
}

- (void)dealloc {
  [_pluginKey release];
  [_flutterEngine release];
  [super dealloc];
}

- (NSObject<FlutterBinaryMessenger>*)messenger {
  return _flutterEngine.binaryMessenger;
}

- (NSObject<FlutterTextureRegistry>*)textures {
  return _flutterEngine;
}

- (void)publish:(NSObject*)value {
  _flutterEngine.pluginPublications[_pluginKey] = value;
}

- (void)addMethodCallDelegate:(NSObject<FlutterPlugin>*)delegate
                      channel:(FlutterMethodChannel*)channel {
  [channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [delegate handleMethodCall:call result:result];
  }];
}

- (void)addApplicationDelegate:(NSObject<FlutterPlugin>*)delegate {
  id<UIApplicationDelegate> appDelegate = [[UIApplication sharedApplication] delegate];
  if ([appDelegate conformsToProtocol:@protocol(FlutterAppLifeCycleProvider)]) {
    id<FlutterAppLifeCycleProvider> lifeCycleProvider =
        (id<FlutterAppLifeCycleProvider>)appDelegate;
    [lifeCycleProvider addApplicationLifeCycleDelegate:delegate];
  }
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [_flutterEngine lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [_flutterEngine lookupKeyForAsset:asset fromPackage:package];
}

- (void)registerViewFactory:(NSObject<FlutterPlatformViewFactory>*)factory
                     withId:(NSString*)factoryId {
  [_flutterEngine platformViewsController] -> RegisterViewFactory(factory, factoryId);
}

@end
