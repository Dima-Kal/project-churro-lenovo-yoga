/*
 * Churro replacement for /vendor/bin/crossystem. Touches NO hardware, ever.
 *
 * The real tool reads/writes ChromeOS firmware state (vboot NVRAM in CMOS or flash): on a normal
 * PC that is the PC's own CMOS/firmware, so it must never run. But Googlebook's boot-control HAL
 * runs `crossystem fw_result=success fw_try_count=0` inside markBootSuccessful(); if that fails,
 * vold can't commit the userdata checkpoint and system_server reboots ("Checkpoint commit failed").
 *
 * So: any "name=value" (write) request is accepted and ignored (exit 0); reads fail like a
 * missing tool did before (exit 1), which everything already tolerates.
 */
#include <string.h>

int main(int argc, char **argv)
{
	int writes = 0;
	for (int i = 1; i < argc; i++) {
		if (!strchr(argv[i], '='))
			return 1;
		writes++;
	}
	return writes ? 0 : 1;
}
