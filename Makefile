PREFIX ?= /usr
DESTDIR ?=
BINDIR = $(DESTDIR)$(PREFIX)/bin
SYSCONFDIR = $(DESTDIR)/etc
SYSTEMDUSERDIR = $(DESTDIR)$(PREFIX)/lib/systemd/user
EXTENSIONDIR = $(DESTDIR)$(PREFIX)/share/gnome-shell/extensions/macbook-lighter@cleomenezesjr.github.io

.PHONY: all install install-scripts install-service install-config install-extension

all:
	@echo "Nothing to build. Run 'make install' to deploy."

install: install-scripts install-service install-config install-extension

install-scripts:
	install -Dm755 src/macbook-lighter-ambient.sh $(BINDIR)/macbook-lighter-ambient
	install -Dm755 src/macbook-lighter-screen.sh $(BINDIR)/macbook-lighter-screen
	install -Dm755 src/macbook-lighter-kbd.sh $(BINDIR)/macbook-lighter-kbd

install-service:
	install -Dm644 macbook-lighter.service $(SYSTEMDUSERDIR)/macbook-lighter.service

install-config:
	install -Dm644 macbook-lighter.conf $(SYSCONFDIR)/macbook-lighter.conf

install-extension:
	mkdir -p $(EXTENSIONDIR)
	cp -r gnome-extension/macbook-lighter@cleomenezesjr.github.io/. $(EXTENSIONDIR)/
