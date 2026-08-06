PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
VALAC  ?= valac
VALAFLAGS ?= --pkg posix --pkg glib-2.0 -X -O2

all: prewarm

prewarm: src/prewarm.vala
	$(VALAC) $(VALAFLAGS) -o $@ $<

install: prewarm
	install -Dm755 prewarm $(DESTDIR)$(BINDIR)/prewarm

clean:
	rm -f prewarm src/prewarm.vala.c

.PHONY: all install clean
