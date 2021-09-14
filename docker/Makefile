SERVICE:= $(notdir $(patsubst %/,%,$(lastword $(CURDIR))))
TAG:=$$(git tag | sort -r -V | head -1)

include ../Makefile
