.PHONY: deps

all: compile

deps:
	@./rebar get-deps

compile: deps
	@./rebar compile

clean:
	@./rebar clean

REPO = riak_api

DIALYZER_APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler

include tools.mk
