# ksu-addon product-level switch (no-op by default)
#
# Enable it from device/oneplus/ovaltine/ovaltine.mk with:
#   $(call inherit-product-if-exists, vendor/oneplus/ksu-addon/ksu.mk)
#
# WITH_KSU semantics:
#   false / unset -- no effect at all (no packages, no properties)
#   true          -- bin/build.sh runs one extra rooted pass per variant
#
# NOTE: adding PRODUCT_PACKAGES or properties here changes the system image, so
# the second pass costs a system image rebuild and the two packages no longer
# share an identical system partition. Everything is left empty on purpose:
# the packages should differ only in boot.img + vendor_dlkm.
# KSU userspace bits (susfs CLI, manager APK) are better shipped as a KSU
# module / standalone APK.

WITH_KSU ?= false

ifeq ($(WITH_KSU),true)
  # Uncomment when you really want them inside the image:
  # PRODUCT_PACKAGES += susfs
  # PRODUCT_PACKAGES += ReSukiSUManager
  # PRODUCT_PROPERTY_OVERRIDES += ro.ksu.addon=1
endif
