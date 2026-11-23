#pragma once

#include <stdlib.h>
#include <string.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

enum scroll_trace_kind {
    TRACE_INPUT = 1,
    TRACE_START,
    TRACE_EMIT,
    TRACE_STOP,
    TRACE_INTERRUPT,
    TRACE_NO_COAST,
    TRACE_CUTOFF,
    TRACE_SPAN,
    TRACE_INPUT_RESET,
};

struct scroll_trace_record {
    uint32_t time_us;
    int32_t x;
    int32_t y;
    uint8_t kind;
};

static struct scroll_trace_record trace_records[2048];
static struct k_spinlock trace_lock;
static uint16_t trace_count;
static uint32_t trace_token;
static enum zmk_transport trace_transport;
static bool trace_mixed_transport;
static bool trace_overflow;
static bool trace_armed;

static void trace_scroll(enum scroll_trace_kind kind, int32_t x, int32_t y) {
    k_spinlock_key_t key = k_spin_lock(&trace_lock);
    if (trace_armed) {
        enum zmk_transport transport = zmk_endpoints_selected().transport;
        if (trace_count == 0) {
            trace_transport = transport;
        } else if (trace_transport != transport) {
            trace_mixed_transport = true;
        }
        if (trace_count == ARRAY_SIZE(trace_records)) {
            trace_overflow = true;
        } else {
            trace_records[trace_count++] = (struct scroll_trace_record){
                .time_us = k_ticks_to_us_floor32(k_uptime_ticks()),
                .x = x,
                .y = y,
                .kind = kind,
            };
        }
    }
    k_spin_unlock(&trace_lock, key);
}

static bool send_trace_line(const struct device *uart, const char *line, int64_t deadline) {
    int remaining = strlen(line);
    int64_t line_deadline = MIN(deadline, k_uptime_get() + 500);
    while (remaining && k_uptime_get() < line_deadline) {
        int sent = uart_fifo_fill(uart, (const uint8_t *)line, remaining);
        if (sent < 0) {
            return false;
        }
        line += sent;
        remaining -= sent;
        if (remaining) {
            k_sleep(K_MSEC(2));
        }
    }
    return remaining == 0;
}

static void dump_scroll_trace(const struct device *uart) {
    const char *transport = trace_mixed_transport ? "mixed" :
                            trace_transport == ZMK_TRANSPORT_BLE ? "Bluetooth" : "USB";
    char line[96];
    int64_t deadline = k_uptime_get() + 10000;
    snprintk(line, sizeof(line), "\nSCROLLTRACE BEGIN %u %u %u %s\n", trace_token,
             (unsigned)trace_count, (unsigned)trace_overflow, transport);
    if (!send_trace_line(uart, line, deadline)) {
        return;
    }
    for (uint16_t i = 0; i < trace_count; ++i) {
        const struct scroll_trace_record *record = &trace_records[i];
        snprintk(line, sizeof(line), "SCROLLTRACE EVENT %u %u %u %d %d\n", trace_token,
                 record->time_us, (unsigned)record->kind, record->x, record->y);
        if (!send_trace_line(uart, line, deadline)) {
            return;
        }
    }
    snprintk(line, sizeof(line), "SCROLLTRACE END %u\n", trace_token);
    send_trace_line(uart, line, deadline);
}

static void handle_trace_command(const struct device *uart, const char *command) {
    if (command[0] == '\0' || command[1] != ' ' ||
        command[2] < '0' || command[2] > '9') {
        return;
    }
    char *end;
    uint32_t token = strtoul(command + 2, &end, 10);
    if (*end != '\0' || token == 0) {
        return;
    }
    k_spinlock_key_t key = k_spin_lock(&trace_lock);
    bool arm = command[0] == 'A';
    bool finish = command[0] == 'E' && trace_armed && token == trace_token;
    if (arm) {
        trace_token = token;
        trace_count = 0;
        trace_overflow = false;
        trace_mixed_transport = false;
        trace_armed = true;
    } else if (finish || (command[0] == 'C' && token == trace_token)) {
        trace_armed = false;
    }
    k_spin_unlock(&trace_lock, key);
    if (arm) {
        char line[40];
        snprintk(line, sizeof(line), "\nSCROLLTRACE READY %u\n", token);
        if (!send_trace_line(uart, line, k_uptime_get() + 500)) {
            key = k_spin_lock(&trace_lock);
            trace_armed = false;
            k_spin_unlock(&trace_lock, key);
        }
    } else if (finish) {
        dump_scroll_trace(uart);
    }
}

static void run_scroll_trace(void *unused1, void *unused2, void *unused3) {
    ARG_UNUSED(unused1);
    ARG_UNUSED(unused2);
    ARG_UNUSED(unused3);
    const struct device *uart = DEVICE_DT_GET(DT_NODELABEL(scroll_trace_uart));
    if (!device_is_ready(uart)) {
        return;
    }
    char command[16];
    size_t length = 0;
    bool overflow = false;
    while (true) {
        unsigned char byte;
        while (uart_poll_in(uart, &byte) == 0) {
            if (byte == '\n') {
                if (!overflow) {
                    command[length] = '\0';
                    handle_trace_command(uart, command);
                }
                length = 0;
                overflow = false;
            } else if (length < sizeof(command) - 1) {
                command[length++] = byte;
            } else {
                overflow = true;
            }
        }
        k_sleep(K_MSEC(10));
    }
}

K_THREAD_DEFINE(scroll_trace_thread, 2048, run_scroll_trace, NULL, NULL, NULL, 7, 0, 0);
