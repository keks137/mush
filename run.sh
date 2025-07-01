#!/bin/sh
set -xe
odin build src -out:mush && ./mush
