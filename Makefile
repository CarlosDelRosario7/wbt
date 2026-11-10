# SPDX-License-Identifier: GPL-3.0-or-later
SHELL := /bin/bash
PREFIX ?= /usr/local

.PHONY: help lint test check install uninstall clean

help:
	@echo "Targets:"
	@echo "  make lint       Ejecuta shellcheck y bash -n"
	@echo "  make test       Pruebas de shell y del proxy Python"
	@echo "  make check      lint + test"
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

install:
	sudo ./install.sh --prefix "$(PREFIX)"

uninstall:
	sudo ./uninstall.sh --prefix "$(PREFIX)"

clean:
	rm -rf tests/__pycache__ tests/.pytest_cache
