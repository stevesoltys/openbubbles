#!/usr/bin/env bash

# Pull submodules
git submodule update --init --recursive

# Build APK
flutter build apk --flavor alpha --debug --target-platform android-arm64