/* Fixed macOS floating-point smallft configuration, matching the pinned probe. */
#include <math.h>
#define FLOATING_POINT 1
#define USE_SMALLFT 1
#define VAR_ARRAYS 1
#define HAVE_STDINT_H 1
#define EXPORT __attribute__((visibility("hidden")))
