/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "Source/common/SNTDropRootPrivs.h"

#include <sys/cdefs.h>

__BEGIN_DECLS

BOOL DropRootPrivileges() {
  if (getuid() == 0 || geteuid() == 0 || getgid() == 0 || getegid() == 0) {
    uid_t nobody = (uid_t)-2;
    if (setgid(nobody) != 0 || setgroups(0, NULL) != 0 || setegid(nobody) != 0 ||
        setuid(nobody) != 0 || seteuid(nobody) != 0) {
      return false;
    }

    if (getuid() != geteuid() || getgid() != getegid()) {
      return false;
    }
  }

  return true;
}

__END_DECLS
