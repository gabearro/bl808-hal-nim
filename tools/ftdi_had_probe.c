// Probe T-Head E902 JTAG2/HAD using the Pine64 FT232H adapter.
// Build:
//   cc -O2 -Wall -Wextra -o ftdi_had_probe ftdi_had_probe.c $(pkg-config --cflags --libs libftdi1)

#include <ftdi.h>

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PINE64_LAYOUT_DATA 0x00f8u
#define PINE64_LAYOUT_DIR  0x00fbu

#define PIN_TCK 0x01u
#define PIN_TDI 0x02u
#define PIN_TDO 0x04u
#define PIN_TMS 0x08u

#define HAD_RS_HAD_IR 0x02u
#define HAD_RS_HAD_DR 0x03u
#define HACR_RW       0x80u
#define HAD_REG_ID    0x02u

struct mpsse_script {
	unsigned char data[32768];
	size_t len;
	unsigned int reads;
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

static int parse_u32(const char *text, unsigned int *out, const char *name)
{
	char *end = NULL;
	errno = 0;
	unsigned long value = strtoul(text, &end, 0);
	if (errno != 0 || end == text || *end != '\0' || value > 0xfffffffful) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		return -1;
	}
	*out = (unsigned int)value;
	return 0;
}

static int script_append(struct mpsse_script *script, unsigned char byte)
{
	if (script->len >= sizeof(script->data)) {
		fprintf(stderr, "MPSSE script too large\n");
		return -1;
	}
	script->data[script->len++] = byte;
	return 0;
}

static int script_gpio(struct mpsse_script *script, unsigned char data, unsigned char dir)
{
	return script_append(script, 0x80) ||
	       script_append(script, data) ||
	       script_append(script, dir);
}

static int script_read_low(struct mpsse_script *script)
{
	if (script_append(script, 0x81) != 0)
		return -1;
	script->reads++;
	return 0;
}

static unsigned char base_data(bool tck_high, bool tms_high)
{
	unsigned char data = (unsigned char)PINE64_LAYOUT_DATA;
	data &= (unsigned char)~PIN_TCK;
	if (tck_high)
		data |= PIN_TCK;
	if (tms_high)
		data |= PIN_TMS;
	else
		data &= (unsigned char)~PIN_TMS;
	return data;
}

static int script_clock_bit_drive(struct mpsse_script *script, bool bit)
{
	unsigned char low = base_data(false, bit);
	unsigned char high = base_data(true, bit);
	unsigned char dir = (unsigned char)PINE64_LAYOUT_DIR;

	return script_gpio(script, low, dir) ||
	       script_gpio(script, high, dir) ||
	       script_gpio(script, low, dir);
}

static int script_clock_bit_released(struct mpsse_script *script)
{
	unsigned char low = base_data(false, true);
	unsigned char high = base_data(true, true);
	unsigned char dir = (unsigned char)(PINE64_LAYOUT_DIR & ~PIN_TMS);

	return script_gpio(script, low, dir) ||
	       script_gpio(script, high, dir) ||
	       script_read_low(script) ||
	       script_gpio(script, low, dir) ||
	       script_read_low(script);
}

static int script_clock_value(struct mpsse_script *script, uint32_t value, unsigned int nbits)
{
	for (unsigned int i = 0; i < nbits; i++) {
		if (script_clock_bit_drive(script, ((value >> i) & 1u) != 0) != 0)
			return -1;
	}
	return 0;
}

static int script_reset(struct mpsse_script *script, unsigned int cycles)
{
	for (unsigned int i = 0; i < cycles; i++) {
		if (script_clock_bit_drive(script, true) != 0)
			return -1;
	}
	return 0;
}

static uint8_t odd_parity(uint32_t value, unsigned int nbits)
{
	uint8_t parity = 1;
	for (unsigned int i = 0; i < nbits; i++)
		parity ^= (value >> i) & 1u;
	return parity;
}

static int script_write_transaction(struct mpsse_script *script, unsigned int rs, uint32_t value, unsigned int nbits)
{
	uint32_t hdr = (0u << 0) |          // START
		       (0u << 1) |          // RW=write
		       ((rs & 1u) << 2) |
		       (((rs >> 1) & 1u) << 3) |
		       (1u << 4);           // TRN1

	return script_clock_value(script, hdr, 5) ||
	       script_clock_value(script, value, nbits) ||
	       script_clock_bit_drive(script, odd_parity(value, nbits) != 0) ||
	       script_clock_bit_drive(script, true);
}

static int script_read_transaction(struct mpsse_script *script, unsigned int rs, unsigned int read_bits)
{
	uint32_t hdr = (0u << 0) |          // START
		       (1u << 1) |          // RW=read
		       ((rs & 1u) << 2) |
		       (((rs >> 1) & 1u) << 3) |
		       (1u << 4);           // TRN1

	if (script_clock_value(script, hdr, 5) != 0)
		return -1;

	for (unsigned int i = 0; i < read_bits; i++) {
		if (script_clock_bit_released(script) != 0)
			return -1;
	}

	return script_clock_bit_drive(script, true);
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

static int read_exact(struct ftdi_context *ftdi, unsigned char *buf, unsigned int len)
{
	unsigned int got = 0;
	for (unsigned int attempts = 0; got < len && attempts < 5000; attempts++) {
		int rc = ftdi_read_data(ftdi, buf + got, (int)(len - got));
		if (rc < 0) {
			fprintf(stderr, "ftdi_read_data failed: %s\n", ftdi_get_error_string(ftdi));
			return -1;
		}
		if (rc == 0) {
			usleep(1000);
			continue;
		}
		got += (unsigned int)rc;
	}
	if (got != len) {
		fprintf(stderr, "timed out reading MPSSE responses: got %u of %u\n", got, len);
		return -1;
	}
	return 0;
}

static uint8_t sample_bit(const unsigned char *samples, unsigned int idx, unsigned int pin, bool low_phase)
{
	unsigned int sample_idx = idx * 2u + (low_phase ? 1u : 0u);
	return (samples[sample_idx] & pin) ? 1u : 0u;
}

static uint32_t collect_data(
	const unsigned char *samples,
	unsigned int pin,
	bool low_phase,
	unsigned int nbits,
	unsigned int offset)
{
	uint32_t value = 0;
	for (unsigned int i = 0; i < nbits; i++)
		value |= (uint32_t)sample_bit(samples, offset + 1u + i, pin, low_phase) << i;
	return value;
}

static void print_bits(
	const char *label,
	const unsigned char *samples,
	unsigned int count,
	unsigned int pin,
	bool low_phase)
{
	printf("%s=", label);
	for (unsigned int i = 0; i < count; i++)
		putchar(sample_bit(samples, i, pin, low_phase) ? '1' : '0');
	putchar('\n');
}

static void decode_stream(
	const char *label,
	const unsigned char *samples,
	unsigned int count,
	unsigned int pin,
	bool low_phase,
	unsigned int nbits)
{
	printf("%s decode:\n", label);
	for (unsigned int offset = 0; offset <= 2 && offset + nbits + 1 < count; offset++) {
		uint8_t sync = sample_bit(samples, offset, pin, low_phase);
		uint32_t data = collect_data(samples, pin, low_phase, nbits, offset);
		uint8_t par = sample_bit(samples, offset + 1u + nbits, pin, low_phase);
		uint8_t expected = odd_parity(data, nbits);
		printf("  off%u sync=%u data=0x%08x par=%u expected=%u %s\n",
		       offset, sync, data, par, expected,
		       (sync == 0 && par == expected) ? "VALID" : "invalid");
	}
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [--reg n] [--nbits n] [--idle-cycles n] [--reset-cycles n] [vid] [pid] [serial]\n"
		"\n"
		"Default reads HAD ID register 0x02 through JTAG2/HAD and samples both\n"
		"ADBUS3/TMS and ADBUS2/TDO during the released read phase.\n",
		prog);
}

int main(int argc, char **argv)
{
	unsigned int vid = 0x0403;
	unsigned int pid = 0x6014;
	unsigned int reg = HAD_REG_ID;
	unsigned int nbits = 32;
	unsigned int idle_cycles = 64;
	unsigned int reset_cycles = 81;
	const char *serial = NULL;
	const char *positional[3];
	int positional_count = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--reg") == 0) {
			if (++i >= argc || parse_u32(argv[i], &reg, "register") != 0)
				return 2;
		} else if (strcmp(argv[i], "--nbits") == 0) {
			if (++i >= argc || parse_u32(argv[i], &nbits, "bit count") != 0)
				return 2;
			if (nbits == 0 || nbits > 32) {
				fprintf(stderr, "bit count must be 1..32\n");
				return 2;
			}
		} else if (strcmp(argv[i], "--idle-cycles") == 0) {
			if (++i >= argc || parse_u32(argv[i], &idle_cycles, "idle cycle count") != 0)
				return 2;
		} else if (strcmp(argv[i], "--reset-cycles") == 0) {
			if (++i >= argc || parse_u32(argv[i], &reset_cycles, "reset cycle count") != 0)
				return 2;
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

	unsigned int read_bits = nbits + 3u;
	unsigned int read_bytes = read_bits * 2u;
	unsigned char *samples = calloc(read_bytes, 1);
	if (!samples) {
		fprintf(stderr, "calloc failed\n");
		return 1;
	}

	struct mpsse_script script = {0};
	uint8_t hacr = (uint8_t)(HACR_RW | (reg & 0x1fu));
	if (script_gpio(&script, base_data(false, true), (unsigned char)PINE64_LAYOUT_DIR) ||
	    script_append(&script, 0x85) || // Disable internal loopback.
	    script_reset(&script, reset_cycles) ||
	    script_write_transaction(&script, HAD_RS_HAD_IR, hacr, 8))
		return 1;
	for (unsigned int i = 0; i < idle_cycles; i++) {
		if (script_clock_bit_drive(&script, true) != 0)
			return 1;
	}
	if (script_read_transaction(&script, HAD_RS_HAD_DR, read_bits) ||
	    script_append(&script, 0x87))
		return 1;

	struct ftdi_context *ftdi = ftdi_new();
	if (!ftdi) {
		fprintf(stderr, "ftdi_new failed\n");
		free(samples);
		return 1;
	}
	if (ftdi_set_interface(ftdi, INTERFACE_A) != 0) {
		fprintf(stderr, "ftdi_set_interface failed: %s\n", ftdi_get_error_string(ftdi));
		ftdi_free(ftdi);
		free(samples);
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
		free(samples);
		return 1;
	}

	int rc = 0;
	if (ftdi_tcioflush(ftdi) != 0) {
		fprintf(stderr, "ftdi_tcioflush failed: %s\n", ftdi_get_error_string(ftdi));
		rc = 1;
		goto out;
	}
	if (ftdi_set_latency_timer(ftdi, 1) != 0) {
		fprintf(stderr, "ftdi_set_latency_timer failed: %s\n", ftdi_get_error_string(ftdi));
		rc = 1;
		goto out;
	}
	if (ftdi_set_bitmode(ftdi, 0x0b, BITMODE_MPSSE) != 0) {
		fprintf(stderr, "ftdi_set_bitmode MPSSE failed: %s\n", ftdi_get_error_string(ftdi));
		rc = 1;
		goto out;
	}
	if (write_all(ftdi, script.data, (int)script.len) != 0) {
		rc = 1;
		goto out;
	}
	if (read_exact(ftdi, samples, read_bytes) != 0) {
		rc = 1;
		goto out;
	}

	printf("HAD probe reg=0x%02x nbits=%u idle=%u reset=%u script_bytes=%zu samples=%u\n",
	       reg, nbits, idle_cycles, reset_cycles, script.len, read_bytes);
	print_bits("tms_high", samples, read_bits, PIN_TMS, false);
	print_bits("tms_low ", samples, read_bits, PIN_TMS, true);
	print_bits("tdo_high", samples, read_bits, PIN_TDO, false);
	print_bits("tdo_low ", samples, read_bits, PIN_TDO, true);
	decode_stream("TMS high", samples, read_bits, PIN_TMS, false, nbits);
	decode_stream("TMS low ", samples, read_bits, PIN_TMS, true, nbits);
	decode_stream("TDO high", samples, read_bits, PIN_TDO, false, nbits);
	decode_stream("TDO low ", samples, read_bits, PIN_TDO, true, nbits);

out:
	if (ftdi_usb_close(ftdi) != 0 && rc == 0) {
		fprintf(stderr, "ftdi_usb_close failed: %s\n", ftdi_get_error_string(ftdi));
		rc = 1;
	}
	ftdi_free(ftdi);
	free(samples);
	return rc;
}
