// DNS shim for the phone-hosted OpenCode server.
//
// STATUS: superseded, kept as source only. It resolves correctly in isolation
// (verified through a preloaded `ping`), but preloading it into the server
// breaks the server's own `listen` with EFAULT for reasons never fully
// established, so it ships in no APK. The production path is the in-app
// CONNECT proxy (`lib/src/runtime/connect_proxy.dart`), which needs no native
// code at all. This file stays because a correct stub resolver is worth more
// than the day it took, should the proxy ever stop being enough.
//
// The musl resolver only reads /etc/resolv.conf, which does not exist on
// Android, so every external name fails inside the server while the device
// itself is online. This library is preloaded into the server process
// (LD_PRELOAD) and answers getaddrinfo from DNS servers the app discovered
// through Android's own APIs and passed in OPENCODE_DNS. No root involved:
// the network was always reachable, only the address book was missing.
//
// Scope, deliberately: numeric services plus http/https, A/AAAA records with
// CNAME chasing, UDP only. No search domains, no /etc/hosts beyond localhost,
// no TCP fallback for truncated replies. A lookup that needs any of that
// fails cleanly with the usual EAI_* code instead of hanging.
//
// Build (NDK 28, minSdk 24, aarch64 only — the app has no other ABI):
//
//   aarch64-linux-android24-clang -shared -fPIC -O2 -o libdnsshim.so \
//     dns_shim.c -ldl
//
// The resulting .so ships in the APK next to the musl loader and is mapped
// from the extracted native library directory, exactly like the loader.
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DNS_PORT 53
#define DNS_MAX_MSG 4096
#define DNS_TIMEOUT_MS 2000
#define DNS_MAX_CNAME 5
#define DNS_MAX_ADDRS 16
#define DNS_MAX_SERVERS 8

typedef struct {
  int family;
  uint8_t addr[16];
} dns_answer_t;

typedef struct {
  struct sockaddr_storage ss;
  int family;
  char ip[64];
} dns_server_t;

static dns_server_t g_servers[DNS_MAX_SERVERS];
static int g_server_count = 0;
static int g_debug = 0;

#define SHIM_LOG(...) \
  do { \
    if (g_debug) fprintf(stderr, "dnsshim: " __VA_ARGS__); \
  } while (0)

// --- freed tracking ----------------------------------------------------------
// None. Every addrinfo in the process comes from the getaddrinfo below — the
// real one is never called by anyone, since the interposition is global — so
// freeaddrinfo always owns what it is given and frees it outright. A global
// registry with a mutex was the first version; the mutex pulled
// __register_atfork out of bionic, which the musl loader loading this library
// does not have, and the server refused to start at all.

// --- configuration -----------------------------------------------------------

static void add_server_literal(const char *ip) {
  if (g_server_count >= DNS_MAX_SERVERS) return;
  dns_server_t *s = &g_servers[g_server_count];
  memset(s, 0, sizeof(*s));
  struct in_addr v4;
  struct in6_addr v6;
  if (inet_pton(AF_INET, ip, &v4) == 1) {
    s->family = AF_INET;
    struct sockaddr_in *sin = (struct sockaddr_in *)&s->ss;
    sin->sin_family = AF_INET;
    sin->sin_port = htons(DNS_PORT);
    sin->sin_addr = v4;
  } else if (inet_pton(AF_INET6, ip, &v6) == 1) {
    s->family = AF_INET6;
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&s->ss;
    sin6->sin6_family = AF_INET6;
    sin6->sin6_port = htons(DNS_PORT);
    sin6->sin6_addr = v6;
  } else {
    return;
  }
  strncpy(s->ip, ip, sizeof(s->ip) - 1);
  g_server_count++;
}

__attribute__((constructor)) static void shim_init(void) {
  srand((unsigned)(time(NULL) ^ getpid()));
  g_debug = getenv("OPENCODE_DNS_DEBUG") != NULL;
  const char *env = getenv("OPENCODE_DNS");
  if (env && *env) {
    char copy[512];
    strncpy(copy, env, sizeof(copy) - 1);
    copy[sizeof(copy) - 1] = '\0';
    for (char *tok = strtok(copy, ",; "); tok; tok = strtok(NULL, ",; ")) {
      add_server_literal(tok);
    }
  }
  if (g_server_count == 0) {
    // Proven reachable from the sandbox; last resort, not the plan.
    add_server_literal("8.8.8.8");
    add_server_literal("1.1.1.1");
  }
  // One line per process, always: it proves in the server output that the
  // preload took effect, which is the first thing to check when lookups fail.
  fprintf(stderr, "dnsshim: loaded, %d upstream server(s)\n", g_server_count);
}

// --- wire format ---------------------------------------------------------------

static size_t encode_name(uint8_t *out, const char *name) {
  // Bare names and trailing dots both accepted; overlong rejected.
  size_t pos = 0;
  const char *label = name;
  for (;;) {
    const char *dot = strchr(label, '.');
    size_t len = dot ? (size_t)(dot - label) : strlen(label);
    if (len == 0 || len > 63 || pos + len + 1 >= 255) return 0;
    out[pos++] = (uint8_t)len;
    memcpy(out + pos, label, len);
    pos += len;
    if (!dot) break;
    label = dot + 1;
    if (*label == '\0') break;
  }
  out[pos++] = 0;
  return pos;
}

// Length of the name at `p`, following compression pointers with a step cap.
// Returns 0 on any malformed input.
static size_t name_skip(const uint8_t *msg, size_t msg_len, size_t pos) {
  size_t start = pos;
  int steps = 0;
  int jumped = 0;
  size_t consumed = 0;
  while (pos < msg_len) {
    if (++steps > 64) return 0;
    uint8_t len = msg[pos];
    if ((len & 0xC0) == 0xC0) {
      if (pos + 1 >= msg_len) return 0;
      if (!jumped) consumed = pos + 2 - start;
      pos = ((len & 0x3F) << 8) | msg[pos + 1];
      jumped = 1;
      continue;
    }
    if (len == 0) {
      return jumped ? consumed : pos + 1 - start;
    }
    if (len > 63 || pos + 1 + len > msg_len) return 0;
    pos += 1 + len;
    if (!jumped) consumed = pos - start;
  }
  return 0;
}

// Unpacks a possibly compressed name into dotted form. Returns 0 on success.
static int name_unpack(
  const uint8_t *msg,
  size_t msg_len,
  size_t pos,
  char *out,
  size_t out_len
) {
  size_t out_pos = 0;
  int steps = 0;
  while (pos < msg_len) {
    if (++steps > 64) return -1;
    uint8_t len = msg[pos];
    if ((len & 0xC0) == 0xC0) {
      if (pos + 1 >= msg_len) return -1;
      pos = ((len & 0x3F) << 8) | msg[pos + 1];
      continue;
    }
    if (len == 0) break;
    if (len > 63 || pos + 1 + len > msg_len) return -1;
    if (out_pos + len + 1 >= out_len) return -1;
    if (out_pos > 0) out[out_pos++] = '.';
    memcpy(out + out_pos, msg + pos + 1, len);
    out_pos += len;
    pos += 1 + len;
  }
  if (out_pos >= out_len) return -1;
  out[out_pos] = '\0';
  return 0;
}

static int name_equal_nocase(const char *a, const char *b) {
  for (;; a++, b++) {
    unsigned char ca = (unsigned char)*a;
    unsigned char cb = (unsigned char)*b;
    if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
    if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
    if (ca != cb) return 0;
    if (ca == '\0') return 1;
  }
}

// One question, one answer collection. Returns: >0 answers stored, 0 for
// NXDOMAIN, -1 for anything inconclusive (timeout, truncation, SERVFAIL).
static int dns_query(
  const dns_server_t *server,
  const char *name,
  uint16_t qtype,
  dns_answer_t *answers,
  int max_answers
) {
  uint8_t out[512];
  uint16_t txid = (uint16_t)rand();
  out[0] = (uint8_t)(txid >> 8);
  out[1] = (uint8_t)txid;
  out[2] = 0x01;  // recursion desired
  out[3] = 0x00;
  out[4] = 0x00;
  out[5] = 0x01;  // one question
  out[6] = out[7] = out[8] = out[9] = out[10] = out[11] = 0;
  size_t name_len = encode_name(out + 12, name);
  if (name_len == 0 || 12 + name_len + 4 > sizeof(out)) return -1;
  size_t pos = 12 + name_len;
  out[pos++] = (uint8_t)(qtype >> 8);
  out[pos++] = (uint8_t)qtype;
  out[pos++] = 0x00;
  out[pos++] = 0x01;  // IN
  size_t out_len = pos;

  int fd = socket(server->family, SOCK_DGRAM, 0);
  if (fd < 0) return -1;
  socklen_t addr_len = server->family == AF_INET
      ? sizeof(struct sockaddr_in)
      : sizeof(struct sockaddr_in6);
  if (sendto(
        fd, out, out_len, 0, (const struct sockaddr *)&server->ss, addr_len
      ) != (ssize_t)out_len) {
    close(fd);
    return -1;
  }
  struct pollfd pfd = {.fd = fd, .events = POLLIN};
  if (poll(&pfd, 1, DNS_TIMEOUT_MS) <= 0) {
    close(fd);
    return -1;
  }
  static uint8_t in[DNS_MAX_MSG];
  ssize_t in_len = recv(fd, in, sizeof(in), 0);
  close(fd);
  if (in_len < 12) return -1;
  if ((uint16_t)((in[0] << 8) | in[1]) != txid) return -1;
  if (!(in[2] & 0x80)) return -1;  // not a response
  uint8_t rcode = in[3] & 0x0F;
  if (rcode == 3) return 0;  // NXDOMAIN: a clean no
  if (rcode != 0) return -1;
  if (in[2] & 0x02) return -1;  // truncated: no TCP fallback in v1
  uint16_t ancount = (uint16_t)((in[6] << 8) | in[7]);
  pos = 12;
  // Skip the question section.
  for (int qd = 0; qd < 1; qd++) {
    size_t skip = name_skip(in, (size_t)in_len, pos);
    if (skip == 0 || pos + skip + 4 > (size_t)in_len) return -1;
    pos += skip + 4;
  }

  char cnames[DNS_MAX_CNAME + 1][256];
  int cname_count = 0;
  int found = 0;
  for (uint16_t a = 0; a < ancount; a++) {
    char owner[256];
    if (name_unpack(in, (size_t)in_len, pos, owner, sizeof(owner)) != 0) {
      return -1;
    }
    size_t skip = name_skip(in, (size_t)in_len, pos);
    if (skip == 0 || pos + skip + 10 > (size_t)in_len) return -1;
    pos += skip;
    uint16_t type = (uint16_t)((in[pos] << 8) | in[pos + 1]);
    // uint16_t class = ...; skipped, IN expected
    uint16_t rdlen = (uint16_t)((in[pos + 8] << 8) | in[pos + 9]);
    pos += 10;
    if (pos + rdlen > (size_t)in_len) return -1;
    if (type == 5 && cname_count <= DNS_MAX_CNAME) {  // CNAME
      if (name_unpack(in, (size_t)in_len, pos, cnames[cname_count],
                      sizeof(cnames[0])) == 0) {
        cname_count++;
      }
    } else if (
      (type == 1 && qtype == 1 && rdlen == 4) ||
      (type == 28 && qtype == 28 && rdlen == 16)) {
      if (found >= max_answers) {
        pos += rdlen;
        continue;
      }
      // Accepted if the owner is the question or a chased CNAME.
      int ok = name_equal_nocase(owner, name);
      for (int c = 0; !ok && c < cname_count; c++) {
        ok = name_equal_nocase(owner, cnames[c]);
      }
      if (ok) {
        answers[found].family = type == 1 ? AF_INET : AF_INET6;
        memcpy(answers[found].addr, in + pos, rdlen);
        found++;
      }
    }
    pos += rdlen;
  }
  // CNAMEs whose targets arrived as further answers are already collected
  // above through the owner check; a bare CNAME with nothing behind it is a
  // no for this query type.
  (void)cnames;
  (void)cname_count;
  return found;
}

// --- resolution ---------------------------------------------------------------

static int resolve_name(
  const char *name,
  int family,
  dns_answer_t *answers,
  int max_answers
) {
  int want_v4 = family == AF_UNSPEC || family == AF_INET;
  int want_v6 = family == AF_UNSPEC || family == AF_INET6;
  int found = 0;
  int timeouts = 0;
  int queries = 0;
  // A then AAAA, each server in turn. A bare NXDOMAIN stops the hunt for that
  // type; anything inconclusive moves to the next server.
  for (int pass = 0; pass < 2; pass++) {
    int want = pass == 0 ? want_v4 : want_v6;
    if (!want) continue;
    uint16_t qtype = pass == 0 ? 1 : 28;
    int answered = 0;
    for (int s = 0; s < g_server_count; s++) {
      queries++;
      int r = dns_query(
        &g_servers[s], name, qtype, answers + found, max_answers - found
      );
      if (r > 0) {
        found += r;
        answered = 1;
        break;
      }
      if (r == 0) {
        answered = 1;  // NXDOMAIN: asking elsewhere will not help
        break;
      }
      timeouts++;
    }
    (void)answered;
  }
  if (found > 0) return found;
  return queries > 0 && timeouts >= queries ? -2 : 0;
}

static int service_port(const char *service) {
  if (!service || !*service) return 0;
  char *end = NULL;
  long port = strtol(service, &end, 10);
  if (end && *end == '\0' && port > 0 && port < 65536) return (int)port;
  if (strcmp(service, "http") == 0) return 80;
  if (strcmp(service, "https") == 0) return 443;
  return -1;
}

// --- toolchain compatibility ---------------------------------------------------
// The NDK's startup objects reference __register_atfork, a bionic/glibc
// symbol the musl loader does not have, and the server refuses to start over
// it. Nothing in this process can call it meaningfully — every other object
// here is musl, which has no such registry — so it is satisfied locally.
// Hidden visibility is load-bearing: an exported __register_atfork changes
// process-wide symbol resolution (something in the server keys off its
// presence and breaks its own listen), while a hidden one only satisfies the
// toolchain's internal reference.
__attribute__((visibility("hidden")))
int __register_atfork(void *prepare, void *parent, void *child, void *dso) {
  (void)prepare;
  (void)parent;
  (void)child;
  (void)dso;
  return 0;
}

// --- the interposed API ---------------------------------------------------------

int getaddrinfo(
  const char *node,
  const char *service,
  const struct addrinfo *hints,
  struct addrinfo **res
) {
  if (!res) return EAI_NONAME;
  *res = NULL;

  // Escape hatch for diagnosis: answer from the real resolver instead of the
  // shim's own. If the server starts like this, the interposition mechanism
  // is innocent and the bytes the shim builds are the poison.
  if (getenv("OPENCODE_DNS_PASSTHROUGH") != NULL) {
    static int (*real_gai)(
      const char *, const char *, const struct addrinfo *,
      struct addrinfo **) = NULL;
    if (!real_gai) {
      real_gai = dlsym(RTLD_NEXT, "getaddrinfo");
    }
    if (real_gai) return real_gai(node, service, hints, res);
  }

  int family = AF_UNSPEC;
  int socktype = 0;
  int protocol = 0;
  int flags = 0;
  if (hints) {
    family = hints->ai_family;
    socktype = hints->ai_socktype;
    protocol = hints->ai_protocol;
    flags = hints->ai_flags;
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6) {
      return EAI_FAMILY;
    }
  }

  int port = service_port(service);
  if (port < 0) return EAI_SERVICE;

  SHIM_LOG(
    "lookup node=%s service=%s family=%d socktype=%d\n",
    node ? node : "(null)",
    service ? service : "(null)",
    family,
    socktype
  );

  // Wildcard bind: no lookup involved.
  if (!node || !*node) {
    struct addrinfo *ai = calloc(1, sizeof(*ai));
    struct sockaddr_storage *ss = calloc(1, sizeof(*ss));
    if (!ai || !ss) {
      free(ai);
      free(ss);
      return EAI_MEMORY;
    }
    int fam = family == AF_UNSPEC ? AF_INET : family;
    if (fam == AF_INET6) {
      ((struct sockaddr_in6 *)ss)->sin6_family = AF_INET6;
      ((struct sockaddr_in6 *)ss)->sin6_port = htons((uint16_t)port);
      ai->ai_addrlen = sizeof(struct sockaddr_in6);
    } else {
      ((struct sockaddr_in *)ss)->sin_family = AF_INET;
      ((struct sockaddr_in *)ss)->sin_port = htons((uint16_t)port);
      ai->ai_addrlen = sizeof(struct sockaddr_in);
    }
    ai->ai_family = fam;
    ai->ai_socktype = socktype ? socktype : SOCK_STREAM;
    ai->ai_protocol = protocol;
    ai->ai_addr = (struct sockaddr *)ss;
    SHIM_LOG("-> wildcard\n");
    *res = ai;
    return 0;
  }

  uint8_t literal[16];
  int literal_family = 0;
  if (inet_pton(AF_INET, node, literal) == 1) {
    literal_family = AF_INET;
  } else if (inet_pton(AF_INET6, node, literal) == 1) {
    literal_family = AF_INET6;
  }
  int is_localhost = name_equal_nocase(node, "localhost");

  dns_answer_t answers[DNS_MAX_ADDRS];
  int addr_count = 0;
  int addr_family[DNS_MAX_ADDRS];

  if (literal_family) {
    if (family != AF_UNSPEC && family != literal_family) return EAI_NONAME;
    memcpy(answers[0].addr, literal,
           literal_family == AF_INET ? 4 : 16);
    answers[0].family = literal_family;
    addr_count = 1;
  } else if (is_localhost) {
    if (family == AF_UNSPEC || family == AF_INET) {
      answers[addr_count].family = AF_INET;
      // 127.0.0.1 in network order.
      answers[addr_count].addr[0] = 127;
      answers[addr_count].addr[1] = 0;
      answers[addr_count].addr[2] = 0;
      answers[addr_count].addr[3] = 1;
      addr_count++;
    }
    if ((family == AF_UNSPEC || family == AF_INET6) &&
        addr_count < DNS_MAX_ADDRS) {
      answers[addr_count].family = AF_INET6;
      memset(answers[addr_count].addr, 0, 16);
      answers[addr_count].addr[15] = 1;
      addr_count++;
    }
  } else {
    int r = resolve_name(node, family, answers, DNS_MAX_ADDRS);
    if (r == -2) return EAI_AGAIN;
    if (r <= 0) return EAI_NONAME;
    addr_count = r;
  }
  (void)addr_family;

  int types[2];
  int type_count = 0;
  if (socktype) {
    types[type_count++] = socktype;
  } else {
    types[type_count++] = SOCK_STREAM;
    types[type_count++] = SOCK_DGRAM;
  }

  struct addrinfo *head = NULL;
  struct addrinfo **link = &head;
  for (int i = 0; i < addr_count; i++) {
    for (int t = 0; t < type_count; t++) {
      struct addrinfo *ai = calloc(1, sizeof(*ai));
      if (!ai) goto oom;
      ai->ai_family = answers[i].family;
      ai->ai_socktype = types[t];
      ai->ai_protocol = protocol
          ? protocol
          : (types[t] == SOCK_DGRAM ? IPPROTO_UDP : IPPROTO_TCP);
      ai->ai_flags = flags;
      if (answers[i].family == AF_INET) {
        struct sockaddr_in *sin = calloc(1, sizeof(*sin));
        if (!sin) {
          free(ai);
          goto oom;
        }
        sin->sin_family = AF_INET;
        sin->sin_port = htons((uint16_t)port);
        memcpy(&sin->sin_addr, answers[i].addr, 4);
        ai->ai_addr = (struct sockaddr *)sin;
        ai->ai_addrlen = sizeof(*sin);
      } else {
        struct sockaddr_in6 *sin6 = calloc(1, sizeof(*sin6));
        if (!sin6) {
          free(ai);
          goto oom;
        }
        sin6->sin6_family = AF_INET6;
        sin6->sin6_port = htons((uint16_t)port);
        memcpy(&sin6->sin6_addr, answers[i].addr, 16);
        ai->ai_addr = (struct sockaddr *)sin6;
        ai->ai_addrlen = sizeof(*sin6);
      }
      if (flags & AI_CANONNAME) {
        ai->ai_canonname = strdup(node);
        if (!ai->ai_canonname) {
          free(ai->ai_addr);
          free(ai);
          goto oom;
        }
      }
      *link = ai;
      link = &ai->ai_next;
    }
  }
  if (!head) return EAI_NONAME;
  SHIM_LOG("-> %d address(es)\n", addr_count);
  *res = head;
  return 0;

oom: {
  struct addrinfo *ai = head;
  while (ai) {
    struct addrinfo *next = ai->ai_next;
    free(ai->ai_addr);
    free(ai->ai_canonname);
    free(ai);
    ai = next;
  }
  return EAI_MEMORY;
}
}

void freeaddrinfo(struct addrinfo *res) {
  struct addrinfo *ai = res;
  while (ai) {
    struct addrinfo *next = ai->ai_next;
    free(ai->ai_addr);
    free(ai->ai_canonname);
    free(ai);
    ai = next;
  }
}
