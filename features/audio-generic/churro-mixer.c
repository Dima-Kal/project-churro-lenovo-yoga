/* churro-mixer <card index>: unmute an ALSA card the way `alsactl init` does on Linux desktops.
 * The kernel creates HD-audio's "Master" muted at volume 0 and leaves unmuting to userspace;
 * Google's audio HAL only sets the controls its board config names, so on a PC nothing does.
 * Sets every "... Playback Switch" (except beep) and "Capture Switch" on, and
 * "Master Playback Volume" to its maximum (0 dB: the HDA followers sit at 0 dB), all channels,
 * using each control's own range: works for mono and stereo controls on any codec.
 * Static (built with the host compiler like the boot logger), run by get_variant_audio. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>

int main(int argc, char **argv)
{
	char path[64];
	struct snd_ctl_elem_list list = {0};
	struct snd_ctl_elem_id *ids;
	unsigned i, c, done = 0;
	int fd;

	if (argc != 2)
		return 2;
	snprintf(path, sizeof(path), "/dev/snd/controlC%s", argv[1]);
	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0 || ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
		perror(path);
		return 1;
	}
	ids = calloc(list.count, sizeof(*ids));
	list.space = list.count;
	list.pids = ids;
	if (!ids || ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0)
		return 1;
	for (i = 0; i < list.used; i++) {
		const char *name = (const char *)ids[i].name;
		int sw = (strstr(name, "Playback Switch") && !strstr(name, "Beep")) ||
			 !strcmp(name, "Capture Switch");
		int vol = !strcmp(name, "Master Playback Volume");
		struct snd_ctl_elem_info info = { .id = ids[i] };
		struct snd_ctl_elem_value v = { .id = ids[i] };

		if ((!sw && !vol) || ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0)
			continue;
		if (info.type != (sw ? SNDRV_CTL_ELEM_TYPE_BOOLEAN : SNDRV_CTL_ELEM_TYPE_INTEGER))
			continue;
		for (c = 0; c < info.count && c < 128; c++)
			v.value.integer.value[c] = sw ? 1 : info.value.integer.max;
		if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &v) == 0)
			done++;
	}
	printf("churro-mixer: card %s: %u controls set\n", argv[1], done);
	return 0;
}
