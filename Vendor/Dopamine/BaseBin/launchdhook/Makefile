TARGET = launchdhook.dylib
DEBUG ?= 0
CC = clang

CFLAGS = -framework Foundation -framework CoreServices -framework Security -framework IOKit -I../.include -I../_external/modules/litehook/src -Isrc -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -arch arm64e -miphoneos-version-min=$(MIN_IOS_VERSION) -Wno-deprecated-declarations -fobjc-arc -O2 -DDEBUG=$(DEBUG)
LDFLAGS = -dynamiclib -rpath @loader_path/fallback -L../.build -L../_external/lib -ljailbreak -lellekit -lbsm

sign: $(TARGET)
	@ldid -S -Cadhoc $^

LAUNCHDHOOK_SOURCES = $(wildcard src/*.m src/*.c src/jbserver/*.c ../systemhook/src/_zqbb.c ../systemhook/src/common.c ../systemhook/src/envbuf.c)

$(TARGET): $(LAUNCHDHOOK_SOURCES) ../systemhook/src/roothider_common.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

clean:
	@rm -f $(TARGET)
