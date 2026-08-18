#include "_zqbb.h"

extern xpc_object_t xpc_create_from_plist(const void* buf, size_t len);
bool zqbb_wantInject(const char *execName, const char *injectPath) {
    struct stat s = {};
    int fd = open(injectPath, O_RDONLY);
    if (fd < 0) return 0;

    if (fstat(fd, &s) != 0) {
		close(fd);
		return 0;
    }

    void *addr = mmap(NULL, s.st_size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
    close(fd);
    if (addr == MAP_FAILED) return 0;

    xpc_object_t xplist = xpc_create_from_plist(addr, s.st_size);
    munmap(addr, s.st_size);
    if (!xplist) return 0;

    bool result = xpc_get_type(xplist) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(xplist, execName);
    xpc_release(xplist);
	
    return result;
}

bool zqbb_isWhiteList(const char *path) {
	if (!path)
		return 0;

	const char *systemInjectPath = JBROOT_PATH("/var/mobile/Library/RootHide/cn.zqbb.inject.system.plist");

	if (access(systemInjectPath, F_OK) != 0)
		return 0;

	struct stat s = {};
	int fd = open(systemInjectPath, O_RDONLY);
	if (fd < 0) return 0;

	if (fstat(fd, &s) != 0) {
		close(fd);
		return 0;
	}

	void *addr = mmap(NULL, s.st_size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
	close(fd);
	if (addr == MAP_FAILED) return 0;

	xpc_object_t xplist = xpc_create_from_plist(addr, s.st_size);
	munmap(addr, s.st_size);
	if (!xplist || xpc_get_type(xplist) != XPC_TYPE_DICTIONARY) {
		if (xplist) xpc_release(xplist);
		return 0;
	}

	__block bool found = 0;
	xpc_dictionary_apply(xplist, ^bool(const char *key, xpc_object_t value) {
		if (xpc_get_type(value) == XPC_TYPE_BOOL && xpc_bool_get_value(value)) {
			if (strstr(path, key)) {
				found = 1;
				return false; // stop iteration
			}
		}
		return true; // continue
	});

	xpc_release(xplist);
	return found;
}
int zqbb_getJetsamAddend(const char *path) {
	if (!path) {
		return 10;
	}

	const char *jetsamPlistPath = JBROOT_PATH("/var/mobile/Library/RootHide/cn.zqbb.jetsam.addend.plist");
	
	// Check if file exists before attempting to read
	if (access(jetsamPlistPath, F_OK) != 0) {
		return 10;
	}

	// Read file into memory
	int fd = open(jetsamPlistPath, O_RDONLY);
	if (fd < 0) {
		return 10;
	}

	struct stat st;
	if (fstat(fd, &st) != 0) {
		close(fd);
		return 10;
	}

	void *data = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (data == MAP_FAILED) {
		return 10;
	}

	// Parse plist using XPC
	xpc_object_t plist = xpc_create_from_plist(data, st.st_size);
	munmap(data, st.st_size);
	
	if (!plist || xpc_get_type(plist) != XPC_TYPE_DICTIONARY) {
		if (plist) xpc_release(plist);
		return 10;
	}

	__block int result = 10;
	xpc_dictionary_apply(plist, ^bool(const char *key, xpc_object_t value) {
		if (xpc_get_type(value) == XPC_TYPE_INT64) {
			int64_t valueInt = xpc_int64_get_value(value);
			if (valueInt > 0 && strstr(path, key)) {
				result = (int)valueInt;
				return false; // Stop iteration
			}
		}
		return true; // Continue iteration
	});

	xpc_release(plist);

	return result;
}