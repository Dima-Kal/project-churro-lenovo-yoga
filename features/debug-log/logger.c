// churro-logger: started by the kernel instead of /init (rdinit=/churro/logger, "debug" boot
// entries only). Forks a child that copies the kernel log (which also carries Android init's
// log) into boot.log on the CHURRO-LOG partition (FAT32, readable from Windows), then execs the
// real /init as PID 1.
// boot.log / boot.prev.log are created by churro.sh at a fixed size, filled with blank lines; the
// logger only overwrites them in place (text ends at the first empty line), so the FAT and the
// directory never change at boot: a hang + power button can't corrupt the file system.
// Built static by churro.sh (host cc); runs before Android's init, so no bionic needed.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define PARTNAME "CHURRO-LOG"
#define LOG_SIZE (64 << 20)  // only used to recreate a log file deleted from Windows
#define FULL_MSG "[churro-logger: boot.log full, logging stopped]\n"

static char io[65536];

// Find the CHURRO-LOG partition in sysfs ("sys" is mounted in cwd); fills major/minor.
static int find_part(unsigned *maj, unsigned *min) {
  DIR *d = opendir("sys/class/block");
  struct dirent *e;
  int found = 0;
  while (d && !found && (e = readdir(d))) {
    char p[512], buf[1024];
    snprintf(p, sizeof p, "sys/class/block/%s/uevent", e->d_name);
    FILE *f = fopen(p, "r");
    if (!f) continue;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char *maj_s = strstr(buf, "MAJOR="), *min_s = strstr(buf, "MINOR=");
    if (strstr(buf, "PARTNAME=" PARTNAME "\n") && maj_s && min_s) {
      *maj = strtoul(maj_s + 6, NULL, 10);
      *min = strtoul(min_s + 6, NULL, 10);
      found = 1;
    }
  }
  if (d) closedir(d);
  return found;
}

// Report a failed step in the kernel log itself (visible on screen / serial), return.
static void fail(const char *what) {
  char m[256];
  int e = errno, fd = open("kmsg", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return;
  if (write(fd, m, snprintf(m, sizeof m, "<3>churro-logger: %s failed: %s\n", what, strerror(e)))) {}
  close(fd);
}

// Overwrite [from, to) with blank lines.
static int fill(int fd, off_t from, off_t to) {
  memset(io, '\n', sizeof io);
  while (from < to) {
    size_t n = to - from < (off_t)sizeof io ? (size_t)(to - from) : sizeof io;
    if (pwrite(fd, io, n, from) != (ssize_t)n) return -1;
    from += n;
  }
  return 0;
}

// Length of the log text at the start of the file: it ends at the first empty line.
static off_t text_len(int fd) {
  off_t pos = 0;
  char prev = '\n';  // a file that starts with a blank line holds no text
  ssize_t n;
  while ((n = pread(fd, io, sizeof io, pos)) > 0) {
    for (ssize_t i = 0; i < n; i++) {
      if (io[i] == '\n' && prev == '\n') return pos + i;
      prev = io[i];
    }
    pos += n;
  }
  return pos;
}

// Open a log file; if it was deleted (e.g. from Windows), recreate it once, blank, fixed size.
static int open_log(const char *path) {
  int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd >= 0 || errno != ENOENT) return fd;
  fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
  if (fd >= 0 && (fill(fd, 0, LOG_SIZE) || fsync(fd))) {
    close(fd);
    return -1;
  }
  return fd;
}

// "6,1234,5678901,-;message" -> "[    5.678901] message"
static size_t format(char *rec, size_t n, char *out) {
  rec[n] = 0;
  if (rec[0] == ' ') return 0;  // continuation/dictionary line
  char *semi = strchr(rec, ';'), *c1 = strchr(rec, ','), *c2 = c1 ? strchr(c1 + 1, ',') : NULL;
  if (!semi || !c2) return 0;
  unsigned long long us = strtoull(c2 + 1, NULL, 10);
  return sprintf(out, "[%5llu.%06llu] %s", us / 1000000, us % 1000000, semi + 1);
}

static void logger(void) {
  // Private mount namespace: first-stage init moves every mount it can see into the new root
  // and aborts if one fails, so ours must stay invisible to it.
  if (unshare(CLONE_NEWNS) || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)) return;
  mkdir("/churro-log", 0700);
  if (mount("tmpfs", "/churro-log", "tmpfs", 0, "mode=0700") || chdir("/churro-log")) return;
  // relative paths from here on: init later deletes the ramdisk (incl. /churro-log) but our cwd
  // keeps this tmpfs alive. No devtmpfs in GKI -> make the device nodes ourselves.
  mkdir("sys", 0700);
  mkdir("mnt", 0700);
  if (mount("sysfs", "sys", "sysfs", 0, NULL)) return;
  mknod("kmsg", S_IFCHR | 0600, makedev(1, 11));
  int k = open("kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (k < 0) return;

  // Poll fast: the disk usually appears just before Android loads its SELinux policy, and
  // mounting is easier (fewer rules) while that hasn't happened yet.
  unsigned maj = 0, min = 0;
  for (int i = 0; !find_part(&maj, &min); i++) {
    if (i >= 3000) { errno = ENODEV; fail("finding partition " PARTNAME " (5 min)"); return; }
    usleep(100000);
  }
  if (mknod("part", S_IFBLK | 0600, makedev(maj, min))) { fail("mknod"); return; }
  if (mount("part", "mnt", "vfat", MS_NOATIME, NULL)) { fail("mounting " PARTNAME); return; }
  int out = open_log("mnt/boot.log"), prev = open_log("mnt/boot.prev.log");
  if (out < 0) { fail("opening boot.log"); return; }
  off_t size = lseek(out, 0, SEEK_END), len = text_len(out);
  if (size < 4096) { errno = EFBIG; fail("boot.log too small"); return; }

  // Rotate in place: last boot's text -> boot.prev.log (blanking its older, longer text), then
  // blank boot.log's old text.
  if (prev >= 0) {
    off_t psize = lseek(prev, 0, SEEK_END), plen = text_len(prev), pos = 0;
    off_t keep = len < psize ? len : psize;
    while (pos < keep) {
      ssize_t n = pread(out, io, keep - pos < (off_t)sizeof io ? keep - pos : (off_t)sizeof io, pos);
      if (n <= 0 || pwrite(prev, io, n, pos) != n) break;
      pos += n;
    }
    if (plen > pos) fill(prev, pos, plen < psize ? plen : psize);
    fsync(prev);
    close(prev);
  }
  if (fill(out, 0, len) || fsync(out)) { fail("blanking boot.log"); return; }

  static char rec[8193], buf[65536 + 8300];
  size_t used = 0;
  off_t pos = 0, end = size - (off_t)sizeof FULL_MSG;  // keep room for the "full" note
  for (;;) {
    ssize_t n = read(k, rec, sizeof rec - 1);
    int drained = 0;
    if (n > 0) used += format(rec, n, buf + used);
    else if (errno == EPIPE) used += sprintf(buf + used, "[churro-logger: messages lost]\n");
    else if (errno == EAGAIN) drained = 1;
    else { fail("reading kmsg"); return; }
    if (!drained && used < 65536) continue;
    if (used) {  // drained or buffer full: persist now
      int full = pos + (off_t)used > end;
      if (full) used = end - pos;  // ponytail: stop when full; a ring buffer if that ever matters
      if (pwrite(out, buf, used, pos) != (ssize_t)used) { fail("writing boot.log"); return; }
      pos += used;
      used = 0;
      if (full) {
        if (pwrite(out, FULL_MSG, sizeof FULL_MSG - 1, pos) < 0) {}
        fsync(out);
        return;
      }
      fsync(out);
    }
    if (drained) {
      struct pollfd p = {k, POLLIN, 0};
      poll(&p, 1, -1);
    }
  }
}

int main(int argc, char **argv) {
  (void)argc;
  if (fork() == 0) {
    logger();
    _exit(0);
  }
  argv[0] = "/init";
  execv("/init", argv);
  return 1;
}
