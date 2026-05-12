// Pulse the Pine64 FT232H nSRST pin without asking OpenOCD to scan JTAG.
// Build:
//   cc -O2 -Wall -Wextra -o ftdi_srst_pulse ftdi_srst_pulse.c $(pkg-config --cflags --libs libftdi1)

#include <ftdi.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int parse_u16(const char *text, unsigned int *out, const char *name)
{
	char *end = NULL;
	errno = 0;
	unsigned long value = strtoul(text, &end, 0);
	if (errno != 0 || end == text || *end != '\0' || value > 0xffff) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		return -1;
	}

	*out = (unsigned int)value;
	return 0;
}

static int write_byte(struct ftdi_context *ftdi, unsigned char value)
{
	int written = ftdi_write_data(ftdi, &value, 1);
	if (written != 1) {
		fprintf(stderr, "ftdi_write_data failed: %s\n", ftdi_get_error_string(ftdi));
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	unsigned int vid = 0x0403;
	unsigned int pid = 0x6014;
	const char *serial = NULL;

	if (argc > 1 && parse_u16(argv[1], &vid, "VID") != 0)
		return 2;
	if (argc > 2 && parse_u16(argv[2], &pid, "PID") != 0)
		return 2;
	if (argc > 3 && argv[3][0] != '\0')
		serial = argv[3];
	if (argc > 4) {
		fprintf(stderr, "usage: %s [vid] [pid] [serial]\n", argv[0]);
		return 2;
	}

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

	int open_status;
	if (serial)
		open_status = ftdi_usb_open_desc(ftdi, (int)vid, (int)pid, NULL, serial);
	else
		open_status = ftdi_usb_open(ftdi, (int)vid, (int)pid);

	if (open_status != 0) {
		fprintf(stderr, "ftdi_usb_open failed for %04x:%04x", vid, pid);
		if (serial)
			fprintf(stderr, " serial=%s", serial);
		fprintf(stderr, ": %s\n", ftdi_get_error_string(ftdi));
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_usb_reset(ftdi) != 0) {
		fprintf(stderr, "ftdi_usb_reset failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_set_bitmode(ftdi, 0x00fb, BITMODE_BITBANG) != 0) {
		fprintf(stderr, "ftdi_set_bitmode failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (write_byte(ftdi, 0x00f8) != 0)
		return 1;
	usleep(10000);
	if (write_byte(ftdi, 0x00d8) != 0)
		return 1;
	usleep(200000);
	if (write_byte(ftdi, 0x00f8) != 0)
		return 1;
	usleep(300000);

	if (ftdi_set_bitmode(ftdi, 0x0000, BITMODE_RESET) != 0) {
		fprintf(stderr, "ftdi_set_bitmode reset failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (ftdi_usb_close(ftdi) != 0) {
		fprintf(stderr, "ftdi_usb_close failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_free(ftdi);
		return 1;
	}

	ftdi_free(ftdi);
	printf("pulsed FTDI nSRST on %04x:%04x", vid, pid);
	if (serial)
		printf(" serial=%s", serial);
	printf("\n");
	return 0;
}
