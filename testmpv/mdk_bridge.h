#ifndef MDK_BRIDGE_H
#define MDK_BRIDGE_H
#ifndef BUILD_MDK_STATIC
#define BUILD_MDK_STATIC   // MDK_API expands to nothing; symbols resolved by dlopen + dynamic_lookup
#endif
#include "module.h"        // includes all MDK C headers (Player.h, RenderAPI.h, global.h, etc.)
#endif
