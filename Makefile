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
        match-1k match-10k match-100k match-250k match-500k match-250m \
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

# UDP variants
stress-1k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 10

stress-10k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 11

stress-100k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 12

# ============================================================================
# Matching Stress (20-25) ★ KEY BENCHMARK
# ============================================================================

match-1k: build
	@echo "=== 1K Trades (2K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 20

match-10k: build
	@echo "=== 10K Trades (20K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 21

match-100k: build
	@echo "=== 100K Trades (200K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 22

match-250k: build
	@echo "=== 250K Trades (500K orders) ==="
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 23

match-500k: build
	@echo "=== 500K Trades (1M orders) ==="
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 24

match-250m: build
	@echo ""
	@echo "★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★"
	@echo "★★★ LEGENDARY: 250M Trades (500M orders) ★★★"
	@echo "★★★ Blood, Sweat, and Tears Mode ★★★"
	@echo "★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★"
	@echo ""
	$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 25

# UDP matching variants
match-1k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 20

match-10k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 21

match-100k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 22

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
# Benchmarking
# ============================================================================

bench: build
	@echo "=== Quick Benchmark ==="
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 20
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 21

bench-full: build
	@echo "=== Full Benchmark Suite ==="
	@echo "--- 1K Trades ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 20
	@echo "--- 10K Trades ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 21
	@echo "--- 100K Trades ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 22

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Matching Engine Zig Client"
	@echo "=========================="
	@echo ""
	@echo "Config: HOST=$(HOST) PORT=$(PORT) QUIET=$(QUIET)"
	@echo ""
	@echo "Build:"
	@echo "  make build    Build client"
	@echo "  make clean    Remove artifacts"
	@echo "  make rebuild  Clean + build"
	@echo ""
	@echo "Run:"
	@echo "  make run          Auto-detect"
	@echo "  make run-tcp      TCP + Binary"
	@echo "  make run-tcp-csv  TCP + CSV"
	@echo "  make run-udp      UDP + Binary"
	@echo "  make run-udp-csv  UDP + CSV"
	@echo "  make interactive  Interactive mode"
	@echo ""
	@echo "Basic: scenario-1, scenario-2, scenario-3"
	@echo ""
	@echo "Unmatched Stress:"
	@echo "  make stress-1k / stress-10k / stress-100k"
	@echo ""
	@echo "Matching Stress ★ KEY BENCHMARK:"
	@echo "  make match-1k      1K trades   (2K orders)"
	@echo "  make match-10k     10K trades  (20K orders)"
	@echo "  make match-100k    100K trades (200K orders)"
	@echo "  make match-250k    250K trades (500K orders)"
	@echo "  make match-500k    500K trades (1M orders)"
	@echo "  make match-250m    250M trades (500M orders) ★★★ LEGENDARY ★★★"
	@echo ""
	@echo "UDP: stress-*-udp, match-*-udp (use port 1235)"
	@echo ""
	@echo "Benchmarking:"
	@echo "  make bench       Quick (1K, 10K)"
	@echo "  make bench-full  Full (1K, 10K, 100K)"
	@echo ""
	@echo "Development: test, check, fmt"
	@echo ""
	@echo "Examples:"
	@echo "  make match-100k"
	@echo "  make match-250k QUIET=1"
	@echo "  make run-tcp SCENARIO=22"
	@echo "  make match-250m  # Glory awaits!"
