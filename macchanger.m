#include <arpa/inet.h>
#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <getopt.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <net/if_types.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/network/IONetworkController.h>
#import <CoreWLAN/CoreWLAN.h>

#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define YELLOW "\033[0;33m"
#define RS "\033[0m"

#define BOLD "\x1b[1m"
#define NORMAL "\x1b(B\x1b[m"

#define ERROR   BOLD RED "ERROR:" RS NORMAL "   "
#define INFO    BOLD CYAN "INFO:" RS NORMAL "    "
#define WARNING BOLD YELLOW "WARNING:" RS NORMAL " "

#define PERROR() fprintf(stderr, ERROR "%s: %s\n", __FUNCTION__, strerror(errno));

#ifndef CONFIG_PATH
#define CONFIG_PATH "/usr/local/etc/macchanger.conf"
#endif

#define LAUNCHD_LABEL "com.github.macchanger"
#define LAUNCHD_PLIST_PATH "/Library/LaunchDaemons/" LAUNCHD_LABEL ".plist"

#define MAX_RETRIES 6
#define RETRY_DELAY_SECONDS 5

typedef io_service_t interface_t;
void interface_open(interface_t* iface, const char* name);
void interface_get_name(interface_t iface, char* name);
void interface_get_ether(const interface_t iface, ether_addr_t* ether);
void interface_set_ether(interface_t iface, const ether_addr_t* ether);
void interface_get_permanent_ether(const interface_t iface, ether_addr_t* ether);
int interface_is_airport(interface_t iface);
void interface_airport_disassociate(interface_t iface);

void print_usage();
void print_version();
void print_info(const interface_t iface);
void change_mac(interface_t iface, const ether_addr_t* ether);

void random_ether(ether_addr_t* ether);
int ether_parse(const char* str, ether_addr_t* ether);
const char* ether_to_string(const ether_addr_t* ether);

void save_config(const char* config_path, const char* if_name, const ether_addr_t* ether);
int load_config(const char* config_path, char* if_name, ether_addr_t* ether);
int install_daemon(const char* bin_path);
int uninstall_daemon(void);

int main(int argc, char** argv) {
    static const struct option long_options[] = {
        {"random", no_argument, NULL, 'r'},
        {"mac", required_argument, NULL, 'm'},
        {"permanent", no_argument, NULL, 'p'},
        {"show", no_argument, NULL, 's'},
        {"version", no_argument, NULL, 'v'},
        {"save", no_argument, NULL, 'S'},
        {"config", no_argument, NULL, 'c'},
        {"install-daemon", no_argument, NULL, 'i'},
        {"uninstall-daemon", no_argument, NULL, 'u'},
        {NULL, 0, NULL, 0}
    };

    char selected_option = 0;
    char mac_specified = 0;
    ether_addr_t ether;

    int ch;
    while ((ch = getopt_long(argc, argv, "rm:psvSciu", long_options, NULL)) != -1) {
        if(selected_option != 0 && !(selected_option == 'S' && ch == 'm') && !(selected_option == 'm' && ch == 'S')) {
            fputs(ERROR "Only one option is allowed at a time\n", stderr);
            return 1;
        }
        selected_option = ch;

        if(ch == 'm') {
            mac_specified = 1;
            int res = ether_parse(optarg, &ether);
            if(res) {
                fputs(ERROR "Failed to parse MAC address\n", stderr);
                return res;
            }
        }
    }
    argc -= optind;
    argv += optind;

    if(selected_option == 0 || selected_option == '?') {
        print_usage();
        return opterr;
    } else if(selected_option == 'v') {
        print_version();
        return 0;
    }

    // Handle --config (read config file and apply)
    if(selected_option == 'c') {
        char cfg_if[IF_NAMESIZE] = {};
        ether_addr_t cfg_ether;

        if (load_config(CONFIG_PATH, cfg_if, &cfg_ether) != 0) {
            return 1;
        }

        // Retry loop for interface availability at boot time
        interface_t iface;
        for (int attempt = 0; attempt < MAX_RETRIES; attempt++) {
            interface_open(&iface, cfg_if);
            if (iface) break;
            fprintf(stderr, WARNING "Interface %s not found, retrying in %ds (%d/%d)...\n",
                    cfg_if, RETRY_DELAY_SECONDS, attempt + 1, MAX_RETRIES);
            sleep(RETRY_DELAY_SECONDS);
        }

        if (!iface) {
            fprintf(stderr, ERROR "Interface %s not found after %d attempts\n", cfg_if, MAX_RETRIES);
            return 1;
        }

        change_mac(iface, &cfg_ether);
        return 0;
    }

    // Handle --install-daemon
    if(selected_option == 'i') {
        if (geteuid() != 0) {
            fputs(ERROR "Please run --install-daemon as root\n", stderr);
            return 1;
        }
        // Resolve binary path
        char bin_path[PATH_MAX];
        if (realpath(argv[0] ? argv[0] : "/proc/self/exe", bin_path) == NULL) {
            // Fallback: use which
            FILE* pipe = popen("which macchanger", "r");
            if (pipe && fgets(bin_path, sizeof(bin_path), pipe)) {
                bin_path[strcspn(bin_path, "\n")] = '\0';
            }
            if (pipe) pclose(pipe);
        }
        return install_daemon(bin_path);
    }

    // Handle --uninstall-daemon
    if(selected_option == 'u') {
        if (geteuid() != 0) {
            fputs(ERROR "Please run --uninstall-daemon as root\n", stderr);
            return 1;
        }
        return uninstall_daemon();
    }

    // Handle --save
    if(selected_option == 'S') {
        if(argc < 1) {
            fputs(ERROR "Please specify an interface name\n", stderr);
            return 1;
        }
        const char* if_name = argv[0];
        if(strlen(if_name) > IFNAMSIZ) {
            fputs(ERROR "Interface name too long\n", stderr);
            return 1;
        }

        if (!mac_specified) {
            // Read current MAC from interface
            interface_t iface;
            interface_open(&iface, if_name);
            if(!iface) {
                fprintf(stderr, ERROR "Can not find device %s\n", if_name);
                return 1;
            }
            interface_get_ether(iface, &ether);
        }

        save_config(CONFIG_PATH, if_name, &ether);
        return 0;
    }

    // Original options below
    if(argc < 1) {
        fputs(ERROR "Please specify an interface name\n", stderr);
        return 1;
    }

    const char* if_name = argv[0];
    if(strlen(if_name) > IFNAMSIZ) {
        fputs(ERROR "Interface name too long\n", stderr);
        return 1;
    }

    interface_t iface;
    interface_open(&iface, if_name);

    if(!iface) {
        fputs(ERROR "Can not find device / interface. Maybe it is down?\n", stderr);
        return 1;
    }

    if(selected_option == 's') {
        print_info(iface);
        return 0;
    }

    if(selected_option == 'r') {
        random_ether(&ether);
    } else if(selected_option == 'p') {
        interface_get_permanent_ether(iface, &ether);
    } else {
        assert(selected_option == 'm');
    }

    change_mac(iface, &ether);

    return 0;
}

void print_usage() {
    puts("Usage: macchanger [option] [device]");
    puts("Options:");
    puts(" -r, --random           Generates a random MAC and sets it");
    puts(" -m, --mac MAC          Set a custom MAC address, e.g. macchanger -m aa:bb:cc:dd:ee:ff en0");
    puts(" -p, --permanent        Resets the MAC address to the permanent");
    puts(" -s, --show             Shows the current MAC address");
    puts(" -v, --version          Prints version");
    puts(" -S, --save             Save current MAC to config file (combine with -m to save specific MAC)");
    puts(" -c, --config           Apply MAC from config file (" CONFIG_PATH ")");
    puts(" -i, --install-daemon   Install launchd daemon for auto-start at boot");
    puts(" -u, --uninstall-daemon Remove launchd daemon");

#ifdef HOMEPAGE
    puts("\nHomepage: " HOMEPAGE);
#endif
}

void print_version() {
#if defined(VERSION) && defined(YEAR) && defined(AUTHOR) && defined(HOMEPAGE)
    puts("Version:  " VERSION ", Copyright " YEAR " by " AUTHOR);
    puts("Homepage: " HOMEPAGE);
#else
    puts("Built without version information");
#endif
}

void print_info(const interface_t iface) {
    ether_addr_t ether, permanent_ether;

    interface_get_ether(iface, &ether);
    interface_get_permanent_ether(iface, &permanent_ether);

    printf(BOLD "Current MAC address:" NORMAL "    %s\n", ether_to_string(&ether));
    printf(BOLD "Permanent MAC address:" NORMAL "  %s\n", ether_to_string(&permanent_ether));
}

void change_mac(const interface_t iface, const ether_addr_t* new_ether) {
    ether_addr_t permanent_ether, old_ether, current_ether;

    if (new_ether->octet[0] & 1) {
        fputs(WARNING "MAC address is multicast! Setting it might not work.\n", stderr);
    }

    int is_airport = interface_is_airport(iface);
    if(is_airport) {
        fputs(INFO "Type of interface is Wi-Fi. Will disassociate from any network.\n", stderr);
    }

    interface_get_permanent_ether(iface, &permanent_ether);
    interface_get_ether(iface, &old_ether);
    if(is_airport) {
        interface_airport_disassociate(iface);
    }
    interface_set_ether(iface, new_ether);
    interface_get_ether(iface, &current_ether);

    if(memcmp(new_ether, &current_ether, sizeof(current_ether)) != 0) {
        fputs(ERROR "Can't set MAC address on this device. Ensure the driver supports changing the MAC address.\n", stderr);
        exit(1);
    }

    printf(BOLD "Permanent MAC address:" NORMAL " %s\n", ether_to_string(&permanent_ether));
    printf(BOLD "Old MAC address:" NORMAL "       %s\n", ether_to_string(&old_ether));
    printf(BOLD "New MAC address:" NORMAL "       %s\n", ether_to_string(new_ether));
}

void random_ether(ether_addr_t* ether) {
    int fd = open("/dev/urandom", O_RDONLY);
    if(fd == -1) {
        PERROR();
        exit(errno);
    }

    size_t to_read = ETHER_ADDR_LEN;

    while(to_read > 0) {
        ssize_t n = read(fd, ether->octet + (ETHER_ADDR_LEN - to_read), to_read);
        if(n == -1) {
            PERROR();
            exit(errno);
        }
        to_read -= n;
    }

    // Make ether unicast
    ether->octet[0] &= 0xFE;

    close(fd);
}

#define ETHER_STRING_LEN (3 * ETHER_ADDR_LEN - 1)
int ether_parse(const char* str, ether_addr_t* ether) {
    if(strlen(str) != ETHER_STRING_LEN) return -1;
    for(int i = 2; i < ETHER_STRING_LEN; i += 3) {
        if(str[i] != ':') return -1;
    }

    for(int i = 0; i < ETHER_ADDR_LEN; i++) {
        ether->octet[i] = 0;
        for(int j = 0; j < 2; j++) {
            ether->octet[i] <<= 4;
            char ch = str[3 * i + j];
            if(ch >= '0' && ch <= '9') ether->octet[i] |= (ch - '0');
            else if(ch >= 'a' && ch <= 'f') ether->octet[i] |= (ch - 'a' + 10);
            else if(ch >= 'A' && ch <= 'F') ether->octet[i] |= (ch - 'A' + 10);
            else return -1;
        }
    }
    return 0;
}

const char* ether_to_string(const ether_addr_t* ether) {
    static char buf[ETHER_STRING_LEN];

    char* out = buf;
    for(int i = 0; i < ETHER_ADDR_LEN; i++) {
        if(i > 0) {
            *out++ = ':';
        }
        out += sprintf(out, "%.2x", ether->octet[i]);
    }

    return buf;
}
#undef ETHER_STRING_LEN

void interface_open(interface_t* iface, const char* name) {
    assert(iface);

    CFMutableDictionaryRef matchingDict = IOBSDNameMatching(kIOMasterPortDefault, 0, name);
    if (matchingDict == NULL) {
        exit(1);
    }

    *iface = IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict);
}

void interface_get_name(const interface_t iface, char* name) {
    IORegistryEntryGetName(iface, name);
}

#define if_request(iface, code, req)                                 \
    {                                                               \
        char if_name[IF_NAMESIZE] = {};                             \
        interface_get_name(iface, if_name);                         \
        int fd = socket(AF_INET, SOCK_DGRAM, 0);                    \
        strncpy(req.ifr_name, if_name, IF_NAMESIZE);                \
        int res = ioctl(fd, code, &req);                            \
        if(res == -1) {                                             \
            PERROR();                                               \
            if(errno == EPERM && geteuid() != 0) {                  \
                fputs("Please run macchanger as root\n", stderr);   \
            }                                                       \
            exit(errno);                                            \
        }                                                           \
        close(fd);                                                  \
    }

void interface_get_ether(const interface_t iface, ether_addr_t* ether) {
    struct ifreq req;
#define SIOCGIFLLADDR _IOWR('i', 158, struct ifreq)
    if_request(iface, SIOCGIFLLADDR, req);
#undef SIOCGIFLLADDR
    assert(req.ifr_addr.sa_family == AF_LINK);
    assert(req.ifr_addr.sa_len == ETHER_ADDR_LEN);
    memcpy(ether->octet, req.ifr_addr.sa_data, ETHER_ADDR_LEN);
}

void interface_set_ether(interface_t iface, const ether_addr_t* ether) {
    struct ifreq req;
    bzero(&req.ifr_addr, sizeof(req.ifr_addr));
    req.ifr_addr.sa_family = AF_LINK;
    req.ifr_addr.sa_len = ETHER_ADDR_LEN;
    memcpy(req.ifr_addr.sa_data, ether->octet, ETHER_ADDR_LEN);
    if_request(iface, SIOCSIFLLADDR, req);
}

void interface_get_permanent_ether(const interface_t iface, ether_addr_t* ether) {
    io_registry_entry_t parent;
    IORegistryEntryGetParentEntry(iface, kIOServicePlane, &parent);

    CFDataRef data = IORegistryEntryCreateCFProperty(parent, CFSTR(kIOMACAddress), kCFAllocatorDefault, 0);
    memcpy(ether->octet, CFDataGetBytePtr(data), CFDataGetLength(data));

    IOObjectRelease(parent);
}

int interface_is_airport(interface_t iface) {
    io_registry_entry_t parent;
    IORegistryEntryGetParentEntry(iface, kIOServicePlane, &parent);
    char buf[256] = {0};
    IOObjectGetClass(parent, buf);
    IOObjectRelease(parent);
    return strcmp(buf, "IO80211Controller") == 0;
}

void interface_airport_disassociate(interface_t iface) {
    char if_name[IF_NAMESIZE] = {};
    interface_get_name(iface, if_name);

    CWWiFiClient *client = [[CWWiFiClient alloc] init];

    CWInterface *interface = [client interfaceWithName:[NSString stringWithUTF8String:if_name]];

    [interface disassociate];

    [client dealloc];
}

void save_config(const char* config_path, const char* if_name, const ether_addr_t* ether) {
    FILE* f = fopen(config_path, "w");
    if (!f) {
        PERROR();
        exit(errno);
    }
    fprintf(f, "# macchanger configuration\n");
    fprintf(f, "# Generated by: sudo macchanger --save %s\n\n", if_name);
    fprintf(f, "interface=%s\n", if_name);
    fprintf(f, "mac=%s\n", ether_to_string(ether));
    fclose(f);
    chmod(config_path, 0600);
    printf(INFO "Configuration saved to %s\n", config_path);
}

int load_config(const char* config_path, char* if_name, ether_addr_t* ether) {
    FILE* f = fopen(config_path, "r");
    if (!f) {
        fprintf(stderr, ERROR "Config file not found: %s\n", config_path);
        fprintf(stderr, "Run 'sudo macchanger --save <interface>' to create one.\n");
        return -1;
    }

    int has_interface = 0, has_mac = 0;
    char line[256];

    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;

        char* eq = strchr(line, '=');
        if (!eq) continue;

        *eq = '\0';
        char* key = line;
        char* val = eq + 1;
        val[strcspn(val, "\n")] = '\0';

        if (strcmp(key, "interface") == 0) {
            strncpy(if_name, val, IF_NAMESIZE);
            has_interface = 1;
        } else if (strcmp(key, "mac") == 0) {
            if (ether_parse(val, ether) == 0) {
                has_mac = 1;
            }
        }
    }
    fclose(f);

    if (!has_interface) {
        fprintf(stderr, ERROR "Config file missing 'interface' key\n");
        return -1;
    }
    if (!has_mac) {
        fprintf(stderr, ERROR "Config file missing or invalid 'mac' key\n");
        return -1;
    }
    return 0;
}

int install_daemon(const char* bin_path) {
    FILE* f = fopen(LAUNCHD_PLIST_PATH, "w");
    if (!f) {
        PERROR();
        return errno;
    }

    fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    fprintf(f, "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\"\n");
    fprintf(f, "  \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
    fprintf(f, "<plist version=\"1.0\">\n");
    fprintf(f, "<dict>\n");
    fprintf(f, "    <key>Label</key>\n");
    fprintf(f, "    <string>%s</string>\n\n", LAUNCHD_LABEL);
    fprintf(f, "    <key>ProgramArguments</key>\n");
    fprintf(f, "    <array>\n");
    fprintf(f, "        <string>%s</string>\n", bin_path);
    fprintf(f, "        <string>--config</string>\n");
    fprintf(f, "    </array>\n\n");
    fprintf(f, "    <key>RunAtLoad</key>\n");
    fprintf(f, "    <true/>\n\n");
    fprintf(f, "    <key>LaunchOnlyOnce</key>\n");
    fprintf(f, "    <true/>\n\n");
    fprintf(f, "    <key>StandardOutPath</key>\n");
    fprintf(f, "    <string>/var/log/macchanger.log</string>\n\n");
    fprintf(f, "    <key>StandardErrorPath</key>\n");
    fprintf(f, "    <string>/var/log/macchanger.log</string>\n");
    fprintf(f, "</dict>\n");
    fprintf(f, "</plist>\n");
    fclose(f);

    printf(INFO "Daemon plist installed to %s\n", LAUNCHD_PLIST_PATH);

    // Load the daemon
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "launchctl load %s", LAUNCHD_PLIST_PATH);
    int res = system(cmd);
    if (res == 0) {
        printf(INFO "Daemon loaded successfully\n");
    } else {
        fprintf(stderr, WARNING "Failed to load daemon (exit code %d)\n", res);
    }
    return 0;
}

int uninstall_daemon(void) {
    // Unload the daemon
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "launchctl unload %s", LAUNCHD_PLIST_PATH);
    int res = system(cmd);
    if (res == 0) {
        printf(INFO "Daemon unloaded\n");
    }

    // Remove the plist file
    if (unlink(LAUNCHD_PLIST_PATH) == 0) {
        printf(INFO "Daemon plist removed from %s\n", LAUNCHD_PLIST_PATH);
    } else {
        fprintf(stderr, WARNING "Plist file not found: %s\n", LAUNCHD_PLIST_PATH);
    }
    return 0;
}
