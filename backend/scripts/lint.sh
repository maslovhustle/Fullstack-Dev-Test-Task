#!/usr/bin/env bash

set -e
set -x

mypy app tests
ty check app tests
ruff check app tests scripts
ruff format app tests --check
