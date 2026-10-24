# allow for local directory containing source to be used

LOCAL_SRC ?= $(TOPDIR)/qca/src/$(PKG_NAME)

ifeq (exists, $(shell [ -d $(LOCAL_SRC) ] && echo exists))
# No git revision in PKG_VERSION.
#
# 25.12 builds with apk, whose version grammar requires every dot-separated
# component to start with a digit.  The vendor's "g<sha>" form yields e.g.
# "6.12.112.g57ab21c-r1", which apk rejects ("package version is invalid").
# The revision is not reachable either way: build/sbe1v1k-build.sh exports
# GIT_CEILING_DIRECTORIES=<workspace>/sources, so `git describe` inside the
# assembly tree fails and the string degenerates to a bare "g" - the exact
# value that broke kmod-qca-mdio.  Leaving PKG_VERSION unset gives these
# kernel modules the same version shape as every in-tree kmod.
#
# Cost: PKG_BUILD_DIR drops the "-g<sha>" suffix, so packages built from an
# older assembly tree need `package/<pkg>/clean` after installing this file.
PKG_SOURCE_URL:=
PKG_UNPACK=mkdir -p $(PKG_BUILD_DIR); $(CP) $(LOCAL_SRC)/* $(PKG_BUILD_DIR)/
endif
