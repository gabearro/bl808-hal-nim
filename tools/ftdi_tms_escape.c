// Clock diagnostic TMS sequences with the Pine64 FT232H JTAG adapter.
// Build:
//   cc -O2 -Wall -Wextra -o ftdi_tms_escape ftdi_tms_escape.c $(pkg-config --cflags --libs libftdi1)

#include <ftdi.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PINE64_LAYOUT_DATA 0x00f8
#define PINE64_LAYOUT_DIR  0x00fb

enum chunk_kind {
	CHUNK_TMS,
	CHUNK_ESCAPE,
};

struct sequence_chunk {
	enum chunk_kind kind;
	unsigned int bits;
	uint64_t value;
};

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

static int parse_u64(const char *text, uint64_t *out, const char *name)
{
	char *end = NULL;
	errno = 0;
	unsigned long long value = strtoull(text, &end, 0);
	if (errno != 0 || end == text || *end != '\0') {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		return -1;
	}

	*out = (uint64_t)value;
	return 0;
}

static int write_all(struct ftdi_context *ftdi, const unsigned char *buf, int len)
{
	int written = 0;
	while (written < len) {
		int rc = ftdi_write_data(ftdi, (unsigned char *)buf + written, len - written);
		if (rc < 0) {
			fprintf(stderr, "ftdi_write_data failed: %s\n", ftdi_get_error_string(ftdi));
			return -1;
		}
		written += rc;
	}
	return 0;
}

struct mpsse_script {
	unsigned char data[4096];
	size_t len;
};

static int script_append(struct mpsse_script *script, unsigned char byte)
{
	if (script->len >= sizeof(script->data)) {
		fprintf(stderr, "MPSSE script too large\n");
		return -1;
	}
	script->data[script->len++] = byte;
	return 0;
}

static int script_gpio_low(struct mpsse_script *script, unsigned char data)
{
	return script_append(script, 0x80) ||
	       script_append(script, data) ||
	       script_append(script, PINE64_LAYOUT_DIR);
}

static int script_tms_chunk(struct mpsse_script *script, unsigned int bits, uint64_t value)
{
	if (bits == 0 || bits > 64) {
		fprintf(stderr, "TMS chunk width must be between 1 and 64 bits\n");
		return -1;
	}

	unsigned int offset = 0;
	while (offset < bits) {
		unsigned int this_bits = bits - offset;
		if (this_bits > 7)
			this_bits = 7;

		unsigned char data = (unsigned char)((value >> offset) & ((1u << this_bits) - 1u));
		unsigned char cmd[3] = {
			0x42,                         // Clock TMS, no read, LSB first.
			(unsigned char)(this_bits - 1),
			data,
		};
		if (script_append(script, cmd[0]) ||
		    script_append(script, cmd[1]) ||
		    script_append(script, cmd[2]))
			return -1;

		offset += this_bits;
	}

	return 0;
}

static int script_escape_chunk(struct mpsse_script *script, unsigned int edges)
{
	if (edges == 0 || edges > 64) {
		fprintf(stderr, "escape edge count must be between 1 and 64\n");
		return -1;
	}

	unsigned char data = (unsigned char)(PINE64_LAYOUT_DATA | 0x01u);
	if (script_gpio_low(script, data) != 0)
		return -1;

	for (unsigned int i = 0; i < edges; i++) {
		data ^= 0x08u;
		if (script_gpio_low(script, data) != 0)
			return -1;
	}

	return script_gpio_low(script, PINE64_LAYOUT_DATA);
}

static int append_chunk(
	struct sequence_chunk *chunks,
	size_t *count,
	enum chunk_kind kind,
	unsigned int bits,
	uint64_t value)
{
	if (*count >= 32) {
		fprintf(stderr, "too many sequence chunks\n");
		return -1;
	}
	chunks[*count].kind = kind;
	chunks[*count].bits = bits;
	chunks[*count].value = value;
	(*count)++;
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [--escape edges | --tms bits value]... [vid] [pid] [serial]\n"
		"\n"
		"If no chunks are supplied, the helper emits a cJTAG connect sequence\n"
		"matching the public J-Link sequence and the Bouffalo/CKLink OAC/EC TMS\n"
		"payloads observed in libCklink.so.\n",
		prog);
}

int main(int argc, char **argv)
{
	unsigned int vid = 0x0403;
	unsigned int pid = 0x6014;
	const char *serial = NULL;
	struct sequence_chunk chunks[32];
	size_t chunk_count = 0;
	const char *positional[3];
	int positional_count = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--tms") == 0) {
			if (i + 2 >= argc) {
				usage(argv[0]);
				return 2;
			}
			unsigned int bits;
			uint64_t value;
			if (parse_u16(argv[i + 1], &bits, "TMS bit count") != 0)
				return 2;
			if (parse_u64(argv[i + 2], &value, "TMS value") != 0)
				return 2;
			if (append_chunk(chunks, &chunk_count, CHUNK_TMS, bits, value) != 0)
				return 2;
			i += 2;
		} else if (strcmp(argv[i], "--escape") == 0) {
			if (i + 1 >= argc) {
				usage(argv[0]);
				return 2;
			}
			unsigned int edges;
			if (parse_u16(argv[i + 1], &edges, "escape edge count") != 0)
				return 2;
			if (append_chunk(chunks, &chunk_count, CHUNK_ESCAPE, edges, 0) != 0)
				return 2;
			i += 1;
		} else if (argv[i][0] == '-') {
			usage(argv[0]);
			return 2;
		} else {
			if (positional_count >= 3) {
				usage(argv[0]);
				return 2;
			}
			positional[positional_count++] = argv[i];
		}
	}

	if (positional_count > 0 && parse_u16(positional[0], &vid, "VID") != 0)
		return 2;
	if (positional_count > 1 && parse_u16(positional[1], &pid, "PID") != 0)
		return 2;
	if (positional_count > 2 && positional[2][0] != '\0')
		serial = positional[2];

	if (chunk_count == 0) {
		if (append_chunk(chunks, &chunk_count, CHUNK_ESCAPE, 10, 0) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 24, 0xffffff) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_ESCAPE, 10, 0) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 24, 0xffffff) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 1, 0x00) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_ESCAPE, 7, 0) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 4, 0x0c) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 4, 0x08) != 0 ||
		    append_chunk(chunks, &chunk_count, CHUNK_TMS, 4, 0x00) != 0)
			return 2;
	}

	struct ftdi_context *ftdi = ftdi_new();
	if (!ftdi) {
		fprintf(stderr, "ftdi_new failed\n");
		return 1;
	}

	if (ftdi_set_interface(ftdi, INTERFACE_A) != 0) {
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

	if (ftdi_tcioflush(ftdi) != 0) {
		fprintf(stderr, "ftdi_tcioflush failed: %s\n", ftdi_get_error_string(ftdi));
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

	if (ftdi_set_bitmode(ftdi, 0x0b, BITMODE_MPSSE) != 0) {
		fprintf(stderr, "ftdi_set_bitmode MPSSE failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	struct mpsse_script script = { 0 };
	if (script_gpio_low(&script, PINE64_LAYOUT_DATA) || // Keep nSRST deasserted.
	    script_append(&script, 0x8b) ||                 // Enable divide-by-5 clock.
	    script_append(&script, 0x86) ||
	    script_append(&script, 59) ||                   // 100 kHz TCK from 12 MHz base.
	    script_append(&script, 0))
		return 1;

	for (size_t i = 0; i < chunk_count; i++) {
		int rc;
		if (chunks[i].kind == CHUNK_ESCAPE)
			rc = script_escape_chunk(&script, chunks[i].bits);
		else
			rc = script_tms_chunk(&script, chunks[i].bits, chunks[i].value);
		if (rc != 0) {
			ftdi_usb_close(ftdi);
			ftdi_free(ftdi);
			return 1;
		}
	}

	// Send immediate command so the adapter drains the MPSSE queue before close.
	if (script_append(&script, 0x87) != 0) {
		ftdi_usb_close(ftdi);
		ftdi_free(ftdi);
		return 1;
	}

	if (write_all(ftdi, script.data, (int)script.len) != 0) {
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
	printf("clocked %zu TMS chunk(s) on FTDI adapter %04x:%04x", chunk_count, vid, pid);
	if (serial)
		printf(" serial=%s", serial);
	printf("\n");
	return 0;
}
