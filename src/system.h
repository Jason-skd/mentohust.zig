/* System ABI source for the generated Zig bindings. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <pthread.h>
#include <stdlib.h>
#include <termios.h>
#if defined(__APPLE__)
#include <sys/event.h>
#include <net/bpf.h>
#include <net/if_dl.h>
#elif defined(__linux__)
#include <sys/signalfd.h>
#include <netpacket/packet.h>
#include <net/ethernet.h>
#endif
