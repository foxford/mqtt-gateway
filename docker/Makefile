SERVICE:= $(notdir $(patsubst %/,%,$(lastword $(CURDIR))))
TAG:=$$(git tag | sort -r -V | head -1)

.SILENT:
.PHONY: help

REG_HOST="foxford"

build:
	if [[ ! "${TAG}" ]]; then echo "TAG is required." 1>&2; exit 1; fi
	docker build --rm -t ${REG_HOST}/${SERVICE}:${TAG} --no-cache . 
	docker push $(REG_HOST)/${SERVICE}:${TAG}

help:
        echo "help:"
        echo "Run: make ${SERVICE}"
