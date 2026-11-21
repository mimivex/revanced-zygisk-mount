#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <vector>

#include "zygisk.hpp"

#define ARR_LEN(a) (sizeof(a) / (sizeof((a)[0])))
#define LOGD(fmt, ...) \
    __android_log_print(ANDROID_LOG_DEBUG, "revanced-zygisk-mount", "[%d] " fmt, __LINE__, ##__VA_ARGS__)

static bool readFull(int fd, void* data, size_t size) {
    auto* ptr = static_cast<char*>(data);
    size_t done = 0;
    while (done < size) {
        ssize_t ret = read(fd, ptr + done, size - done);
        if (ret < 0 && errno == EINTR) continue;
        if (ret <= 0) return false;
        done += static_cast<size_t>(ret);
    }
    return true;
}

static bool writeFull(int fd, const void* data, size_t size) {
    const auto* ptr = static_cast<const char*>(data);
    size_t done = 0;
    while (done < size) {
        ssize_t ret = write(fd, ptr + done, size - done);
        if (ret < 0 && errno == EINTR) continue;
        if (ret <= 0) return false;
        done += static_cast<size_t>(ret);
    }
    return true;
}

static bool sendProcInfo(int fd, const char* proc) {
    pid_t pid = getpid();
    if (!writeFull(fd, &pid, sizeof(pid))) {
        LOGD("ERROR write: %s", strerror(errno));
        return false;
    }

    unsigned int proc_len = strlen(proc) + 1;
    if (!writeFull(fd, &proc_len, sizeof(proc_len))) {
        LOGD("ERROR write: %s", strerror(errno));
        return false;
    }

    if (!writeFull(fd, proc, proc_len)) {
        LOGD("ERROR write: %s", strerror(errno));
        return false;
    }

    return true;
}

class RevancedZygiskMount : public zygisk::ModuleBase {
   public:
    void onLoad(zygisk::Api* api, JNIEnv* env) override {
        this->api = api;
        this->env = env;
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs* args) override {
        (void)args;
        api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs* args) override {
        // Zygisk Next can invoke app specialization with no process name for
        // short-lived/internal processes. Calling GetStringUTFChars with a
        // null jstring aborts in Android's JNI implementation ("string
        // pointer is null"), which otherwise causes a respawn loop at boot.
        if (api == nullptr || env == nullptr || args == nullptr || args->nice_name == nullptr) {
            if (api != nullptr) api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        const char* proc = env->GetStringUTFChars(args->nice_name, NULL);
        if (!proc) {
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        int fd = api->connectCompanion();
        if (fd < 0) {
            LOGD("connectCompanion failed: %s", strerror(errno));
        } else if (!sendProcInfo(fd, proc)) {
            LOGD("failed to send process info for %s", proc);
        }

        if (fd >= 0) close(fd);
        env->ReleaseStringUTFChars(args->nice_name, proc);
        api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

   private:
    zygisk::Api* api;
    JNIEnv* env;
};

static bool getMountSrcDst(const char* procs_map, const char* proc, const char** src, const char** dst) {
    uint8_t proc_len = strlen(proc);

    size_t i = 0;
    uint8_t tplen;
    while ((tplen = procs_map[i])) {
        const char* tpptr = procs_map + i + sizeof(tplen);

        uint8_t _len = tplen;
        for (size_t j = 0; j < 3; j++) {
            i += sizeof(_len) + _len + 1;
            _len = procs_map[i];
        }

        if (tplen != proc_len) continue;
        if (memcmp(tpptr, proc, tplen) != 0) continue;

        *src = tpptr + tplen + 2 * sizeof(uint8_t);
        uint8_t src_len = *(uint8_t*)(tpptr + tplen + sizeof(uint8_t));
        *dst = *src + src_len + 2 * sizeof(uint8_t);

        return true;
    }
    return false;
}

static char* readFileToNullStr(const char* path) {
    char* buf = nullptr;
    off_t size_read = 0;

    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        LOGD("ERROR open %s: %s", path, strerror(errno));
        goto defer;
    }

    struct stat st;
    if (fstat(fd, &st) == -1) {
        LOGD("ERROR fstat: %s", strerror(errno));
        goto defer;
    }
    if (st.st_size <= 0) {
        LOGD("ERROR %s is empty (size=%d)", path, (int)st.st_size);
        goto defer;
    }

    buf = (char*)malloc(st.st_size + 1);
    while (size_read < st.st_size) {
        ssize_t ret = read(fd, buf + size_read, st.st_size - size_read);
        if (ret < 0) {
            LOGD("ERROR read: %s", strerror(errno));
            free(buf);
            buf = nullptr;
            goto defer;
        } else {
            size_read += ret;
        }
    }
    buf[st.st_size] = 0;

defer:
    close(fd);
    return buf;
}

static pid_t parentPid(pid_t pid) {
    char path[64];
    snprintf(path, ARR_LEN(path), "/proc/%d/status", pid);

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd == -1) return -1;

    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;

    char* ppid = strstr(buf, "\nPPid:");
    return ppid ? static_cast<pid_t>(atoi(ppid + 6)) : -1;
}

// Zygisk runs preAppSpecialize before zygote finishes specializing the
// process, so when the request arrives the app still shares zygote's mount
// namespace. A bind mounted there is copied into every process zygote starts
// afterwards, and the app itself can miss it if it unshares first. Wait
// until the process has a namespace of its own before mounting into it.
static bool waitForPrivateMountNamespace(pid_t pid) {
    char ns_path[64];
    snprintf(ns_path, ARR_LEN(ns_path), "/proc/%d/ns/mnt", pid);

    pid_t ppid = parentPid(pid);
    if (ppid <= 0) return false;

    char parent_ns_path[64];
    snprintf(parent_ns_path, ARR_LEN(parent_ns_path), "/proc/%d/ns/mnt", ppid);

    struct stat parent_ns;
    if (stat(parent_ns_path, &parent_ns) == -1) return false;

    // Specialization takes milliseconds. A second is already generous, and
    // the companion waits on its own: the app is not blocked by this.
    for (int i = 0; i < 1000; i++) {
        struct stat ns;
        if (stat(ns_path, &ns) == -1) {
            if (errno == ENOENT) return false;
        } else if (ns.st_dev != parent_ns.st_dev || ns.st_ino != parent_ns.st_ino) {
            return true;
        }
        usleep(1000);
    }
    return false;
}

static bool injectMount(const char* src, const char* dst, pid_t pid) {
    if (!waitForPrivateMountNamespace(pid)) {
        LOGD("ERROR pid=%d never left the zygote mount namespace; not mounting", pid);
        return false;
    }

    // The companion was spawned by the engine daemon, so the namespace it
    // starts in is the one the engine runs in. Remember it: the bind must
    // not be created there, or every process started afterwards would
    // inherit it. The wait above can only be fooled by an engine whose
    // daemon lives in a namespace of its own, and in that case skipping the
    // mount is better than exposing it.
    struct stat start_ns;
    if (stat("/proc/self/ns/mnt", &start_ns) == -1) {
        LOGD("ERROR stat self namespace: %s", strerror(errno));
        return false;
    }

    char ns_path[64];
    snprintf(ns_path, ARR_LEN(ns_path), "/proc/%d/ns/mnt", pid);

    int ns_fd = open(ns_path, O_RDONLY);
    if (ns_fd == -1) {
        LOGD("ERROR open (%s): %s", ns_path, strerror(errno));
        return false;
    }

    int r = setns(ns_fd, CLONE_NEWNS);
    close(ns_fd);
    if (r == -1) {
        LOGD("ERROR setns: %s", strerror(errno));
        return false;
    }

    struct stat now_ns;
    if (stat("/proc/self/ns/mnt", &now_ns) == -1) {
        LOGD("ERROR stat self namespace: %s", strerror(errno));
        return false;
    }
    if (now_ns.st_dev == start_ns.st_dev && now_ns.st_ino == start_ns.st_ino) {
        LOGD("ERROR pid=%d is still in the namespace this companion started in; not mounting", pid);
        return false;
    }

    // unshare keeps the propagation flags, so make this namespace a slave of
    // its parent before mounting: the bind must not travel back to zygote if
    // the ROM left the mount shared. A namespace that is already slave is
    // unaffected.
    mount(NULL, "/", NULL, MS_REC | MS_SLAVE, NULL);

    if (mount(src, dst, NULL, MS_BIND, NULL) != 0) {
        LOGD("ERROR mount: %s", strerror(errno));
        return false;
    }

    return true;
}

static bool receiveProcInfo(int fd, char** src, char** dst, pid_t* pid) {
    if (!readFull(fd, pid, sizeof(*pid))) {
        LOGD("ERROR read: %s", strerror(errno));
        return false;
    }

    unsigned int proc_len;
    if (!readFull(fd, &proc_len, sizeof(proc_len)) || proc_len == 0 || proc_len > 4096) {
        LOGD("ERROR read: %s", strerror(errno));
        return false;
    }

    std::vector<char> proc(proc_len);
    if (!readFull(fd, proc.data(), proc_len)) {
        LOGD("ERROR read: %s", strerror(errno));
        return false;
    }

    char* procs_map = readFileToNullStr("/data/adb/modules/revanced-zygisk-mount/procs_map");
    if (procs_map == nullptr) {
        LOGD("procs_map is missing or empty, nothing can be mounted");
        return false;
    }

    const char *mapped_src, *mapped_dst;
    bool r = getMountSrcDst(procs_map, proc.data(), &mapped_src, &mapped_dst);
    if (r) {
        *src = strdup(mapped_src);
        *dst = strdup(mapped_dst);
        if (!*src || !*dst) {
            free(*src);
            free(*dst);
            *src = nullptr;
            *dst = nullptr;
            r = false;
        }
    }
    free(procs_map);
    // Zygisk calls us for every app process, so a miss just means this one
    // is not patched. Stay quiet.
    if (!r) return false;

    LOGD("%s: %s -> %s", proc.data(), *src, *dst);
    return true;
}

static void companionHandler(int fd) {
    char *src = nullptr, *dst = nullptr;
    pid_t pid;
    if (!receiveProcInfo(fd, &src, &dst, &pid)) return;

    pid_t child = fork();
    if (child == 0) {
        bool ok = injectMount(src, dst, pid);
        LOGD("mount %s -> %s for pid=%d: %s", src, dst, pid, ok ? "success" : "failed");
        _exit(ok ? 0 : 1);
    } else if (child == -1) {
        LOGD("ERROR fork: %s", strerror(errno));
    }
    free(src);
    free(dst);
}

REGISTER_ZYGISK_MODULE(RevancedZygiskMount)
REGISTER_ZYGISK_COMPANION(companionHandler)
