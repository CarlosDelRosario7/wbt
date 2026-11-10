# SPDX-License-Identifier: GPL-3.0-or-later
SHELL := /bin/bash
PREFIX ?= /usr/local
VERSION := $(shell sed -n 's/^WBT_VERSION="\(.*\)"/\1/p' lib/core.sh)

.PHONY: help lint test check release install uninstall clean

help:
	@echo "Targets:"
	@echo "  make lint       Ejecuta shellcheck y bash -n"
	@echo "  make test       Pruebas de shell y del proxy Python"
	@echo "  make check      lint + test"
	@echo "  make release    Valida el árbol limpio y ejecuta make check"
	@echo "  make install    sudo ./install.sh"
	@echo "  make uninstall  sudo ./uninstall.sh"

lint:
	shellcheck -x bin/wbt lib/*.sh install.sh uninstall.sh tests/run.sh
	bash -n bin/wbt
	bash -n lib/*.sh
	bash -n install.sh
	bash -n uninstall.sh
	bash -n tests/run.sh

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	bash tests/run.sh

check: lint test

release:
	@test -z "$$(git status --porcelain)" || { \
		echo "Hay cambios sin commitear; haz commit antes del release."; exit 1; }
	@$(MAKE) check
	@printf '\nValidación local completada (wbt %s).\n' "$(VERSION)"
	@printf 'Crea y publica el tag con:\n'
	@printf '  git tag -a v%s -m "wbt %s"\n' "$(VERSION)" "$(VERSION)"
	@printf '  git push origin main v%s\n' "$(VERSION)"

install:
	sudo ./install.sh --prefix "$(PREFIX)"

uninstall:
	sudo ./uninstall.sh --prefix "$(PREFIX)"

clean:
	rm -rf tests/__pycache__ tests/.pytest_cache
