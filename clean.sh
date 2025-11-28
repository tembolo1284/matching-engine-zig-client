#!/bin/bash
# Clean all Zig build artifacts and caches
# Usage: ./clean.sh [--global]

set -e

echo "=== Zig Clean ==="

# Local project caches
if [ -d ".zig-cache" ]; then
    echo "Removing .zig-cache/"
    rm -rf .zig-cache
fi

if [ -d "zig-out" ]; then
    echo "Removing zig-out/"
    rm -rf zig-out
fi

# Global cache (optional with --global flag)
if [ "$1" = "--global" ]; then
    GLOBAL_CACHE=""
    
    # Linux/macOS
    if [ -d "$HOME/.cache/zig" ]; then
        GLOBAL_CACHE="$HOME/.cache/zig"
    fi
    
    # Windows (Git Bash / MSYS2)
    if [ -d "$LOCALAPPDATA/zig" ]; then
        GLOBAL_CACHE="$LOCALAPPDATA/zig"
    fi
    
    # Windows (WSL)
    if [ -d "/mnt/c/Users/$USER/AppData/Local/zig" ]; then
        GLOBAL_CACHE="/mnt/c/Users/$USER/AppData/Local/zig"
    fi
    
    if [ -n "$GLOBAL_CACHE" ] && [ -d "$GLOBAL_CACHE" ]; then
        echo "Removing global cache: $GLOBAL_CACHE"
        rm -rf "$GLOBAL_CACHE"
    fi
fi

echo "Done!"
echo ""
echo "Usage:"
echo "  ./clean.sh          # Clean local project caches"
echo "  ./clean.sh --global # Also clean global Zig cache"
