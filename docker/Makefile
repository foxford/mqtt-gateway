SERVICE:= $(notdir $(patsubst %/,%,$(lastword $(CURDIR))))
TAG:=$$(git tag | sort -r -V | head -1)



.SILENT:
.PHONY: help

REG_HOST="netologygroup"

build:
	docker build --rm -t $(REG_HOST)/${SERVICE}:${TAG} --no-cache . 
	docker push $(REG_HOST)/${SERVICE}

help:
        echo "help:"
        echo "Run: make ${SERVICE}"
