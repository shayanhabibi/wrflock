version = "0.4.1"
author = "Shayan Habibi"
description = "Write, Read, Free lock primitive"
license = "MIT"

requires "https://github.com/shayanhabibi/futex < 1.0.0"
requires "https://github.com/shayanhabibi/waitonaddress < 1.0.0"
requires "https://github.com/shayanhabibi/ulock < 1.0.0"

when not defined(release):
  requires "https://github.com/disruptek/balls >= 3.0.0 & < 4.0.0"

task test, "run tests for ci":
  when defined(windows):
    exec """env GITHUB_ACTIONS="false" balls.cmd"""
  else:
    exec """env GITHUB_ACTIONS="false" balls"""
