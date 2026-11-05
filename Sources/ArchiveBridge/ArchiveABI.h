#ifndef MACRAR_ARCHIVE_ABI_H
#define MACRAR_ARCHIVE_ABI_H
// Stable public libarchive ABI subset. Apple's SDK ships libarchive but omits its headers.
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
typedef int64_t la_int64_t;
struct archive;
struct archive_entry;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_FORMAT_RAW 0x90000
#define ARCHIVE_FILTER_NONE 0
#define AE_IFREG 0100000
#define AE_IFDIR 0040000
#define ARCHIVE_EXTRACT_TIME 0x0004
#define ARCHIVE_EXTRACT_NO_OVERWRITE 0x0008
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200
struct archive *archive_read_new(void);
struct archive *archive_write_disk_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_write_disk_set_options(struct archive *, int);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_next_header(struct archive *, struct archive_entry **);
const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
int archive_filter_code(struct archive *, int);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_perm(struct archive_entry *, mode_t);
int archive_write_header(struct archive *, struct archive_entry *);
int archive_read_data_block(struct archive *, const void **, size_t *, la_int64_t *);
la_int64_t archive_write_data_block(struct archive *, const void *, size_t, la_int64_t);
int archive_write_finish_entry(struct archive *);
int archive_read_free(struct archive *);
int archive_write_free(struct archive *);

// Public writing, encryption and entry metadata API.
#include <sys/stat.h>
struct archive *archive_write_new(void);
int archive_write_set_format_by_name(struct archive *, const char *);
int archive_write_add_filter_by_name(struct archive *, const char *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_close(struct archive *);
la_int64_t archive_write_data(struct archive *, const void *, size_t);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_copy_stat(struct archive_entry *, const struct stat *);
la_int64_t archive_entry_size(struct archive_entry *);

#endif
