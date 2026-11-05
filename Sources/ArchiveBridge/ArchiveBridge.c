#include "ArchiveBridge.h"
#include "ArchiveABI.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>

static int fail(char *buffer, size_t size, const char *message) {
    snprintf(buffer, size, "%s", message ? message : "Erro desconhecido na extração.");
    return -1;
}

static int safe_path(const char *path) {
    if (!path || !*path || path[0] == '/') return 0;
    const char *part = path;
    while (*part) {
        const char *end = strchr(part, '/');
        size_t len = end ? (size_t)(end - part) : strlen(part);
        if (len == 2 && part[0] == '.' && part[1] == '.') return 0;
        if (!end) break;
        part = end + 1;
    }
    return 1;
}

struct macrar_cancel_token { atomic_bool cancelled; };
macrar_cancel_token *macrar_cancel_new(void) {
    macrar_cancel_token *token = calloc(1, sizeof(*token));
    if (token) atomic_init(&token->cancelled, false);
    return token;
}
void macrar_cancel(macrar_cancel_token *token) { if (token) atomic_store(&token->cancelled, true); }
void macrar_cancel_free(macrar_cancel_token *token) { free(token); }
static int cancelled(macrar_cancel_token *token, char *error, size_t size) {
    if (token && atomic_load(&token->cancelled)) {
        fail(error, size, "Operação cancelada.");
        return 1;
    }
    return 0;
}
int macrar_extract(const char *source, const char *destination, char *error, size_t error_size) {
    return macrar_extract_options(source, destination, "", NULL, error, error_size);
}
int macrar_extract_options(const char *source, const char *destination, const char *password,
                          macrar_cancel_token *token, char *error, size_t error_size) {
    // Canonicalize in C: Foundation can normalize /private/var back to /var,
    // which is a symlink and is correctly rejected by secure extraction.
    char *root = realpath(destination, NULL);
    if (!root) return fail(error, error_size, "Não foi possível acessar a pasta de destino.");
    struct archive *reader = archive_read_new();
    struct archive *writer = archive_write_disk_new();
    struct archive_entry *entry;
    int result = -1, status;
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    archive_read_support_format_raw(reader);
    if (password && *password) archive_read_add_passphrase(reader, password);
    archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME |
        ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        ARCHIVE_EXTRACT_NO_OVERWRITE);
    if (archive_read_open_filename(reader, source, 10240) != ARCHIVE_OK) {
        fail(error, error_size, archive_error_string(reader));
        goto cleanup;
    }
    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (cancelled(token, error, error_size)) goto cleanup;
        if (status != ARCHIVE_OK) {
            fail(error, error_size, archive_error_string(reader));
            goto cleanup;
        }
        if (archive_format(reader) == ARCHIVE_FORMAT_RAW) {
            if (archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
                fail(error, error_size, "Formato de arquivo não reconhecido.");
                goto cleanup;
            }
            const char *base = strrchr(source, '/');
            char *name = strdup(base ? base + 1 : source);
            char *extension = strrchr(name, '.');
            if (extension && extension != name) *extension = '\0';
            archive_entry_set_pathname(entry, *name ? name : "conteudo");
            free(name);
        }
        const char *path = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        if (!safe_path(path) || archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
            (type != AE_IFREG && type != AE_IFDIR)) {
            fail(error, error_size, "Arquivo contém caminhos inseguros, links ou arquivos especiais. Extração interrompida.");
            goto cleanup;
        }
        char *target = NULL;
        if (asprintf(&target, "%s/%s", root, path) < 0) {
            fail(error, error_size, "Memória insuficiente.");
            goto cleanup;
        }
        archive_entry_set_pathname(entry, target);
        free(target);
        // Do not restore privileged bits or executable permissions from untrusted archives.
        archive_entry_set_perm(entry, type == AE_IFDIR ? 0755 : 0644);
        if (archive_write_header(writer, entry) != ARCHIVE_OK) {
            fail(error, error_size, archive_error_string(writer));
            goto cleanup;
        }
        if (type == AE_IFDIR) {
            // RAR directory entries can retain a compression method in their
            // header. Reading their data invokes a decompressor that rejects
            // directories; skip them explicitly and only copy regular files.
            if (archive_read_data_skip(reader) != ARCHIVE_OK) {
                fail(error, error_size, archive_error_string(reader));
                goto cleanup;
            }
        } else {
            const void *block;
            size_t size;
            la_int64_t offset;
            while ((status = archive_read_data_block(reader, &block, &size, &offset)) == ARCHIVE_OK) {
                if (cancelled(token, error, error_size)) goto cleanup;
                if (archive_write_data_block(writer, block, size, offset) != ARCHIVE_OK) {
                    fail(error, error_size, archive_error_string(writer));
                    goto cleanup;
                }
            }
            if (status != ARCHIVE_EOF) {
                fail(error, error_size, archive_error_string(reader));
                goto cleanup;
            }
        }
        if (archive_write_finish_entry(writer) != ARCHIVE_OK) {
            fail(error, error_size, archive_error_string(writer));
            goto cleanup;
        }
    }
    result = 0;
cleanup:
    free(root);
    archive_read_free(reader);
    archive_write_free(writer);
    return result;
}

typedef struct {
    struct archive *archive;
    macrar_cancel_token *token;
} MacRarWriter;

void *macrar_writer_open(const char *destination, const char *format, const char *filter,
                        int level, const char *password, macrar_cancel_token *token,
                        char *error, size_t error_size) {
    MacRarWriter *writer = calloc(1, sizeof(*writer));
    if (!writer) { fail(error, error_size, "Memória insuficiente."); return NULL; }
    writer->archive = archive_write_new();
    writer->token = token;
    struct archive *a = writer->archive;
    if (archive_write_set_format_by_name(a, format) != ARCHIVE_OK) goto failure;
    if (filter && *filter && archive_write_add_filter_by_name(a, filter) != ARCHIVE_OK) goto failure;
    char options[128];
    if (level >= 0 && (strcmp(format, "zip") == 0 || strcmp(format, "7zip") == 0 || (filter && *filter))) {
        const char *module = (filter && *filter) ? filter : format;
        snprintf(options, sizeof(options), "%s:compression-level=%d", module, level);
        if (archive_write_set_options(a, options) != ARCHIVE_OK) goto failure;
    }
    if (password && *password) {
        if (strcmp(format, "zip") != 0) {
            fail(error, error_size, "Senha disponível somente para ZIP nesta versão.");
            macrar_writer_abort(writer);
            return NULL;
        }
        if (archive_write_set_options(a, "zip:encryption=aes256") != ARCHIVE_OK ||
            archive_write_set_passphrase(a, password) != ARCHIVE_OK) goto failure;
    }
    if (archive_write_open_filename(a, destination) != ARCHIVE_OK) goto failure;
    return writer;
failure:
    fail(error, error_size, archive_error_string(a));
    macrar_writer_abort(writer);
    return NULL;
}

int macrar_writer_add(void *handle, const char *source, const char *relative_path,
                     char *error, size_t error_size) {
    MacRarWriter *writer = handle;
    struct archive *a = writer->archive;
    if (cancelled(writer->token, error, error_size)) return -1;
    if (!safe_path(relative_path)) return fail(error, error_size, "Caminho de entrada inválido.");
    struct stat metadata;
    if (lstat(source, &metadata) != 0) return fail(error, error_size, "Não foi possível ler os atributos do arquivo.");
    if (!S_ISREG(metadata.st_mode) && !S_ISDIR(metadata.st_mode))
        return fail(error, error_size, "Links e arquivos especiais não são compactados. Remova-os da seleção.");
    FILE *file = NULL;
    if (S_ISREG(metadata.st_mode)) {
        int fd = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) return fail(error, error_size, "Não foi possível abrir o arquivo para leitura.");
        struct stat actual;
        if (fstat(fd, &actual) != 0 || !S_ISREG(actual.st_mode) || actual.st_ino != metadata.st_ino || actual.st_dev != metadata.st_dev) {
            close(fd);
            return fail(error, error_size, "O arquivo mudou durante a compactação. Tente novamente.");
        }
        metadata = actual;
        file = fdopen(fd, "rb");
        if (!file) { close(fd); return fail(error, error_size, "Não foi possível ler o arquivo."); }
    }
    struct archive_entry *entry = archive_entry_new();
    archive_entry_copy_stat(entry, &metadata);
    archive_entry_set_pathname(entry, relative_path);
    archive_entry_set_perm(entry, S_ISDIR(metadata.st_mode) ? 0755 : 0644);
    int result = -1;
    if (archive_write_header(a, entry) != ARCHIVE_OK) {
        fail(error, error_size, archive_error_string(a));
        goto done;
    }
    if (file) {
        char buffer[65536];
        size_t count;
        la_int64_t remaining = metadata.st_size;
        while (remaining > 0 && (count = fread(buffer, 1, remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer), file)) > 0) {
            if (cancelled(writer->token, error, error_size)) goto done;
            size_t written = 0;
            while (written < count) {
                la_int64_t amount = archive_write_data(a, buffer + written, count - written);
                if (amount <= 0) { fail(error, error_size, archive_error_string(a)); goto done; }
                written += (size_t)amount;
            }
            remaining -= count;
        }
        if (remaining != 0 || ferror(file)) { fail(error, error_size, "Falha de leitura: o arquivo foi alterado ou está inacessível."); goto done; }
    }
    if (archive_write_finish_entry(a) != ARCHIVE_OK) { fail(error, error_size, archive_error_string(a)); goto done; }
    result = 0;
done:
    if (file) fclose(file);
    archive_entry_free(entry);
    return result;
}

int macrar_writer_close(void *handle, char *error, size_t error_size) {
    MacRarWriter *writer = handle;
    int result = 0;
    if (cancelled(writer->token, error, error_size)) result = -1;
    if (archive_write_close(writer->archive) != ARCHIVE_OK && result == 0)
        result = fail(error, error_size, archive_error_string(writer->archive));
    archive_write_free(writer->archive);
    free(writer);
    return result;
}
void macrar_writer_abort(void *handle) {
    if (!handle) return;
    MacRarWriter *writer = handle;
    archive_write_free(writer->archive);
    free(writer);
}

int macrar_inspect(const char *source, const char *password, int verify,
                   macrar_entry_visitor visitor, void *context, macrar_cancel_token *token,
                   char *error, size_t error_size) {
    struct archive *reader = archive_read_new();
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    archive_read_support_format_raw(reader);
    if (password && *password) archive_read_add_passphrase(reader, password);
    int result = -1, status;
    if (archive_read_open_filename(reader, source, 10240) != ARCHIVE_OK) goto failure;
    struct archive_entry *entry;
    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (cancelled(token, error, error_size)) goto done;
        if (status != ARCHIVE_OK) goto failure;
        if (archive_format(reader) == ARCHIVE_FORMAT_RAW && archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
            fail(error, error_size, "Formato de arquivo não reconhecido."); goto done;
        }
        if (visitor) visitor(archive_entry_pathname(entry), archive_entry_size(entry),
                             archive_entry_filetype(entry) == AE_IFDIR, context);
        if (verify && archive_entry_filetype(entry) == AE_IFREG) {
            const void *block;
            size_t size;
            la_int64_t offset;
            while ((status = archive_read_data_block(reader, &block, &size, &offset)) == ARCHIVE_OK)
                if (cancelled(token, error, error_size)) goto done;
            if (status != ARCHIVE_EOF) goto failure;
        } else if (archive_read_data_skip(reader) != ARCHIVE_OK) goto failure;
    }
    result = 0;
    goto done;
failure:
    fail(error, error_size, archive_error_string(reader));
done:
    archive_read_free(reader);
    return result;
}
