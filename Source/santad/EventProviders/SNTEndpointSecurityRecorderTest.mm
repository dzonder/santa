/// Copyright 2022 Google Inc. All rights reserved.
/// Copyright 2024 North Pole Security, Inc.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///     http://www.apache.org/licenses/LICENSE-2.0
///
/// Unless required by applicable law or agreed to in writing, software
/// distributed under the License is distributed on an "AS IS" BASIS,
/// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
/// See the License for the specific language governing permissions and
/// limitations under the License.

#include <EndpointSecurity/ESTypes.h>
#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <objc/NSObjCRuntime.h>
#include <cstddef>

#include <memory>
#include <set>

#include "Source/common/Platform.h"
#include "Source/common/PrefixTree.h"
#import "Source/common/SNTConfigurator.h"
#include "Source/common/TelemetryEventMap.h"
#include "Source/common/TestUtils.h"
#include "Source/common/Unit.h"
#import "Source/santad/EventProviders/AuthResultCache.h"
#include "Source/santad/EventProviders/EndpointSecurity/Client.h"
#include "Source/santad/EventProviders/EndpointSecurity/EnrichedTypes.h"
#include "Source/santad/EventProviders/EndpointSecurity/Enricher.h"
#include "Source/santad/EventProviders/EndpointSecurity/Message.h"
#include "Source/santad/EventProviders/EndpointSecurity/MockEndpointSecurityAPI.h"
#import "Source/santad/EventProviders/SNTEndpointSecurityRecorder.h"
#include "Source/santad/Logs/EndpointSecurity/MockLogger.h"
#include "Source/santad/Metrics.h"
#import "Source/santad/SNTCompilerController.h"

using santa::AuthResultCache;
using santa::EnrichedMessage;
using santa::Enricher;
using santa::EventDisposition;
using santa::Logger;
using santa::Message;
using santa::PrefixTree;
using santa::Processor;
using santa::TelemetryEvent;
using santa::Unit;

class MockEnricher : public Enricher {
 public:
  MOCK_METHOD(std::unique_ptr<EnrichedMessage>, Enrich, (Message &&));
};

class MockAuthResultCache : public AuthResultCache {
 public:
  using AuthResultCache::AuthResultCache;

  MOCK_METHOD(void, RemoveFromCache, (const es_file_t *));
};

@interface SNTEndpointSecurityRecorderTest : XCTestCase
@property id mockConfigurator;
@end

@implementation SNTEndpointSecurityRecorderTest

- (void)setUp {
  self.mockConfigurator = OCMClassMock([SNTConfigurator class]);
  OCMStub([self.mockConfigurator configurator]).andReturn(self.mockConfigurator);
  NSString *testPattern = @"^/foo/match.*";
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:testPattern
                                                                      options:0
                                                                        error:NULL];
  OCMStub([self.mockConfigurator fileChangesRegex]).andReturn(re);
}

- (std::set<es_event_type_t>)expectedSubscriptions {
  std::set<es_event_type_t> expectedEventSubs{
      ES_EVENT_TYPE_NOTIFY_CLONE,        ES_EVENT_TYPE_NOTIFY_CLOSE,
      ES_EVENT_TYPE_NOTIFY_COPYFILE,     ES_EVENT_TYPE_NOTIFY_CS_INVALIDATED,
      ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA, ES_EVENT_TYPE_NOTIFY_EXEC,
      ES_EVENT_TYPE_NOTIFY_FORK,         ES_EVENT_TYPE_NOTIFY_EXIT,
      ES_EVENT_TYPE_NOTIFY_LINK,         ES_EVENT_TYPE_NOTIFY_RENAME,
      ES_EVENT_TYPE_NOTIFY_UNLINK,
  };

#if HAVE_MACOS_13
  if (@available(macOS 13.0, *)) {
    expectedEventSubs.insert({
        ES_EVENT_TYPE_NOTIFY_AUTHENTICATION,
        ES_EVENT_TYPE_NOTIFY_LW_SESSION_LOGIN,
        ES_EVENT_TYPE_NOTIFY_LW_SESSION_LOGOUT,
        ES_EVENT_TYPE_NOTIFY_LW_SESSION_LOCK,
        ES_EVENT_TYPE_NOTIFY_LW_SESSION_UNLOCK,
        ES_EVENT_TYPE_NOTIFY_SCREENSHARING_ATTACH,
        ES_EVENT_TYPE_NOTIFY_SCREENSHARING_DETACH,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGIN,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGOUT,
        ES_EVENT_TYPE_NOTIFY_LOGIN_LOGIN,
        ES_EVENT_TYPE_NOTIFY_LOGIN_LOGOUT,
        ES_EVENT_TYPE_NOTIFY_BTM_LAUNCH_ITEM_ADD,
        ES_EVENT_TYPE_NOTIFY_BTM_LAUNCH_ITEM_REMOVE,
    });
  }
#endif  // HAVE_MACOS_13

#if HAVE_MACOS_15
  if (@available(macOS 15.0, *)) {
    expectedEventSubs.insert(ES_EVENT_TYPE_NOTIFY_GATEKEEPER_USER_OVERRIDE);
  }
#endif  // HAVE_MACOS_15

#if HAVE_MACOS_15_4
  if (@available(macOS 15.4, *)) {
    expectedEventSubs.insert(ES_EVENT_TYPE_NOTIFY_TCC_MODIFY);
  }
#endif  // HAVE_MACOS_15_4

  return expectedEventSubs;
}

- (void)testEnable {
  // Ensure the client subscribes to expected event types
  std::set<es_event_type_t> expectedEventSubs = [self expectedSubscriptions];

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();

  id recorderClient = [[SNTEndpointSecurityRecorder alloc] initWithESAPI:mockESApi
                                                                 metrics:nullptr
                                                               processor:Processor::kRecorder];

  EXPECT_CALL(*mockESApi, Subscribe(testing::_, expectedEventSubs)).WillOnce(testing::Return(true));

  [recorderClient enable];

  for (const auto &event : expectedEventSubs) {
    XCTAssertNoThrow(santa::EventTypeToString(event));
  }

  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
}

- (void)testTelemetryMappings {
  std::set<es_event_type_t> expectedEventSubs = [self expectedSubscriptions];
  // Make sure a TelemetryEvent exists for each subscription
  for (const auto &event : expectedEventSubs) {
    XCTAssertNotEqual(santa::ESEventToTelemetryEvent(event), TelemetryEvent::kNone,
                      "Unexpected TelemetryEvent for ES event: %d", event);
    ;
  }
}

typedef void (^TestHelperBlock)(es_message_t *message,
                                std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
                                SNTEndpointSecurityRecorder *recorderClient,
                                std::shared_ptr<PrefixTree<Unit>> prefixTree,
                                dispatch_semaphore_t *sema, dispatch_semaphore_t *semaMetrics);

es_file_t targetFileMatchesRegex = MakeESFile("/foo/matches");
es_file_t targetFileMatchesAlsoRegex = MakeESFile("/foo/matches_also");
es_file_t targetFileMissesRegex = MakeESFile("/foo/misses");

- (void)handleMessageShouldLog:(BOOL)shouldLog
         shouldRemoveFromCache:(BOOL)shouldRemoveFromCache
                     withBlock:(TestHelperBlock)testBlock
                 telemetryMask:(TelemetryEvent)telemetryMask {
  es_file_t file = MakeESFile("foo");
  es_process_t proc = MakeESProcess(&file);
  es_message_t esMsg = MakeESMessage(ES_EVENT_TYPE_NOTIFY_CLOSE, &proc, ActionType::Auth);

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();
  mockESApi->SetExpectationsESNewClient();
  mockESApi->SetExpectationsRetainReleaseMessage();

  // Create a fake enriched message. It isn't used other than to inject a valid
  // returned object from a mocked Enrich method. The purpose is to ensure the
  // check in the recorder that a message is enriched always succeeds.
  es_message_t fakeEnrichedMsg = MakeESMessage(ES_EVENT_TYPE_NOTIFY_EXIT, NULL);
  std::unique_ptr<EnrichedMessage> enrichedMsg = std::make_unique<EnrichedMessage>(EnrichedMessage(
      santa::EnrichedExit(Message(mockESApi, &fakeEnrichedMsg), santa::EnrichedProcess())));

  auto mockEnricher = std::make_shared<MockEnricher>();

  auto mockAuthCache = std::make_shared<MockAuthResultCache>(nullptr, nil);
  if (shouldRemoveFromCache) {
    EXPECT_CALL(*mockAuthCache, RemoveFromCache).Times(1);
  } else {
    EXPECT_CALL(*mockAuthCache, RemoveFromCache).Times(0);
  }
  dispatch_semaphore_t semaMetrics = dispatch_semaphore_create(0);

  // NOTE: Currently unable to create a partial mock of the
  // `SNTEndpointSecurityRecorder` object. There is a bug in OCMock that doesn't
  // properly handle the `processEnrichedMessage:handler:` block. Instead this
  // test will mock the `Log` method that is called in the handler block.
  __block dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  auto mockLogger = std::make_shared<MockLogger>();
  mockLogger->SetTelemetryMask(telemetryMask);

  if (shouldLog) {
    EXPECT_CALL(*mockEnricher, Enrich).WillOnce(testing::Return(std::move(enrichedMsg)));
    EXPECT_CALL(*mockLogger, Log).WillOnce(testing::InvokeWithoutArgs(^() {
      dispatch_semaphore_signal(sema);
    }));
  } else {
    EXPECT_CALL(*mockEnricher, Enrich).Times(0);
    EXPECT_CALL(*mockLogger, Log).Times(0);
  }

  auto prefixTree = std::make_shared<PrefixTree<Unit>>();

  id mockCC = OCMStrictClassMock([SNTCompilerController class]);

  SNTEndpointSecurityRecorder *recorderClient =
      [[SNTEndpointSecurityRecorder alloc] initWithESAPI:mockESApi
                                                 metrics:nullptr
                                                  logger:mockLogger
                                                enricher:mockEnricher
                                      compilerController:mockCC
                                         authResultCache:mockAuthCache
                                              prefixTree:prefixTree
                                             processTree:nullptr];

  testBlock(&esMsg, mockESApi, mockCC, recorderClient, prefixTree, &sema, &semaMetrics);

  // Ensure the deleter is called on the fake enriched message so that the underlying message gets
  // released. Otherwise, various gmock warnings about uninteresting calls are printed because the
  // object isn't deleted until after expectations are verified below.
  enrichedMsg.reset();

  XCTAssertTrue(OCMVerifyAll(mockCC));

  XCTBubbleMockVerifyAndClearExpectations(mockAuthCache.get());
  XCTBubbleMockVerifyAndClearExpectations(mockEnricher.get());
  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
  XCTBubbleMockVerifyAndClearExpectations(mockLogger.get());

  [mockCC stopMocking];
}

- (void)handleMessageShouldLog:(BOOL)shouldLog
         shouldRemoveFromCache:(BOOL)shouldRemoveFromCache
                     withBlock:(TestHelperBlock)testBlock {
  [self handleMessageShouldLog:shouldLog
         shouldRemoveFromCache:shouldRemoveFromCache
                     withBlock:testBlock
                 telemetryMask:TelemetryEvent::kEverything];
}

- (void)testHandleEventCloseMappedWritableMatchesRegex {
#if HAVE_MACOS_13
  if (@available(macOS 13.0, *)) {
    // CLOSE not modified, but was_mapped_writable, should remove from cache,
    // and matches fileChangesRegex
    TestHelperBlock testBlock =
        ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
          SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
          __autoreleasing dispatch_semaphore_t *sema,
          __autoreleasing dispatch_semaphore_t *semaMetrics) {
          esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
          esMsg->event.close.modified = false;
          esMsg->event.close.was_mapped_writable = true;
          esMsg->event.close.target = &targetFileMatchesRegex;
          Message msg(mockESApi, esMsg);

          OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

          XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                      recordEventMetrics:^(EventDisposition d) {
                                        XCTAssertEqual(d, EventDisposition::kProcessed);
                                        dispatch_semaphore_signal(*semaMetrics);
                                      }]);
          XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
          XCTAssertSemaTrue(*sema, 5, "Log wasn't called within expected time window");
        };

    [self handleMessageShouldLog:YES shouldRemoveFromCache:YES withBlock:testBlock];
  }
#endif
}

- (void)testHandleEventCloseMappedWritableMissesRegex {
#if HAVE_MACOS_13
  if (@available(macOS 13.0, *)) {
    // CLOSE not modified, but was_mapped_writable, remove from cache, and does not match
    // fileChangesRegex
    TestHelperBlock testBlock = ^(
        es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
      esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
      esMsg->event.close.modified = false;
      esMsg->event.close.was_mapped_writable = true;
      esMsg->event.close.target = &targetFileMissesRegex;
      Message msg(mockESApi, esMsg);

      OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

      XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                  recordEventMetrics:^(EventDisposition d) {
                                    XCTFail("Metrics record callback should not be called here");
                                  }]);
    };

    [self handleMessageShouldLog:NO shouldRemoveFromCache:YES withBlock:testBlock];
  }
#endif
}

- (void)testHandleMessage {
  // CLOSE not modified, bail early
  TestHelperBlock testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
        esMsg->event.close.modified = false;
        esMsg->event.close.target = NULL;

        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTFail("Metrics record callback should not be called here");
                                    }]);
      };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:NO withBlock:testBlock];

  // CLOSE modified, remove from cache, and matches fileChangesRegex
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
        esMsg->event.close.modified = true;
        esMsg->event.close.target = &targetFileMatchesRegex;
        Message msg(mockESApi, esMsg);

        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

        [recorderClient handleMessage:std::move(msg)
                   recordEventMetrics:^(EventDisposition d) {
                     XCTAssertEqual(d, EventDisposition::kProcessed);
                     dispatch_semaphore_signal(*semaMetrics);
                   }];

        XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
        XCTAssertSemaTrue(*sema, 5, "Log wasn't called within expected time window");
      };

  [self handleMessageShouldLog:YES shouldRemoveFromCache:YES withBlock:testBlock];

  // CLOSE modified, remove from cache, but doesn't match fileChangesRegex
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
        esMsg->event.close.modified = true;
        esMsg->event.close.target = &targetFileMissesRegex;
        Message msg(mockESApi, esMsg);
        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();
        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTFail("Metrics record callback should not be called here");
                                    }]);
      };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:YES withBlock:testBlock];

  // CLONE Prefix match, bail early
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_CLONE;
        esMsg->event.clone.source = &targetFileMatchesRegex;
        esMsg->event.clone.target_dir = &targetFileMissesRegex;
        esMsg->event.clone.target_name = MakeESStringToken("foo");
        prefixTree->InsertPrefix(esMsg->event.clone.source->path.data, Unit{});
        Message msg(mockESApi, esMsg);
        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();
        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTAssertEqual(d, EventDisposition::kDropped);
                                      dispatch_semaphore_signal(*semaMetrics);
                                    }]);
        XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
      };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:NO withBlock:testBlock];

  // COPYFILE Matches regex, not prefix, handle message
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_COPYFILE;
        esMsg->event.copyfile.source = &targetFileMatchesAlsoRegex;
        esMsg->event.copyfile.target_file = &targetFileMissesRegex;
        Message msg(mockESApi, esMsg);
        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();
        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTAssertEqual(d, EventDisposition::kProcessed);
                                      dispatch_semaphore_signal(*semaMetrics);
                                    }]);
        XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
        XCTAssertSemaTrue(*sema, 5, "Log wasn't called within expected time window");
      };

  [self handleMessageShouldLog:YES shouldRemoveFromCache:NO withBlock:testBlock];

  // UNLINK, remove from cache, but doesn't match fileChangesRegex
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_UNLINK;
        esMsg->event.unlink.target = &targetFileMissesRegex;
        Message msg(mockESApi, esMsg);
        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();
        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTFail("Metrics record callback should not be called here");
                                    }]);
      };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:NO withBlock:testBlock];

  // EXCHANGEDATA, Prefix match, bail early
  testBlock =
      ^(es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
        SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
        __autoreleasing dispatch_semaphore_t *sema,
        __autoreleasing dispatch_semaphore_t *semaMetrics) {
        esMsg->event_type = ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA;
        esMsg->event.exchangedata.file1 = &targetFileMatchesRegex;
        prefixTree->InsertPrefix(esMsg->event.exchangedata.file1->path.data, Unit{});
        Message msg(mockESApi, esMsg);
        OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();
        XCTAssertNoThrow([recorderClient handleMessage:Message(mockESApi, esMsg)
                                    recordEventMetrics:^(EventDisposition d) {
                                      XCTAssertEqual(d, EventDisposition::kDropped);
                                      dispatch_semaphore_signal(*semaMetrics);
                                    }]);

        XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
      };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:NO withBlock:testBlock];

  // LINK, Prefix match, bail early
  testBlock = ^(
      es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
      SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
      __autoreleasing dispatch_semaphore_t *sema, __autoreleasing dispatch_semaphore_t *semaMetrics)

  {
    esMsg->event_type = ES_EVENT_TYPE_NOTIFY_LINK;
    esMsg->event.link.source = &targetFileMatchesRegex;
    prefixTree->InsertPrefix(esMsg->event.link.source->path.data, Unit{});
    Message msg(mockESApi, esMsg);

    OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

    [recorderClient handleMessage:std::move(msg)
               recordEventMetrics:^(EventDisposition d) {
                 XCTAssertEqual(d, EventDisposition::kDropped);
                 dispatch_semaphore_signal(*semaMetrics);
               }];

    XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
  };

  [self handleMessageShouldLog:NO shouldRemoveFromCache:NO withBlock:testBlock];

  // EXIT, EnableForkAndExitLogging is false
  testBlock = ^(
      es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
      SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
      __autoreleasing dispatch_semaphore_t *sema, __autoreleasing dispatch_semaphore_t *semaMetrics)

  {
    esMsg->event_type = ES_EVENT_TYPE_NOTIFY_EXIT;
    Message msg(mockESApi, esMsg);

    OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

    [recorderClient handleMessage:std::move(msg)
               recordEventMetrics:^(EventDisposition d) {
                 XCTAssertEqual(d, EventDisposition::kDropped);
                 dispatch_semaphore_signal(*semaMetrics);
               }];

    XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
  };

  [self handleMessageShouldLog:NO
         shouldRemoveFromCache:NO
                     withBlock:testBlock
                 telemetryMask:santa::TelemetryConfigToBitmask(nil, false)];

  // FORK, EnableForkAndExitLogging is true
  testBlock = ^(
      es_message_t *esMsg, std::shared_ptr<MockEndpointSecurityAPI> mockESApi, id mockCC,
      SNTEndpointSecurityRecorder *recorderClient, std::shared_ptr<PrefixTree<Unit>> prefixTree,
      __autoreleasing dispatch_semaphore_t *sema, __autoreleasing dispatch_semaphore_t *semaMetrics)

  {
    esMsg->event_type = ES_EVENT_TYPE_NOTIFY_FORK;
    Message msg(mockESApi, esMsg);

    OCMExpect([mockCC handleEvent:msg withLogger:nullptr]).ignoringNonObjectArgs();

    [recorderClient handleMessage:std::move(msg)
               recordEventMetrics:^(EventDisposition d) {
                 XCTAssertEqual(d, EventDisposition::kProcessed);
                 dispatch_semaphore_signal(*semaMetrics);
               }];

    XCTAssertSemaTrue(*semaMetrics, 5, "Metrics not recorded within expected window");
  };

  [self handleMessageShouldLog:YES
         shouldRemoveFromCache:NO
                     withBlock:testBlock
                 telemetryMask:santa::TelemetryConfigToBitmask(nil, true)];

  XCTAssertTrue(OCMVerifyAll(self.mockConfigurator));
}

- (void)testGetTargetFileForPrefixTree {
  // Ensure `GetTargetFileForPrefixTree` returns expected field for each
  // subscribed event type in the `SNTEndpointSecurityRecorder`.
  extern es_file_t *GetTargetFileForPrefixTree(const es_message_t *msg);

  es_file_t cloneFile = MakeESFile("clone");
  es_file_t closeFile = MakeESFile("close");
  es_file_t copyfileFile = MakeESFile("copyfile");
  es_file_t exchangedataFile = MakeESFile("exchangedata");
  es_file_t linkFile = MakeESFile("link");
  es_file_t renameFile = MakeESFile("rename");
  es_file_t unlinkFile = MakeESFile("unlink");
  es_message_t esMsg;

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_CLONE;
  esMsg.event.clone.source = &cloneFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &cloneFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_CLOSE;
  esMsg.event.close.target = &closeFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &closeFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_COPYFILE;
  esMsg.event.clone.source = &copyfileFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &copyfileFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_LINK;
  esMsg.event.link.source = &linkFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &linkFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_RENAME;
  esMsg.event.rename.source = &renameFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &renameFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_UNLINK;
  esMsg.event.unlink.target = &unlinkFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &unlinkFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA;
  esMsg.event.exchangedata.file1 = &exchangedataFile;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), &exchangedataFile);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_EXEC;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), nullptr);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_FORK;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), nullptr);

  esMsg.event_type = ES_EVENT_TYPE_NOTIFY_EXIT;
  XCTAssertEqual(GetTargetFileForPrefixTree(&esMsg), nullptr);
}

@end
