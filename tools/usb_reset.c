#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libusb.h>

static unsigned parse_u16(const char *text, unsigned fallback)
{
    if (text == NULL || *text == '\0') {
        return fallback;
    }
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 0);
    if (end == text || *end != '\0' || value > 0xfffful) {
        fprintf(stderr, "invalid USB id: %s\n", text);
        exit(2);
    }
    return (unsigned)value;
}

int main(int argc, char **argv)
{
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s vid pid [serial]\n", argv[0]);
        return 2;
    }

    unsigned vid = parse_u16(argv[1], 0);
    unsigned pid = parse_u16(argv[2], 0);
    const char *serial = argc == 4 ? argv[3] : NULL;

    libusb_context *ctx = NULL;
    int rc = libusb_init(&ctx);
    if (rc != 0) {
        fprintf(stderr, "libusb_init failed: %s\n", libusb_error_name(rc));
        return 1;
    }

    libusb_device_handle *handle = NULL;
    if (serial == NULL || *serial == '\0') {
        handle = libusb_open_device_with_vid_pid(ctx, (uint16_t)vid, (uint16_t)pid);
    } else {
        libusb_device **devices = NULL;
        ssize_t count = libusb_get_device_list(ctx, &devices);
        if (count < 0) {
            fprintf(stderr, "libusb_get_device_list failed: %s\n", libusb_error_name((int)count));
            libusb_exit(ctx);
            return 1;
        }
        for (ssize_t i = 0; i < count; i++) {
            struct libusb_device_descriptor desc;
            rc = libusb_get_device_descriptor(devices[i], &desc);
            if (rc != 0 || desc.idVendor != vid || desc.idProduct != pid) {
                continue;
            }
            libusb_device_handle *candidate = NULL;
            rc = libusb_open(devices[i], &candidate);
            if (rc != 0) {
                continue;
            }
            unsigned char text[256];
            rc = libusb_get_string_descriptor_ascii(
                candidate, desc.iSerialNumber, text, sizeof(text));
            if (rc > 0 && strcmp((const char *)text, serial) == 0) {
                handle = candidate;
                break;
            }
            libusb_close(candidate);
        }
        libusb_free_device_list(devices, 1);
    }

    if (handle == NULL) {
        fprintf(stderr, "USB device %04x:%04x not found", vid, pid);
        if (serial != NULL && *serial != '\0') {
            fprintf(stderr, " serial=%s", serial);
        }
        fprintf(stderr, "\n");
        libusb_exit(ctx);
        return 1;
    }

    rc = libusb_reset_device(handle);
    if (rc != 0) {
        fprintf(stderr, "libusb_reset_device failed for %04x:%04x: %s\n",
                vid, pid, libusb_error_name(rc));
        libusb_close(handle);
        libusb_exit(ctx);
        return 1;
    }

    printf("reset USB device %04x:%04x", vid, pid);
    if (serial != NULL && *serial != '\0') {
        printf(" serial=%s", serial);
    }
    printf("\n");

    libusb_close(handle);
    libusb_exit(ctx);
    return 0;
}
