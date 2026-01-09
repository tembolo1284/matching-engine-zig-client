# Matching Engine Zig Client - Makefile
# ======================================

HOST ?= 127.0.0.1
PORT ?= 1234
SCENARIO ?= i
ZIG ?= zig
BINARY := ./zig-out/bin/me-client
QUIET ?=
MODE ?= ReleaseFast

QUIET_FLAG := $(if $(filter 1,$(QUIET)),--quiet,)

.PHONY: all build clean rebuild help run interactive \
        run-tcp run-tcp-csv run-udp run-udp-csv \
        scenario-1 scenario-2 scenario-3 \
        stress-1k stress-10k stress-100k \
        match-1k match-10k match-100k match-250k match-500k match-1m \
        dual-500k dual-1m dual-100m \
        test check fmt

# ============================================================================
# Core
# ============================================================================

all: build

build:
	@echo "=== Building Matching Engine Client ($(MODE)) ==="
	$(ZIG) build -Doptimize=$(MODE)
	@echo "Build complete: $(BINARY)"

clean:
	@rm -rf .zig-cache zig-out
	@echo "Cleaned!"

rebuild: clean build

# ============================================================================
# Run
# ============================================================================

run: build
	$(BINARY) $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

interactive: build
	$(BINARY) $(HOST) $(PORT) i

run-tcp: build
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

run-tcp-csv: build
	$(BINARY) --tcp --csv $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

run-udp: build
	$(BINARY) --udp --binary $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

run-udp-csv: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

# ============================================================================
# Basic Scenarios (1-3)
# ============================================================================

scenario-1: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 1

scenario-2: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 2

scenario-3: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 3

# ============================================================================
# Unmatched Stress (10-12)
# ============================================================================

stress-1k: build
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 10

stress-10k: build
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 11

stress-100k: build
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 12

# ============================================================================
# BUFFERED Matching (40-45) - Uses threaded.zig with write buffering
# ============================================================================

match-1k: build
	@echo "=== 1K Trades (2K orders) - BUFFERED ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 40

match-10k: build
	@echo "=== 10K Trades (20K orders) - BUFFERED ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 41

match-100k: build
	@echo "=== 100K Trades (200K orders) - BUFFERED ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 42

match-250k: build
	@echo "=== 250K Trades (500K orders) - BUFFERED ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 43

match-500k: build
	@echo "=== 500K Trades (1M orders) - BUFFERED ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 44

match-1m: build
	@echo ""
	@echo "★★★ BEAST MODE: 1M Trades (2M orders) - BUFFERED ★★★"
	@echo ""
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 45

# ============================================================================
# Dual-Processor Matching (30-32) - IBM + NVDA
# ============================================================================

dual-500k: build
	@echo "=== 500K Trades (1M orders) - Dual Processor ==="
	@echo "    IBM (Proc 0): 250K | NVDA (Proc 1): 250K"
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 30

dual-1m: build
	@echo "=== 1M Trades (2M orders) - Dual Processor ==="
	@echo "    IBM (Proc 0): 500K | NVDA (Proc 1): 500K"
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 31

dual-100m: build
	@echo ""
	@echo "★★★ ULTIMATE: 100M Trades (200M orders) - Dual Processor ★★★"
	@echo "    IBM (Proc 0): 50M | NVDA (Proc 1): 50M"
	@echo ""
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 32

# ============================================================================
# Benchmarking
# ============================================================================

bench: build
	@echo "=== Quick Benchmark (Buffered) ==="
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 40
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 41

bench-full: build
	@echo "=== Full Benchmark Suite ==="
	@echo "--- Buffered Single Processor ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 40
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 41
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 42
	@echo "--- Dual Processor ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 30

# ============================================================================
# Development
# ============================================================================

test:
	$(ZIG) build test

check:
	$(ZIG) build --summary all

fmt:
	$(ZIG) fmt src/

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Matching Engine Zig Client"
	@echo "=========================="
	@echo ""
	@echo "Config: HOST=$(HOST) PORT=$(PORT)"
	@echo ""
	@echo "Build:"
	@echo "  make build    Build client"
	@echo "  make clean    Remove artifacts"
	@echo "  make rebuild  Clean + build"
	@echo ""
	@echo "Basic: scenario-1, scenario-2, scenario-3"
	@echo ""
	@echo "BUFFERED Matching (threaded send/recv):"
	@echo "  make match-1k      1K trades"
	@echo "  make match-10k     10K trades"
	@echo "  make match-100k    100K trades"
	@echo "  make match-250k    250K trades"
	@echo "  make match-500k    500K trades"
	@echo "  make match-1m      1M trades    ★★★ BEAST MODE ★★★"
	@echo ""
	@echo "Dual-Processor Matching (IBM + NVDA):"
	@echo "  make dual-500k     500K trades  (250K each)"
	@echo "  make dual-1m       1M trades    (500K each)"
	@echo "  make dual-100m     100M trades  (50M each) ★★★ ULTIMATE ★★★"
	@echo ""
	@echo "Benchmarking:"
	@echo "  make bench       Quick (1K, 10K)"
	@echo "  make bench-full  Full suite"
	@echo ""
	@echo "Examples:"
	@echo "  make match-100k"
	@echo "  make dual-1m"
	@echo "  make run-tcp SCENARIO=42"
