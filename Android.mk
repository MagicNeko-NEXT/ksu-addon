# ksu-addon build-level target (read-only health check; never nests an m call)
#
#   m ksu-check     # assert: protected refs are clean, kernel checkout is clean,
#                   # patches apply on the current HEAD
#
# The real two-pass build is orchestrated by bin/build.sh. Nesting "m" inside a
# make recipe would fight over the same out/ and soong lock, so it is avoided.

ifeq ($(WITH_KSU),true)
.PHONY: ksu-check
ksu-check:
	@$(TOPDIR)/vendor/oneplus/ksu-addon/bin/ksu.sh check
endif
