#!/bin/sh
zig build && ./zig-out/bin/pngine examples/demo2025/simpleR.wgsl.pngine --html -o /tmp/simpleR.html && wc -c /tmp/simpleR.html
