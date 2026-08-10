#include "mappy.h"

// Small protocol and bounds helpers shared across modules.

void write_i32(DictionaryIterator *iter, uint32_t key, int32_t value) {
  dict_write_int(iter, key, &value, sizeof(value), true);
}

uint16_t read_u16_le(const uint8_t *data, int offset) {
  return (uint16_t)data[offset] | ((uint16_t)data[offset + 1] << 8);
}

int32_t read_i32_le(const uint8_t *data, int offset) {
  uint32_t value = (uint32_t)data[offset] |
                   ((uint32_t)data[offset + 1] << 8) |
                   ((uint32_t)data[offset + 2] << 16) |
                   ((uint32_t)data[offset + 3] << 24);
  return (int32_t)value;
}

void copy_bounded_text(char *dest, size_t dest_size, const char *src) {
  if (!dest || dest_size == 0) {
    return;
  }
  if (!src) {
    dest[0] = '\0';
    return;
  }
  strncpy(dest, src, dest_size - 1);
  dest[dest_size - 1] = '\0';
}

void set_bottom_text(const char *text) {
  copy_bounded_text(s_bottom_text, sizeof(s_bottom_text), text);
}

AppMessageResult send_message_begin(DictionaryIterator **iter, int32_t cmd);


void sanitize_payload_text(char *dest, size_t dest_size, const uint8_t *src, uint8_t src_len) {
  if (!dest || dest_size == 0) {
    return;
  }
  uint8_t copy_len = src_len;
  if (copy_len > dest_size - 1) {
    copy_len = dest_size - 1;
  }
  for (uint8_t i = 0; i < copy_len; i++) {
    uint8_t value = src[i];
    dest[i] = (value >= 32 && value <= 126) ? (char)value : '?';
  }
  dest[copy_len] = '\0';
}
