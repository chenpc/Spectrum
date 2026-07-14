#!/bin/zsh
# 編譯 hdr-lab 實驗工具
set -e
cd "$(dirname "$0")"
swiftc -O -o hdrlab main.swift
echo "OK → $(pwd)/hdrlab"
