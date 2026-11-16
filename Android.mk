# ksu-addon 构建级目标（只读体检，不嵌套 m）
#
#   m ksu-check     # 断言：主线 ref 无 KSU、内核 checkout 干净、补丁能在当前 HEAD 上干净应用
#
# 注意：这里只做检查。真正的两遍构建由 bin/build.sh 编排 ——
# 在 make 里嵌套 m 会抢同一个 out/ 与 soong 锁，必定翻车。

ifeq ($(WITH_KSU),true)
.PHONY: ksu-check
ksu-check:
	@$(TOPDIR)/vendor/oneplus/ksu-addon/bin/ksu.sh check
endif
