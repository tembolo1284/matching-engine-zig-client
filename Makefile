# Matching Engine Zig Client - Makefile
# ======================================
# Default: TCP + Binary protocol (production-like)

# Configuration
HOST ?= 127.0.0.1
PORT ?= 1234
SCENARIO ?= i
ZIG ?= zig
BINARY := ./zig-out/bin/me-client
QUIET ?=

# Build modes: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
MODE ?= ReleaseFast

# Quiet flag (set QUIET=1 for high-volume tests)
QUIET_FLAG := $(if $(filter 1,$(QUIET)),--quiet,)

.PHONY: all build clean rebuild help \
        run interactive \
        run-tcp run-tcp-csv run-udp run-udp-csv \
        scenario-1 scenario-2 scenario-3 \
        stress-1k stress-10k stress-100k \
        match-1k match-10k match-100k match-250k match-500k \
        test check fmt

# ============================================================================
# Core Targets
# ============================================================================

all: build

build:
	@echo "=== Building Matching Engine Client ($(MODE)) ==="
	$(ZIG) build -Doptimize=$(MODE)
	@echo "Build complete: $(BINARY)"

clean:
	@echo "=== Cleaning build artifacts ==="
	@rm -rf .zig-cache zig-out
	@echo "Done!"

rebuild: clean build

# ============================================================================
# Run Targets
# ============================================================================

run: build
	$(BINARY) $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

interactive: build
	$(BINARY) $(HOST) $(PORT) i

# TCP (binary = production, csv = debug)
run-tcp: build
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

run-tcp-csv: build
	$(BINARY) --tcp --csv $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

# UDP
run-udp: build
	$(BINARY) --udp --binary $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

run-udp-csv: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) $(PORT) $(SCENARIO)

# ============================================================================
# Basic Scenarios (1-3)
# ============================================================================

scenario-1: build
	@echo "=== Scenario 1: Simple Orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 1

scenario-2: build
	@echo "=== Scenario 2: Matching Trade ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 2

scenario-3: build
	@echo "=== Scenario 3: Cancel Order ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 3

# ============================================================================
# Unmatched Stress Tests (10-12) - Input Throughput
# ============================================================================

stress-1k: build
	@echo "=== Unmatched Stress: 1K orders ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 10

stress-10k: build
	@echo "=== Unmatched Stress: 10K orders ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 11

stress-100k: build
	@echo "=== Unmatched Stress: 100K orders ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 12

# UDP variants
stress-1k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 10

stress-10k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 11

stress-100k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 12

# ============================================================================
# Matching Stress Tests (20-24) - Trade Throughput - KEY BENCHMARK
# ============================================================================

match-1k: build
	@echo "=== Matching Stress: 1K trades (2K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 20

match-10k: build
	@echo "=== Matching Stress: 10K trades (20K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 21

match-100k: build
	@echo "=== Matching Stress: 100K trades (200K orders) ==="
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 22

match-250k: build
	@echo "=== Matching Stress: 250K trades (500K orders) ==="
	@echo "Tip: Use QUIET=1 for cleaner output"
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 23

match-500k: build
	@echo "=== Matching Stress: 500K trades (1M orders) ==="
	@echo "Tip: Use QUIET=1 for cleaner output"
	$(BINARY) --tcp --binary $(QUIET_FLAG) $(HOST) $(PORT) 24

# UDP matching variants
match-1k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 20

match-10k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 21

match-100k-udp: build
	$(BINARY) --udp --csv $(QUIET_FLAG) $(HOST) 1235 22

# ============================================================================
# Development & Testing
# ============================================================================

test:
	@echo "=== Running Tests ==="
	$(ZIG) build test

check:
	@echo "=== Checking Build ==="
	$(ZIG) build --summary all

fmt:
	@echo "=== Formatting Code ==="
	$(ZIG) fmt src/

# ============================================================================
# Benchmarking
# ============================================================================

bench: build
	@echo "=== Quick Benchmark (1K orders, all modes) ==="
	@echo ""
	@echo "--- TCP Binary ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 10
	@echo ""
	@echo "--- UDP CSV ---"
	@$(BINARY) --udp --csv --quiet $(HOST) 1235 10

bench-match: build
	@echo "=== Matching Benchmark ==="
	@echo ""
	@echo "--- 1K Trades ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 20
	@echo ""
	@echo "--- 10K Trades ---"
	@$(BINARY) --tcp --binary --quiet $(HOST) $(PORT) 21

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Matching Engine Zig Client"
	@echo "=========================="
	@echo ""
	@echo "Configuration (override with VAR=value):"
	@echo "  HOST=$(HOST)        Server host"
	@echo "  PORT=$(PORT)            TCP port (UDP uses 1235)"
	@echo "  SCENARIO=$(SCENARIO)          Scenario number or 'i' for interactive"
	@echo "  QUIET=1             Suppress progress output"
	@echo "  MODE=$(MODE)     Build optimization"
	@echo ""
	@echo "Build:"
	@echo "  make build          Build client"
	@echo "  make clean          Remove build artifacts"
	@echo "  make rebuild        Clean and build"
	@echo ""
	@echo "Run:"
	@echo "  make run            Auto-detect (TCP/binary)"
	@echo "  make run-tcp        TCP + Binary"
	@echo "  make run-tcp-csv    TCP + CSV"
	@echo "  make run-udp        UDP + Binary"
	@echo "  make run-udp-csv    UDP + CSV"
	@echo "  make interactive    Interactive mode"
	@echo ""
	@echo "Basic Scenarios:"
	@echo "  make scenario-1     Simple orders (no match)"
	@echo "  make scenario-2     Matching trade"
	@echo "  make scenario-3     Cancel order"
	@echo ""
	@echo "Unmatched Stress (input throughput):"
	@echo "  make stress-1k      1K orders"
	@echo "  make stress-10k     10K orders"
	@echo "  make stress-100k    100K orders"
	@echo ""
	@echo "Matching Stress (trade throughput) - KEY BENCHMARK:"
	@echo "  make match-1k       1K trades   (2K orders)"
	@echo "  make match-10k      10K trades  (20K orders)"
	@echo "  make match-100k     100K trades (200K orders)"
	@echo "  make match-250k     250K trades (500K orders)"
	@echo "  make match-500k     500K trades (1M orders)"
	@echo ""
	@echo "UDP Variants:"
	@echo "  make stress-1k-udp, stress-10k-udp, stress-100k-udp"
	@echo "  make match-1k-udp, match-10k-udp, match-100k-udp"
	@echo ""
	@echo "Benchmarking:"
	@echo "  make bench          Quick benchmark (1K)"
	@echo "  make bench-match    Matching benchmark (1K, 10K)"
	@echo ""
	@echo "Development:"
	@echo "  make test           Run unit tests"
	@echo "  make check          Check build"
	@echo "  make fmt            Format source code"
	@echo ""
	@echo "Examples:"
	@echo "  make match-100k                    Run 100K matching test"
	@echo "  make match-250k QUIET=1            Large test, quiet mode"
	@echo "  make run-tcp SCENARIO=22           Run specific scenario"
	@echo "  make stress-100k HOST=10.0.0.5     Test remote server"
