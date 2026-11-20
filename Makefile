ZIG    ?= zig
OPT    ?= Debug
NAME   := demo
BUILD  := build
TARGET ?=

ifneq ($(TARGET),)
  OS := $(if $(findstring windows,$(TARGET)),Windows,$(if $(findstring macos,$(TARGET)),Darwin,Linux))
else
  OS ?= $(shell uname -s)
endif

SOKOL_DIR  := $(BUILD)/sokol
SOKOL_REPO ?= https://github.com/floooh/sokol.git
SOKOL_REV  ?= HEAD
SOKOL_HDR  := $(SOKOL_DIR)/sokol_app.h

TARGET_FLAG := $(if $(TARGET),-target $(TARGET))
MODFLAGS    := $(TARGET_FLAG) -O $(OPT) -lc
EXE :=

ifeq ($(OS),Linux)
  CFLAGS := -DSOKOL_GLCORE
  LIBS   := -lX11 -lXi -lXcursor -lGL -ldl -lm -lpthread
endif
ifeq ($(OS),Windows)
  CFLAGS := -DSOKOL_GLCORE
  LIBS   := -lkernel32 -luser32 -lgdi32 -lshell32
  EXE    := .exe
endif
ifeq ($(OS),Darwin)
  CFLAGS := -DSOKOL_METAL -x objective-c
  LIBS   := -framework Cocoa -framework QuartzCore -framework Metal -framework MetalKit
endif

CH   := $(BUILD)/c.h
IMPL := $(BUILD)/sokol_impl.c
CMOD := $(BUILD)/c.zig
LIB  := $(BUILD)/libsokol.a
BIN  := $(BUILD)/$(NAME)$(EXE)

define CH_CONTENT
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_log.h"
endef
export CH_CONTENT

define IMPL_CONTENT
#define SOKOL_IMPL
#define SOKOL_NO_ENTRY
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_log.h"
endef
export IMPL_CONTENT

.PHONY: all run clean distclean
all: $(BIN)

$(BUILD):
	@mkdir -p $@

$(SOKOL_HDR): | $(BUILD)
	git init -q $(SOKOL_DIR)
	git -C $(SOKOL_DIR) remote add origin $(SOKOL_REPO)
	git -C $(SOKOL_DIR) fetch -q --depth 1 origin $(SOKOL_REV)
	git -C $(SOKOL_DIR) checkout -q FETCH_HEAD

$(CH): Makefile | $(BUILD)
	@printf '%s\n' "$$CH_CONTENT" > $@

$(IMPL): Makefile | $(BUILD)
	@printf '%s\n' "$$IMPL_CONTENT" > $@

$(CMOD): $(CH) $(SOKOL_HDR)
	$(ZIG) translate-c $(TARGET_FLAG) -lc -I$(SOKOL_DIR) $(CH) > $@

$(LIB): $(IMPL) $(SOKOL_HDR)
	$(ZIG) build-lib -static $(MODFLAGS) -I$(SOKOL_DIR) \
		-cflags $(CFLAGS) -- $(IMPL) -femit-bin=$@

$(BIN): main.zig $(CMOD) $(LIB)
	$(ZIG) build-exe $(MODFLAGS) $(LIBS) \
		--dep c -Mroot=main.zig \
		$(MODFLAGS) -Mc=$(CMOD) \
		$(LIB) -femit-bin=$@

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(CH) $(IMPL) $(CMOD) $(LIB) $(BIN)
	rm -rf .zig-cache

distclean:
	rm -rf $(BUILD) .zig-cache
