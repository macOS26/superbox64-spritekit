#include "Zip.h"
#include <stdlib.h>
#include <string.h>

#define MINIZ_HEADER_FILE_ONLY
#include "miniz.c"

typedef struct {
    mz_zip_archive zip;
    int file_index;
    const void* file_data;
    size_t file_size;
    size_t file_pos;
} ZipArchiveImpl;

typedef struct {
    const void* data;
    size_t size;
    size_t pos;
} ZipFileImpl;

ZipArchive* zip_open(const char* path) {
    ZipArchiveImpl* impl = malloc(sizeof(ZipArchiveImpl));
    if (!impl) return NULL;

    memset(&impl->zip, 0, sizeof(mz_zip_archive));
    if (!mz_zip_reader_init_file(&impl->zip, path, 0)) {
        free(impl);
        return NULL;
    }

    impl->file_index = -1;
    impl->file_data = NULL;
    impl->file_size = 0;
    impl->file_pos = 0;

    return (ZipArchive*)impl;
}

ZipArchive* zip_open_mem(const void* data, size_t size) {
    ZipArchiveImpl* impl = malloc(sizeof(ZipArchiveImpl));
    if (!impl) return NULL;

    memset(&impl->zip, 0, sizeof(mz_zip_archive));
    if (!mz_zip_reader_init_mem(&impl->zip, data, size, 0)) {
        free(impl);
        return NULL;
    }

    impl->file_index = -1;
    impl->file_data = NULL;
    impl->file_size = 0;
    impl->file_pos = 0;

    return (ZipArchive*)impl;
}

void zip_close(ZipArchive* archive) {
    if (!archive) return;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    mz_zip_reader_end(&impl->zip);
    free(impl);
}

ZipFile* zip_fopen(ZipArchive* archive, const char* name) {
    if (!archive) return NULL;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;

    int file_index = mz_zip_reader_locate_file(&impl->zip, name, NULL, 0);
    if (file_index < 0) return NULL;

    size_t size = 0;
    const void* data = mz_zip_reader_extract_to_mem(&impl->zip, file_index, NULL, 0, &size);
    if (!data) {
        data = malloc(size);
        if (!data) return NULL;
        if (!mz_zip_reader_extract_to_mem(&impl->zip, file_index, (void*)data, size, &size)) {
            free((void*)data);
            return NULL;
        }
    }

    ZipFileImpl* file = malloc(sizeof(ZipFileImpl));
    if (!file) {
        free((void*)data);
        return NULL;
    }

    file->data = data;
    file->size = size;
    file->pos = 0;

    return (ZipFile*)file;
}

void zip_fclose(ZipFile* file) {
    if (!file) return;
    ZipFileImpl* impl = (ZipFileImpl*)file;
    free((void*)impl->data);
    free(impl);
}

size_t zip_fread(void* buf, size_t size, ZipFile* file) {
    if (!file) return 0;
    ZipFileImpl* impl = (ZipFileImpl*)file;

    if (impl->pos >= impl->size) return 0;

    size_t remaining = impl->size - impl->pos;
    size_t to_read = size < remaining ? size : remaining;

    memcpy(buf, (const char*)impl->data + impl->pos, to_read);
    impl->pos += to_read;

    return to_read;
}

int zip_feof(ZipFile* file) {
    if (!file) return 1;
    ZipFileImpl* impl = (ZipFileImpl*)file;
    return impl->pos >= impl->size;
}

int zip_locate_file(ZipArchive* archive, const char* name) {
    if (!archive) return -1;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    return mz_zip_reader_locate_file(&impl->zip, name, NULL, 0);
}

int zip_get_current_file_info_name(ZipArchive* archive, char* name_buf, size_t name_buf_size) {
    if (!archive || name_buf == NULL) return -1;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;

    if (impl->file_index < 0) return -1;

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&impl->zip, impl->file_index, &stat)) return -1;

    size_t len = strlen(stat.m_filename);
    if (len >= name_buf_size) len = name_buf_size - 1;

    strncpy(name_buf, stat.m_filename, len);
    name_buf[len] = '\0';

    return 0;
}

size_t zip_get_current_file_info_size(ZipArchive* archive) {
    if (!archive) return 0;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;

    if (impl->file_index < 0) return 0;

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&impl->zip, impl->file_index, &stat)) return 0;

    return stat.m_uncomp_size;
}
