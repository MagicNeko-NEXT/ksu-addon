# ksu-addon 产品级开关（默认零影响）
#
# 在 device/oneplus/ovaltine/ovaltine.mk 里加一行即可启用本开关：
#   $(call inherit-product-if-exists, vendor/oneplus/ksu-addon/ksu.mk)
#
# WITH_KSU 语义：
#   false / 未设置 —— 完全无影响（不注册任何包、不改任何属性）
#   true           —— 构建入口 bin/build.sh 会多跑一遍带 root 的内核，
#                     并允许在这里追加用户态组件
#
# 注意：这里追加 PRODUCT_PACKAGES / 属性会让 **system 镜像变脸**，
# 于是第二遍构建要多花一次 system image 的时间，而且两个包的 system 分区不再相同。
# 所以默认全部留空 —— 两个包只差 boot.img + vendor_dlkm，增量最省、隔离最干净。
# KSU 的用户态（susfs CLI、ReSukiSU Manager）建议作为 KSU 模块 / 单独 APK 分发。

WITH_KSU ?= false

ifeq ($(WITH_KSU),true)
  # —— 想让它进镜像时再放开，并接受 system 镜像重建的代价 ——
  # PRODUCT_PACKAGES += susfs
  # PRODUCT_PACKAGES += ReSukiSUManager
  # PRODUCT_PROPERTY_OVERRIDES += ro.ksu.addon=1
endif
