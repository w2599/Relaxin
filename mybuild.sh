#!/bin/bash

pkill -f 'xcodebuild' || true
pkill -f 'run-xcodebuild.sh' || true
pkill -f 'build-basebin-resources.sh' || true
pkill -f 'make.*BaseBin' || true
pkill -f 'swiftc' || true
pkill -f 'clang' || true


cd "$(dirname "$0")" || exit 1

if [ $1 -eq "2" ]
then
    make ipa -j4 && make tipa -j4
    exit 0
fi


make ipa