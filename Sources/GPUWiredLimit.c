#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>

#define GPU_LIMIT "iogpu.wired_limit_mb"
#define MIB (1024ULL * 1024)
#define LOCK_PATH "/var/run/org.ramcruzy.memory-monitor.gpu.lock"

static volatile sig_atomic_t stopping;

static void stop(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static int read_limit(void) {
    int value;
    size_t size = sizeof(value);
    return sysctlbyname(GPU_LIMIT, &value, &size, NULL, 0) == 0 && size == sizeof(value) && value >= 0 ? value : -1;
}

static int parse_number(const char *text) {
    char *end;
    errno = 0;
    long value = strtol(text, &end, 10);
    return errno == 0 && end != text && *end == '\0' && value > 0 && value <= INT32_MAX ? (int)value : -1;
}

static int receive(int fd, int timeout_ms) {
    struct pollfd peer = { .fd = fd, .events = POLLIN };
    char byte;
    if (stopping || poll(&peer, 1, timeout_ms) != 1 || read(fd, &byte, 1) != 1) return -1;
    return (unsigned char)byte;
}

static void send_status(int fd, char byte) {
    (void)send(fd, &byte, 1, 0);
}

static int restore(int applied, int previous) {
    for (int attempt = 0; attempt < 68; ++attempt) {
        int live = read_limit();
        if (live == previous) return 'R';
        if (live >= 0 && live != applied) return 'X';
        if (live == applied) (void)sysctlbyname(GPU_LIMIT, NULL, NULL, &previous, sizeof(previous));
        if (read_limit() == previous) return 'R';
        if (attempt < 8) usleep(250000);
        else sleep(1);
    }
    return 'F';
}

static void run(int peer, int target) {
    int lock = open(LOCK_PATH, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDONLY, 0600);
    struct stat info;
    if (lock < 0 || fstat(lock, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & 077) != 0 || info.st_nlink != 1) {
        send_status(peer, 'E');
        if (lock >= 0) close(lock);
        return;
    }
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
        send_status(peer, 'B');
        close(lock);
        return;
    }

    int previous = read_limit();
    if (previous < 0) send_status(peer, 'E');
    else if (target <= previous) send_status(peer, 'N');
    else {
        send_status(peer, 'P');
        int command;
        do { command = receive(peer, 30000); } while (command == 'K');
        if (command == 'A' && !stopping) {
            previous = read_limit();
            if (previous < 0) send_status(peer, 'E');
            else if (target <= previous) send_status(peer, 'N');
            else {
                int result = sysctlbyname(GPU_LIMIT, NULL, NULL, &target, sizeof(target));
                int live = read_limit();
                if (result == 0 && live == target) {
                    send_status(peer, 'A');
                    while (receive(peer, 90000) == 'K') {}
                    send_status(peer, (char)restore(target, previous));
                } else {
                    // A successful setter followed by an unreadable value still needs a rollback attempt.
                    if (result == 0 || live == target) {
                        if (restore(target, previous) == 'F') {
                            send_status(peer, 'F');
                            close(lock);
                            return;
                        }
                    }
                    send_status(peer, 'E');
                }
            }
        }
    }
    close(lock);
}

int main(int argc, char *argv[]) {
    if (argc != 4 || geteuid() != 0) return 1;
    int uid = parse_number(argv[2]);
    int target = parse_number(argv[3]);

    uint64_t physical;
    size_t size = sizeof(physical);
    if (uid < 0 || target < 0 ||
        sysctlbyname("hw.memsize", &physical, &size, NULL, 0) != 0 || size != sizeof(physical)) return 1;
    uint64_t total = physical / MIB;
    uint64_t reserve = total / 8 < 4096 ? 4096 : total / 8;
    if ((uint64_t)target + reserve > total) return 1;

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(argv[1]) >= sizeof(address.sun_path)) return 1;
    strlcpy(address.sun_path, argv[1], sizeof(address.sun_path));
    address.sun_len = SUN_LEN(&address);

    struct sigaction action = { .sa_handler = stop };
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    int peer = socket(AF_UNIX, SOCK_STREAM, 0);
    if (peer < 0) return 1;
    uid_t peer_uid;
    gid_t peer_gid;
    if (connect(peer, (struct sockaddr *)&address, address.sun_len) != 0 ||
        getpeereid(peer, &peer_uid, &peer_gid) != 0 || peer_uid != (uid_t)uid) {
        close(peer);
        return 1;
    }
    run(peer, target);
    close(peer);
    return 0;
}
