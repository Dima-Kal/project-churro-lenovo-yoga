/*
 * churro-yoga: Lenovo Yoga 2-in-1 convertible tablet mode & auto-rotation daemon.
 * Monitors Intel ISHTP hinge angle (custom_intel_hinge) and 3D accelerometer (accel_3d):
 * - Hinge >= 195 deg: inhibits AT keyboard & touchpad, emits SW_TABLET_MODE=1, shows virtual keyboard.
 * - Hinge <= 175 deg: enables AT keyboard & touchpad, emits SW_TABLET_MODE=0, restores normal rotation.
 * - Auto-rotation: 4-way rotation (0=Landscape, 1=Portrait, 2=Tent/180 deg, 3=Inv Portrait).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>

#define MAX_TOUCHPADS 8

static char kbd_inhibit[512];
static char tp_inhibit[MAX_TOUCHPADS][512];
static int tp_count = 0;
static char hinge_path[512];
static char accel_x_path[512];
static char accel_y_path[512];
static char accel_z_path[512];
static int uinput_fd = -1;

static int write_str(const char *path, const char *val) {
    if (!path[0]) return -1;
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    int ret = write(fd, val, strlen(val));
    close(fd);
    return ret;
}

static int read_int(const char *path) {
    if (!path[0]) return 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char buf[64];
    memset(buf, 0, sizeof(buf));
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    return atoi(buf);
}

static void send_switch(int fd, int code, int value) {
    if (fd < 0) return;
    struct input_event ev[2];
    memset(ev, 0, sizeof(ev));
    ev[0].type = EV_SW;
    ev[0].code = code;
    ev[0].value = value;
    ev[1].type = EV_SYN;
    ev[1].code = SYN_REPORT;
    ev[1].value = 0;
    if (write(fd, ev, sizeof(ev)) < 0) {
        // ignore
    }
}

static void scan_inputs(void) {
    DIR *d = opendir("/sys/class/input");
    if (!d) return;
    struct dirent *de;
    tp_count = 0;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "input", 5) != 0) continue;
        char name_path[512], name_buf[128];
        snprintf(name_path, sizeof(name_path), "/sys/class/input/%s/name", de->d_name);
        int fd = open(name_path, O_RDONLY);
        if (fd < 0) continue;
        memset(name_buf, 0, sizeof(name_buf));
        int n = read(fd, name_buf, sizeof(name_buf) - 1);
        close(fd);
        if (n <= 0) continue;
        while (n > 0 && (name_buf[n - 1] == '\n' || name_buf[n - 1] == '\r')) name_buf[--n] = '\0';

        if (strstr(name_buf, "AT Translated Set 2 keyboard") ||
            (strstr(name_buf, "keyboard") && !strstr(name_buf, "Virtual") && !strstr(name_buf, "churro"))) {
            snprintf(kbd_inhibit, sizeof(kbd_inhibit), "/sys/class/input/%s/inhibited", de->d_name);
            printf("churro-yoga: found internal keyboard: %s -> %s\n", name_buf, kbd_inhibit);
        } else if (strstr(name_buf, "Touchpad") || strstr(name_buf, "touchpad") || strstr(name_buf, "06CB:CE44 Mouse")) {
            if (tp_count < MAX_TOUCHPADS) {
                snprintf(tp_inhibit[tp_count], sizeof(tp_inhibit[0]), "/sys/class/input/%s/inhibited", de->d_name);
                printf("churro-yoga: found internal touchpad: %s -> %s\n", name_buf, tp_inhibit[tp_count]);
                tp_count++;
            }
        }
    }
    closedir(d);
}

static void scan_iio(void) {
    DIR *d = opendir("/sys/bus/iio/devices");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "iio:device", 10) != 0) continue;
        char name_path[512], name_buf[128];
        snprintf(name_path, sizeof(name_path), "/sys/bus/iio/devices/%s/name", de->d_name);
        int fd = open(name_path, O_RDONLY);
        if (fd < 0) continue;
        memset(name_buf, 0, sizeof(name_buf));
        int n = read(fd, name_buf, sizeof(name_buf) - 1);
        close(fd);
        if (n <= 0) continue;
        while (n > 0 && (name_buf[n - 1] == '\n' || name_buf[n - 1] == '\r')) name_buf[--n] = '\0';

        if (strstr(name_buf, "hinge") || strstr(name_buf, "custom_intel_hinge")) {
            char test_path[512];
            snprintf(test_path, sizeof(test_path), "/sys/bus/iio/devices/%s/in_angl0_raw", de->d_name);
            if (access(test_path, R_OK) == 0) {
                strncpy(hinge_path, test_path, sizeof(hinge_path) - 1);
                printf("churro-yoga: found hinge sensor: %s at %s\n", name_buf, hinge_path);
            } else {
                snprintf(test_path, sizeof(test_path), "/sys/bus/iio/devices/%s/in_angl0_input", de->d_name);
                if (access(test_path, R_OK) == 0) {
                    strncpy(hinge_path, test_path, sizeof(hinge_path) - 1);
                    printf("churro-yoga: found hinge sensor: %s at %s\n", name_buf, hinge_path);
                }
            }
        } else if (strstr(name_buf, "accel_3d") || strstr(name_buf, "cros-ec-accel") || strstr(name_buf, "accel")) {
            snprintf(accel_x_path, sizeof(accel_x_path), "/sys/bus/iio/devices/%s/in_accel_x_raw", de->d_name);
            snprintf(accel_y_path, sizeof(accel_y_path), "/sys/bus/iio/devices/%s/in_accel_y_raw", de->d_name);
            snprintf(accel_z_path, sizeof(accel_z_path), "/sys/bus/iio/devices/%s/in_accel_z_raw", de->d_name);
            printf("churro-yoga: found 3D accelerometer: %s (%s)\n", name_buf, accel_x_path);
        }
    }
    closedir(d);
}

static int init_uinput(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_SW);
    ioctl(fd, UI_SET_SWBIT, SW_TABLET_MODE);
    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_VIRTUAL;
    strcpy(usetup.name, "Churro Yoga Tablet Switch");
    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void set_inhibit(int state) {
    const char *s = state ? "1" : "0";
    if (kbd_inhibit[0]) write_str(kbd_inhibit, s);
    for (int i = 0; i < tp_count; i++) {
        write_str(tp_inhibit[i], s);
    }
}

int main(void) {
    printf("churro-yoga: starting Lenovo Yoga convertible daemon\n");
    uinput_fd = init_uinput();
    if (uinput_fd < 0) {
        fprintf(stderr, "churro-yoga: warning: could not open /dev/uinput\n");
    }

    int in_tablet_mode = 0;
    int cur_rotation = 0, candidate_rotation = 0, stable_rot_count = 0;

    for (int init_try = 0; init_try < 20; init_try++) {
        if (!kbd_inhibit[0]) scan_inputs();
        if (!hinge_path[0] || !accel_x_path[0]) scan_iio();
        if (kbd_inhibit[0] && (hinge_path[0] || accel_x_path[0])) break;
        usleep(500000);
    }

    // Default to laptop mode at boot
    set_inhibit(0);
    send_switch(uinput_fd, SW_TABLET_MODE, 0);

    while (1) {
        usleep(350000); // Poll ~3 times per second

        // Periodic rescan if devices were not ready at boot
        if (!kbd_inhibit[0] || !hinge_path[0]) {
            scan_inputs();
            scan_iio();
        }

        int hinge_deg = 0;
        if (hinge_path[0]) {
            hinge_deg = read_int(hinge_path);
        }

        // Tablet mode threshold: >= 195 deg enters tablet mode, <= 175 deg returns to laptop mode
        if (hinge_deg >= 195) {
            if (!in_tablet_mode) {
                in_tablet_mode = 1;
                set_inhibit(1);
                send_switch(uinput_fd, SW_TABLET_MODE, 1);
                int r = system("settings put secure show_ime_with_hard_keyboard 1 2>/dev/null &");
                (void)r;
                printf("churro-yoga: entered tablet mode (hinge=%d deg) -> keyboard/touchpad inhibited, SW_TABLET_MODE=1\n", hinge_deg);
            }
        } else if (hinge_deg > 0 && hinge_deg <= 175) {
            if (in_tablet_mode) {
                in_tablet_mode = 0;
                set_inhibit(0);
                send_switch(uinput_fd, SW_TABLET_MODE, 0);
                int r = system("content insert --uri content://settings/system --bind name:s:user_rotation --bind value:i:0 2>/dev/null &");
                (void)r;
                cur_rotation = 0;
                printf("churro-yoga: restored laptop mode (hinge=%d deg) -> keyboard/touchpad active, rotation=0\n", hinge_deg);
            }
        }

        // Auto-rotation when in tablet mode or if hinge is folded
        if (in_tablet_mode && accel_x_path[0] && accel_y_path[0]) {
            int ax = read_int(accel_x_path);
            int ay = read_int(accel_y_path);
            int az = read_int(accel_z_path);

            int abs_x = abs(ax);
            int abs_y = abs(ay);
            int abs_z = abs(az);

            // Ignore when laptop is flat on table (Z dominant)
            if (abs_z < 8500 || (abs_x + abs_y > 3500)) {
                int new_rot = cur_rotation;
                if (abs_y >= abs_x) {
                    new_rot = (ay < 0) ? 0 : 2; // 0=Landscape normal, 2=Tent / 180 deg
                } else {
                    new_rot = (ax < 0) ? 1 : 3; // 1=Portrait (90 deg), 3=Inverted Portrait (270 deg)
                }

                if (new_rot == candidate_rotation) {
                    stable_rot_count++;
                    if (stable_rot_count >= 2 && new_rot != cur_rotation) {
                        cur_rotation = new_rot;
                        char cmd[128];
                        snprintf(cmd, sizeof(cmd), "content insert --uri content://settings/system --bind name:s:user_rotation --bind value:i:%d 2>/dev/null &", cur_rotation);
                        int r = system(cmd);
                        (void)r;
                        printf("churro-yoga: auto-rotated to %d (ax=%d, ay=%d, az=%d)\n", cur_rotation, ax, ay, az);
                    }
                } else {
                    candidate_rotation = new_rot;
                    stable_rot_count = 0;
                }
            }
        }
    }

    if (uinput_fd >= 0) close(uinput_fd);
    return 0;
}
