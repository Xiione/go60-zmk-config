/* Included in the pinned Pinnacle driver after its register access functions. */
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/printk.h>

struct pad_packet {
    uint32_t time_us;
    uint8_t bytes[6];
};

static const struct device *const sensor = DEVICE_DT_GET(DT_NODELABEL(glidepoint));
static const struct device *const serial = DEVICE_DT_GET(DT_NODELABEL(pad_probe_uart));
static const char *const hand = IS_ENABLED(CONFIG_BOARD_GO60_LH) ? "lh" : "rh";
K_MUTEX_DEFINE(pad_lock);
static struct pad_packet packets[1536];
static size_t packet_count;
static unsigned discarded, io_errors;
static uint32_t start_us;
static char active_mode;
static uint8_t relative_feed[2];
static bool has_relative_feed;

static uint32_t pad_time_us(void) {
    return k_ticks_to_us_floor32(k_uptime_ticks());
}

static void pinnacle_report_data(const struct device *dev) {
    k_mutex_lock(&pad_lock, K_FOREVER);
    uint8_t status;
    int ret = pinnacle_seq_read(dev, PINNACLE_STATUS1, &status, 1);
    if (ret < 0 || status == 0xff) {
        io_errors++;
    } else if (status & PINNACLE_STATUS1_SW_DR) {
        struct pad_packet packet = {.time_us = pad_time_us() - start_us};
        if (active_mode) {
            size_t len = active_mode == 'A' ? 6 : 3;
            if (pinnacle_seq_read(dev, PINNACLE_2_2_PACKET0, packet.bytes, len) < 0) {
                io_errors++;
            } else if (packet_count == ARRAY_SIZE(packets)) {
                discarded++;
            } else {
                packets[packet_count++] = packet;
            }
        }
        if (pinnacle_clear_status(dev) < 0) {
            io_errors++;
        }
    }
    k_mutex_unlock(&pad_lock);
}

static bool send_line(const char *line) {
    size_t len = strlen(line);
    int64_t deadline = k_uptime_get() + 400;
    while (len > 0 && k_uptime_get() < deadline) {
        int n = uart_fifo_fill(serial, (const uint8_t *)line, len);
        if (n < 0) {
            return false;
        }
        line += n;
        len -= n;
        if (len) {
            k_sleep(K_MSEC(1));
        }
    }
    return len == 0;
}

static int configure_feed(char mode, uint8_t id[2], uint8_t feed[2], uint8_t timing[2]) {
    if (!device_is_ready(sensor)) {
        return -ENODEV;
    }
    if (!has_relative_feed) {
        if (pinnacle_seq_read(sensor, PINNACLE_FEED_CFG1, relative_feed, 2) < 0 ||
            !(relative_feed[0] & PINNACLE_FEED_CFG1_EN_FEED) ||
            (relative_feed[0] & PINNACLE_FEED_CFG1_ABS_MODE)) {
            return -EIO;
        }
        has_relative_feed = true;
    }
    uint8_t feed1 = mode == 'A' ? 0x03 : relative_feed[0];
    uint8_t feed2 = mode == 'A' ? 0x1f : relative_feed[1];
    if (pinnacle_write(sensor, PINNACLE_FEED_CFG1, 0) < 0 ||
        pinnacle_write(sensor, PINNACLE_FEED_CFG2, feed2) < 0 ||
        pinnacle_clear_status(sensor) < 0 ||
        pinnacle_write(sensor, PINNACLE_FEED_CFG1, feed1) < 0 ||
        pinnacle_seq_read(sensor, PINNACLE_FEED_CFG1, feed, 2) < 0 ||
        pinnacle_seq_read(sensor, PINNACLE_FW_ID, id, 2) < 0 ||
        pinnacle_seq_read(sensor, PINNACLE_SAMPLE, timing, 2) < 0 ||
        feed[0] != feed1 || feed[1] != feed2) {
        return -EIO;
    }
    return 0;
}

static void begin_capture(char mode) {
    uint8_t id[2], feed[2], timing[2];
    char line[96];
    k_mutex_lock(&pad_lock, K_FOREVER);
    active_mode = 0;
    int err = configure_feed(mode, id, feed, timing);
    if (err == 0) {
        packet_count = discarded = io_errors = 0;
        start_us = pad_time_us();
        active_mode = mode;
        snprintk(line, sizeof(line), "READY %s %c %u %u %u %u %u %u\n", hand, mode,
                 id[0], id[1], feed[0], feed[1], timing[0], timing[1]);
    } else {
        snprintk(line, sizeof(line), "ERROR sensor setup %d\n", err);
    }
    k_mutex_unlock(&pad_lock);
    send_line(line);
}

static void end_capture(void) {
    /* Only this USB thread can start another capture. After disarming, the
     * sensor workqueue can acknowledge interrupts while we drain the buffer. */
    k_mutex_lock(&pad_lock, K_FOREVER);
    char mode = active_mode;
    active_mode = 0;
    uint32_t elapsed = pad_time_us() - start_us;
    unsigned errors = io_errors;
    k_mutex_unlock(&pad_lock);
    if (!mode) {
        send_line("ERROR no active capture\n");
        return;
    }
    char line[96];
    snprintk(line, sizeof(line), "BEGIN %s %c %u %u %u %u\n", hand, mode,
             (unsigned)packet_count, discarded, errors, elapsed);
    if (!send_line(line)) {
        return;
    }
    for (size_t i = 0; i < packet_count; i++) {
        const uint8_t *b = packets[i].bytes;
        snprintk(line, sizeof(line), "P %u %02x%02x%02x%02x%02x%02x\n",
                 packets[i].time_us, b[0], b[1], b[2], b[3], b[4], b[5]);
        if (!send_line(line)) {
            return;
        }
    }
    send_line("END\n");
}

static void run_probe(void *a, void *b, void *c) {
    if (!device_is_ready(serial)) {
        return;
    }
    for (;;) {
        unsigned char cmd;
        if (uart_poll_in(serial, &cmd) != 0) {
            k_sleep(K_MSEC(2));
            continue;
        }
        switch (cmd) {
        case '?':
            send_line(IS_ENABLED(CONFIG_BOARD_GO60_LH) ? "\nPAD1 lh\n" : "\nPAD1 rh\n");
            break;
        case 'A':
        case 'R':
            begin_capture(cmd);
            break;
        case 'E':
            end_capture();
            break;
        }
    }
}

K_THREAD_DEFINE(pad_probe_thread, 2048, run_probe, NULL, NULL, NULL, 7, 0, 0);
