/// Copyright 2022 Google LLC
/// Copyright 2025 North Pole Security, Inc.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///     https://www.apache.org/licenses/LICENSE-2.0
///
/// Unless required by applicable law or agreed to in writing, software
/// distributed under the License is distributed on an "AS IS" BASIS,
/// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
/// See the License for the specific language governing permissions and
/// limitations under the License.

#ifndef SANTA__COMMON__PLATFORM_H
#define SANTA__COMMON__PLATFORM_H

#include <Availability.h>

#if defined(MAC_OS_VERSION_13_0) && \
    MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_13_0
#define HAVE_MACOS_13 1
#else
#undef HAVE_MACOS_13
#endif

#if defined(MAC_OS_VERSION_14_0) && \
    MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_14_0
#define HAVE_MACOS_14 1
#else
#undef HAVE_MACOS_14
#endif

// Note: MAC_OS_X_VERSION_MAX_ALLOWED (non-underscore version) stopped
// being correctly defined in the macOS 15 SDK. (FB15780730)
#if defined(MAC_OS_VERSION_15_0) && \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_15_0
#define HAVE_MACOS_15 1
#else
#undef HAVE_MACOS_15
#endif

#if defined(MAC_OS_VERSION_15_4) && \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_15_4
#define HAVE_MACOS_15_4 1
#else
#undef HAVE_MACOS_15_4
#endif

#endif
