#ifndef _ARC_SHIM_H
#define _ARC_SHIM_H
#include <stdbool.h>
#ifdef __OBJC__
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

id objc_storeWeak(id *slot, id value);
#endif

void __ARCShimInit(bool haveDispatch);

#endif