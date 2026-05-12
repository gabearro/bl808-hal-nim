// Sample FT232H/FT232HL ADBUS pins and report ADBUS2/ADBUS3 activity.
// Build:
//   cc -O2 -Wall -Wextra -o ftdi_sample_adbus2 ftdi_sample_adbus2.c $(pkg-config --cflags --libs libftdi1)

#include <ftdi.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now_secs(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	double duration = 2.0;
	if (argc > 1)
		duration = atof(argv[1]);

	struct ftdi_context *ftdi = ftdi_new();
	if (!ftdi) {
		fprintf(stderr, "ftdi_new failed\n");
		return 1;
	}

	if (ftdi_set_interface(ftdi, INTERFACE_ANY) != 0) {
		fprintf(stderr, "ftdi_set_interface failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_usb_open(ftdi, 0x0403, 0x6014) != 0) {
		fprintf(stderr, "ftdi_usb_open failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_usb_reset(ftdi) != 0) {
		fprintf(stderr, "ftdi_usb_reset failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_set_latency_timer(ftdi, 1) != 0) {
		fprintf(stderr, "ftdi_set_latency_timer failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_set_bitmode(ftdi, 0x00, BITMODE_BITBANG) != 0) {
		fprintf(stderr, "ftdi_set_bitmode failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	double start = now_secs();
	bool first = true;
	uint8_t prev2 = 0;
	uint8_t prev3 = 0;
	unsigned long samples = 0;
	unsigned long toggles2 = 0;
	unsigned long high2 = 0;
	unsigned long low2 = 0;
	unsigned long toggles3 = 0;
	unsigned long high3 = 0;
	unsigned long low3 = 0;

	while ((now_secs() - start) < duration) {
		unsigned char pins = 0;
		if (ftdi_read_pins(ftdi, &pins) != 0) {
			fprintf(stderr, "ftdi_read_pins failed: %s\n", ftdi_get_error_string(ftdi));
			ftdi_disable_bitbang(ftdi);
			ftdi_usb_close(ftdi);
			ftdi_free(ftdi);
			return 1;
		}

		uint8_t bit2 = (pins >> 2) & 1;
		uint8_t bit3 = (pins >> 3) & 1;
		if (bit2)
			high2++;
		else
			low2++;

		if (bit3)
			high3++;
		else
			low3++;

		if (first) {
			prev2 = bit2;
			prev3 = bit3;
			first = false;
		} else {
			if (bit2 != prev2) {
				toggles2++;
				prev2 = bit2;
			}

			if (bit3 != prev3) {
				toggles3++;
				prev3 = bit3;
			}
		}

		samples++;
		usleep(1000);
	}

	printf("samples=%lu"
		" adbus2_toggles=%lu adbus2_high=%lu adbus2_low=%lu adbus2_last=%u"
		" adbus3_toggles=%lu adbus3_high=%lu adbus3_low=%lu adbus3_last=%u\n",
		samples,
		toggles2, high2, low2, (unsigned)prev2,
		toggles3, high3, low3, (unsigned)prev3);

	ftdi_disable_bitbang(ftdi);
	ftdi_usb_close(ftdi);
	ftdi_free(ftdi);
	return 0;
}
