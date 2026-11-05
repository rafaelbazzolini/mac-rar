#ifndef ARCHIVE_BRIDGE_H
#define ARCHIVE_BRIDGE_H
#include <stddef.h>
// Destination must be a newly created, empty directory owned by the caller.
int macrar_extract(const char *source, const char *destination, char *error, size_t error_size);

#include <stdint.h>
typedef struct macrar_cancel_token macrar_cancel_token;
macrar_cancel_token *macrar_cancel_new(void);
void macrar_cancel(macrar_cancel_token *token);
void macrar_cancel_free(macrar_cancel_token *token);
int macrar_extract_options(const char *source, const char *destination, const char *password,
                          macrar_cancel_token *token, char *error, size_t error_size);
void *macrar_writer_open(const char *destination, const char *format, const char *filter,
                        int level, const char *password, macrar_cancel_token *token,
                        char *error, size_t error_size);
int macrar_writer_add(void *writer, const char *source, const char *relative_path,
                     char *error, size_t error_size);
int macrar_writer_close(void *writer, char *error, size_t error_size);
void macrar_writer_abort(void *writer);
typedef void (*macrar_entry_visitor)(const char *path, int64_t size, int directory, void *context);
int macrar_inspect(const char *source, const char *password, int verify,
                   macrar_entry_visitor visitor, void *context, macrar_cancel_token *token,
                   char *error, size_t error_size);
#endif
