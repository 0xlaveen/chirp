#ifndef CHIRP_DARWIN_NOTIFY_H
#define CHIRP_DARWIN_NOTIFY_H
// Darwin's Swift umbrella omits notify.h. Import the public SDK header through
// a C module; notify_register_dispatch retains its block through cancellation.
#include <notify.h>
#endif
