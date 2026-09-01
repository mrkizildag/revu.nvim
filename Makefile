# Local checks, matching CI exactly. `make` runs all three.
.PHONY: all test lint format format-check deps clean

PLENARY := .tests/plenary.nvim

all: format-check lint test

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

deps: $(PLENARY)

# -u on the parent too: without it plenary is missing from the parent's rtp and
# PlenaryBustedDirectory is an unknown command, which hangs rather than fails.
test: $(PLENARY)
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" \
		< /dev/null

lint:
	luacheck lua/ tests/

format:
	stylua lua/ tests/

format-check:
	stylua --check lua/ tests/

clean:
	rm -rf .tests
