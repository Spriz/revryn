# Driftbord — standalone work-management showcase (BC-US-151).
# Python comes from mise (.mise.toml); `make setup` builds the venv.
PY ?= $(shell mise which python 2>/dev/null || command -v python3)

.PHONY: setup migrate test serve seed

setup:
	$(PY) -m venv .venv
	.venv/bin/pip install -q -r requirements.txt

migrate:
	.venv/bin/python manage.py migrate

test:
	.venv/bin/python manage.py test

serve:
	.venv/bin/python manage.py runserver 8300

seed:
	.venv/bin/python manage.py seed_demo
