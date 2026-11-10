# Targets: build, test, clean, all, install docs (from a multi-target line), check.
CC := cc
PREFIX ?= /usr/local
CFLAGS += -O2
OBJ = main.o util.o
export PATH := $(PATH):/opt/bin
SHELL_VAR != date

.PHONY: build test clean all
.DEFAULT_GOAL := build

build: $(OBJ)
	$(CC) -o app $(OBJ) # recipe line: not: a target

%.o: %.c
	$(CC) -c $<

$(OBJ): config.h

test: build
	./app --self-test

clean:
	rm -f app *.o

all:: build test

install docs: build
	@echo "install and docs: share a rule"

check: ; @echo inline recipe
