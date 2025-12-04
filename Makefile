# Matching Engine Zig Client - Makefile
# ======================================
# Default: TCP + Binary protocol (production-like)
# Use --csv flag or -csv targets for CSV protocol

# Configuration
HOST ?= 127.0.0.1
PORT ?= 1234
SCENARIO ?= i
ZIG ?= zig
BINARY := ./zig-out/bin/me-client

# Build modes
MODE ?= ReleaseFast
# Options: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall

.PHONY: all build clean clean-global help run \
        run-tcp run-tcp-csv run-udp run-udp-csv \
        scenario-% stress-% interactive \
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
	@echo "=== Cleaning local build artifacts ==="
	@rm -rf .zig-cache zig-out
	@echo "Done!"

clean-global: clean
	@echo "=== Cleaning global Zig cache ==="
	@rm -rf $(HOME)/.cache/zig 2>/dev/null || true
	@rm -rf $(LOCALAPPDATA)/zig 2>/dev/null || true
	@echo "Done!"

rebuild: clean build

# ============================================================================
# Run Targets - Default is Binary protocol
# ============================================================================

# Interactive mode (auto-detect)
run: build
	$(BINARY) $(HOST) $(PORT) $(SCENARIO)

interactive: build
	$(BINARY) $(HOST) $(PORT) i

# TCP (binary by default - production mode)
run-tcp: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) $(SCENARIO)

run-tcp-csv: build
	$(BINARY) --tcp --csv $(HOST) $(PORT) $(SCENARIO)

# UDP (binary by default)
run-udp: build
	$(BINARY) --udp --binary $(HOST) $(PORT) $(SCENARIO)

run-udp-csv: build
	$(BINARY) --udp --csv $(HOST) $(PORT) $(SCENARIO)

# ============================================================================
# Basic Scenarios (1-3)
# ============================================================================

# Simple orders
scenario-1: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 1

scenario-1-csv: build
	$(BINARY) --tcp --csv $(HOST) $(PORT) 1

# Matching trade
scenario-2: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 2

scenario-2-csv: build
	$(BINARY) --tcp --csv $(HOST) $(PORT) 2

# Cancel order
scenario-3: build
	$(BINARY) --tcp --binary $(HOST) $(PORT) 3

# ============================================================================
# Stress Tests - Order Volume (scenarios 10-14)
# ============================================================================

stress-1k: build
	@echo "=== Stress Test: 1K orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 10

stress-10k: build
	@echo "=== Stress Test: 10K orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 11

stress-100k: build
	@echo "=== Stress Test: 100K orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 12

stress-1m: build
	@echo "=== Stress Test: 1M orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 13

stress-10m: build
	@echo "=== EXTREME Stress Test: 10M orders ==="
	@echo "Warning: This may take a while and use significant memory"
	$(BINARY) --tcp --binary $(HOST) $(PORT) 14

# ============================================================================
# Stress Tests - Matching (scenarios 20-21)
# ============================================================================

match-1k: build
	@echo "=== Matching Stress: 1K trade pairs ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 20

match-10k: build
	@echo "=== Matching Stress: 10K trade pairs ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 21

# ============================================================================
# Stress Tests - Multi-Symbol (scenario 30)
# ============================================================================

multi-symbol: build
	@echo "=== Multi-Symbol Stress: 10K orders ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 30

# ============================================================================
# Burst Mode - No Throttling (scenarios 40-41)
# ============================================================================

burst-100k: build
	@echo "=== Burst Mode: 100K orders (no throttling) ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 40

burst-1m: build
	@echo "=== Burst Mode: 1M orders (no throttling) ==="
	$(BINARY) --tcp --binary $(HOST) $(PORT) 41

# ============================================================================
# UDP Variants of Stress Tests
# ============================================================================

stress-1k-udp: build
	$(BINARY) --udp --binary $(HOST) $(PORT) 10

stress-10k-udp: build
	$(BINARY) --udp --binary $(HOST) $(PORT) 11

stress-100k-udp: build
	$(BINARY) --udp --binary $(HOST) $(PORT) 12

burst-100k-udp: build
	$(BINARY) --udp --binary $(HOST) $(PORT) 40

# ============================================================================
# CSV Variants (for debugging/visibility)
# ============================================================================

stress-1k-csv: build
	$(BINARY) --tcp --csv $(HOST) $(PORT) 10

stress-10k-csv: build
	$(BINARY) --tcp --csv $(HOST) $(PORT) 11

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
	$(ZIG) fmt tests/ 2>/dev/null || true

# ============================================================================
# Benchmarking Suite
# ============================================================================

bench: build
	@echo "=== Running Benchmark Suite ==="
	@echo ""
	@echo "--- TCP Binary ---"
	@$(BINARY) --tcp --binary $(HOST) $(PORT) 10
	@echo ""
	@echo "--- TCP CSV ---"
	@$(BINARY) --tcp --csv $(HOST) $(PORT) 10
	@echo ""
	@echo "--- UDP Binary ---"
	@$(BINARY) --udp --binary $(HOST) $(PORT) 10
	@echo ""
	@echo "--- UDP CSV ---"
	@$(BINARY) --udp --csv $(HOST) $(PORT) 10

bench-full: build
	@echo "=== Full Benchmark Suite (100K each) ==="
	@for proto in tcp udp; do \
		for fmt in binary csv; do \
			echo ""; \
			echo "--- $$proto $$fmt ---"; \
			$(BINARY) --$$proto --$$fmt $(HOST) $(PORT) 12; \
		done \
	done

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Matching Engine Zig Client - Makefile"
	@echo "======================================"
	@echo ""
	@echo "Configuration (override with VAR=value):"
	@echo "  HOST=$(HOST)      Server host"
	@echo "  PORT=$(PORT)          Server port"
	@echo "  SCENARIO=$(SCENARIO)        Test scenario (i=interactive)"
	@echo "  MODE=$(MODE)   Build optimization level"
	@echo ""
	@echo "Core Targets:"
	@echo "  make build         Build the client (ReleaseFast)"
	@echo "  make clean         Remove local build artifacts"
	@echo "  make clean-global  Also remove global Zig cache"
	@echo "  make rebuild       Clean and build"
	@echo ""
	@echo "Run Targets (Binary protocol = default):"
	@echo "  make run           Auto-detect transport/protocol"
	@echo "  make run-tcp       TCP + Binary (production)"
	@echo "  make run-tcp-csv   TCP + CSV (debug)"
	@echo "  make run-udp       UDP + Binary"
	@echo "  make run-udp-csv   UDP + CSV (debug)"
	@echo "  make interactive   Interactive mode"
	@echo ""
	@echo "Basic Scenarios:"
	@echo "  make scenario-1    Simple orders (buy + sell + flush)"
	@echo "  make scenario-2    Matching trade"
	@echo "  make scenario-3    Cancel order"
	@echo ""
	@echo "Stress Tests (TCP Binary):"
	@echo "  make stress-1k     1,000 orders"
	@echo "  make stress-10k    10,000 orders"
	@echo "  make stress-100k   100,000 orders"
	@echo "  make stress-1m     1,000,000 orders"
	@echo "  make stress-10m    10,000,000 orders (EXTREME)"
	@echo ""
	@echo "Matching Stress:"
	@echo "  make match-1k      1,000 trade pairs"
	@echo "  make match-10k     10,000 trade pairs"
	@echo ""
	@echo "Burst Mode (no throttling):"
	@echo "  make burst-100k    100K orders, max speed"
	@echo "  make burst-1m      1M orders, max speed"
	@echo ""
	@echo "UDP Stress Variants:"
	@echo "  make stress-1k-udp, stress-10k-udp, stress-100k-udp"
	@echo "  make burst-100k-udp"
	@echo ""
	@echo "CSV Variants (for debugging):"
	@echo "  make stress-1k-csv, stress-10k-csv"
	@echo ""
	@echo "Benchmarking:"
	@echo "  make bench         Quick benchmark (1K, all modes)"
	@echo "  make bench-full    Full benchmark (100K, all modes)"
	@echo ""
	@echo "Development:"
	@echo "  make test          Run unit tests"
	@echo "  make check         Check build"
	@echo "  make fmt           Format source code"
	@echo ""
	@echo "Examples:"
	@echo "  make run-tcp SCENARIO=2          Run scenario 2 over TCP"
	@echo "  make stress-100k HOST=10.0.0.5   Stress test remote server"
	@echo "  make build MODE=Debug            Debug build"
