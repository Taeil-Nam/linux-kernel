/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Low-level CPU initialisation
 * Based on arch/arm/kernel/head.S
 *
 * Copyright (C) 1994-2002 Russell King
 * Copyright (C) 2003-2012 ARM Ltd.
 * Authors:	Catalin Marinas <catalin.marinas@arm.com>
 *		Will Deacon <will.deacon@arm.com>
 * Comments:	Taeil Nam <nam0314@gmail.com>
 *		2025/06/23
 */

#include <linux/linkage.h>	// 함수 선언 및 어셈블리 linkage 관련 매크로
#include <linux/init.h> 	// __init 등 초기화 함수 매크로
#include <linux/pgtable.h> 	// 페이지 테이블 공통 정의

#include <asm/asm_pointer_auth.h>	// ARMv8.3 PAC(Pointer Authentication Code) 관련
#include <asm/assembler.h>		// 어셈블리 매크로 및 헬퍼 함수들
#include <asm/boot.h>			// 부팅에 필요한 구조체 및 상수
#include <asm/bug.h>			// BUG(), assert 같은 디버깅용 매크로
#include <asm/ptrace.h>			// 트랩 발생시 CPU 상태 저장 구조체
#include <asm/asm-offsets.h>		// 구조체 오프셋 정보 (C <-> ASM 연동용)
#include <asm/cache.h>			// 캐시 관련 정의 (라인 크기 등)
#include <asm/cputype.h>		// CPU 종류 및 특성 관련 매크로
#include <asm/el2_setup.h>		// Exception Level 2 설정 (KVM/가상화)
#include <asm/elf.h>			// ELF 바이너리 로딩 관련 구조체
#include <asm/image.h>			// 커널 이미지 관련 구조체 및 매크로
#include <asm/kernel-pgtable.h>		// 초기 코널 페이지 테이블 설정용
#include <asm/kvm_arm.h>		// ARM 가상화(KVM) 관련 정의
#include <asm/memory.h>			// 메모리 맵/주소 변환 매크로
#include <asm/pgtable-hwdef.h>		// MMU 레벨/페이지 관련 하드웨어 정의
#include <asm/page.h>			// 페이지 크기, 페이지 관련 연산
#include <asm/scs.h>			// Shadow Call Stack 관련
#include <asm/smp.h>			// 다중 코어 초기화 관련
#include <asm/sysreg.h>			// 시스템 레지스터 조작용 매크로
#include <asm/thread_info.h>		// 스레드 정보 구조체
#include <asm/virt.h>			// 가상화 하드웨어 지원 관련 정의

#include "efi-header.S"			// UEFI(EFI) 기반 시스템에서 부팅될 때
					// 필요한 매크로/상수 또는 구조체 정의

// PAGE_OFFSET은 커널 가상 주소의 시작 위치를 나타냄.
// ARM64_VA_BITS_48 설정을 사용하는 경우(pc, server) PAGE_OFFSET = 0xFFFF_0000_0000_0000
#if (PAGE_OFFSET & 0x1fffff) != 0		// PAGE_OFFSET 값이 2MB(0x200000) 정렬 되어있지 않은 경우
#error PAGE_OFFSET must be at least 2MB aligned	// 컴파일을 실패시키고 메시지 출력
#endif

// MMU : 가상 메모리 주소 -> 물리 메모리 주소 변환 역할을 하는 메모리 관리용 하드웨어.
// MMU는 비활성화 상태로 시작되어, 커널 초기화 도중에 활성화 됨.
// D-cache : 데이터 캐시.
// I-cache : 명령어 캐시.
// x0 = FDT blob의 물리 주소를 나타냄.
// FDT blob = 디바이스 트리의 바이너리 형태.
// 디바이스 트리 = 커널이 실행되는 하드웨어의 구성 요소들을 표현한 자료구조.
/*
 * Kernel startup entry point.
 * ---------------------------
 *
 * The requirements are:
 *   MMU = off, D-cache = off, I-cache = on or off,
 *   x0 = physical address to the FDT blob.
 *
 * Note that the callee-saved registers are used for storing variables
 * that are useful before the MMU is enabled. The allocations are described
 * in the entry routines.
 */
	__HEAD	// .section ".head.text","ax"
	/*
	 * DO NOT MODIFY. Image header expected by Linux boot-loaders.
	 */
	efi_signature_nop			// special NOP to identity as PE/COFF executable
	// b 명령어는 주어진 주소로 분기하라는 명령어.
	// C 언어의 goto문과 동일.
	b	primary_entry			// branch to kernel start, magic
	.quad	0				// Image load offset from start of RAM, little-endian
	le64sym	_kernel_size_le			// Effective size of kernel image, little-endian
	le64sym	_kernel_flags_le		// Informative flags, little-endian
	.quad	0				// reserved
	.quad	0				// reserved
	.quad	0				// reserved
	.ascii	ARM64_IMAGE_MAGIC		// Magic number
	.long	.Lpe_header_offset		// Offset to the PE header.

	__EFI_PE_HEADER

	.section ".idmap.text","a"

	/*
	 * The following callee saved general purpose registers are used on the
	 * primary lowlevel boot path:
	 *
	 *  Register   Scope                      Purpose
	 *  x19        primary_entry() .. start_kernel()        whether we entered with the MMU on
	 *  x20        primary_entry() .. __primary_switch()    CPU boot mode
	 *  x21        primary_entry() .. start_kernel()        FDT pointer passed at boot in x0
	 */
// SYM_CODE_START(name) = name이라는 이름을 가지는 전역 코드 심볼의 시작을 정의.
// 다른 어셈블리 파일이나 C 파일에서 이 심볼 호출 및 참조 가능.
SYM_CODE_START(primary_entry)
	bl	record_mmu_state
	bl	preserve_boot_args

	adrp	x1, early_init_stack
	mov	sp, x1
	mov	x29, xzr
	adrp	x0, init_idmap_pg_dir
	mov	x1, xzr
	bl	__pi_create_init_idmap

	/*
	 * If the page tables have been populated with non-cacheable
	 * accesses (MMU disabled), invalidate those tables again to
	 * remove any speculatively loaded cache lines.
	 */
	cbnz	x19, 0f
	dmb     sy
	mov	x1, x0				// end of used region
	adrp    x0, init_idmap_pg_dir
	adr_l	x2, dcache_inval_poc
	blr	x2
	b	1f

	/*
	 * If we entered with the MMU and caches on, clean the ID mapped part
	 * of the primary boot code to the PoC so we can safely execute it with
	 * the MMU off.
	 */
0:	adrp	x0, __idmap_text_start
	adr_l	x1, __idmap_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2

1:	mov	x0, x19
	bl	init_kernel_el			// w0=cpu_boot_mode
	mov	x20, x0

	/*
	 * The following calls CPU setup code, see arch/arm64/mm/proc.S for
	 * details.
	 * On return, the CPU will be ready for the MMU to be turned on and
	 * the TCR will have been set.
	 */
	bl	__cpu_setup			// initialise processor
	b	__primary_switch
SYM_CODE_END(primary_entry)

	__INIT	// .section        ".init.text","ax"
SYM_CODE_START_LOCAL(record_mmu_state)
	mrs	x19, CurrentEL
	cmp	x19, #CurrentEL_EL2
	mrs	x19, sctlr_el1
	b.ne	0f
	mrs	x19, sctlr_el2
0:
CPU_LE( tbnz	x19, #SCTLR_ELx_EE_SHIFT, 1f	)
CPU_BE( tbz	x19, #SCTLR_ELx_EE_SHIFT, 1f	)
	tst	x19, #SCTLR_ELx_C		// Z := (C == 0)
	and	x19, x19, #SCTLR_ELx_M		// isolate M bit
	csel	x19, xzr, x19, eq		// clear x19 if Z
	ret

	/*
	 * Set the correct endianness early so all memory accesses issued
	 * before init_kernel_el() occur in the correct byte order. Note that
	 * this means the MMU must be disabled, or the active ID map will end
	 * up getting interpreted with the wrong byte order.
	 */
1:	eor	x19, x19, #SCTLR_ELx_EE
	bic	x19, x19, #SCTLR_ELx_M
	b.ne	2f
	pre_disable_mmu_workaround
	msr	sctlr_el2, x19
	b	3f
2:	pre_disable_mmu_workaround
	msr	sctlr_el1, x19
3:	isb
	mov	x19, xzr
	ret
SYM_CODE_END(record_mmu_state)

/*
 * Preserve the arguments passed by the bootloader in x0 .. x3
 */
SYM_CODE_START_LOCAL(preserve_boot_args)
	mov	x21, x0				// x21=FDT

	adr_l	x0, boot_args			// record the contents of
	stp	x21, x1, [x0]			// x0 .. x3 at kernel entry
	stp	x2, x3, [x0, #16]

	cbnz	x19, 0f				// skip cache invalidation if MMU is on
	dmb	sy				// needed before dc ivac with
						// MMU off

	add	x1, x0, #0x20			// 4 x 8 bytes
	b	dcache_inval_poc		// tail call
0:	str_l   x19, mmu_enabled_at_boot, x0
	ret
SYM_CODE_END(preserve_boot_args)

	/*
	 * Initialize CPU registers with task-specific and cpu-specific context.
	 *
	 * Create a final frame record at task_pt_regs(current)->stackframe, so
	 * that the unwinder can identify the final frame record of any task by
	 * its location in the task stack. We reserve the entire pt_regs space
	 * for consistency with user tasks and kthreads.
	 */
	.macro	init_cpu_task tsk, tmp1, tmp2
	msr	sp_el0, \tsk

	ldr	\tmp1, [\tsk, #TSK_STACK]
	add	sp, \tmp1, #THREAD_SIZE
	sub	sp, sp, #PT_REGS_SIZE

	stp	xzr, xzr, [sp, #S_STACKFRAME]
	add	x29, sp, #S_STACKFRAME

	scs_load_current

	adr_l	\tmp1, __per_cpu_offset
	ldr	w\tmp2, [\tsk, #TSK_TI_CPU]
	ldr	\tmp1, [\tmp1, \tmp2, lsl #3]
	set_this_cpu_offset \tmp1
	.endm

/*
 * The following fragment of code is executed with the MMU enabled.
 *
 *   x0 = __pa(KERNEL_START)
 */
SYM_FUNC_START_LOCAL(__primary_switched)
	adr_l	x4, init_task
	init_cpu_task x4, x5, x6

	adr_l	x8, vectors			// load VBAR_EL1 with virtual
	msr	vbar_el1, x8			// vector table address
	isb

	stp	x29, x30, [sp, #-16]!
	mov	x29, sp

	str_l	x21, __fdt_pointer, x5		// Save FDT pointer

	adrp	x4, _text			// Save the offset between
	sub	x4, x4, x0			// the kernel virtual and
	str_l	x4, kimage_voffset, x5		// physical mappings

	mov	x0, x20
	bl	set_cpu_boot_mode_flag

#if defined(CONFIG_KASAN_GENERIC) || defined(CONFIG_KASAN_SW_TAGS)
	bl	kasan_early_init
#endif
	mov	x0, x20
	bl	finalise_el2			// Prefer VHE if possible
	ldp	x29, x30, [sp], #16
	bl	start_kernel
	ASM_BUG()
SYM_FUNC_END(__primary_switched)

/*
 * end early head section, begin head code that is also used for
 * hotplug and needs to have the same protections as the text region
 */
	.section ".idmap.text","a"

/*
 * Starting from EL2 or EL1, configure the CPU to execute at the highest
 * reachable EL supported by the kernel in a chosen default state. If dropping
 * from EL2 to EL1, configure EL2 before configuring EL1.
 *
 * Since we cannot always rely on ERET synchronizing writes to sysregs (e.g. if
 * SCTLR_ELx.EOS is clear), we place an ISB prior to ERET.
 *
 * Returns either BOOT_CPU_MODE_EL1 or BOOT_CPU_MODE_EL2 in x0 if
 * booted in EL1 or EL2 respectively, with the top 32 bits containing
 * potential context flags. These flags are *not* stored in __boot_cpu_mode.
 *
 * x0: whether we are being called from the primary boot path with the MMU on
 */
SYM_FUNC_START(init_kernel_el)
	mrs	x1, CurrentEL
	cmp	x1, #CurrentEL_EL2
	b.eq	init_el2

SYM_INNER_LABEL(init_el1, SYM_L_LOCAL)
	mov_q	x0, INIT_SCTLR_EL1_MMU_OFF
	pre_disable_mmu_workaround
	msr	sctlr_el1, x0
	isb
	mov_q	x0, INIT_PSTATE_EL1
	msr	spsr_el1, x0
	msr	elr_el1, lr
	mov	w0, #BOOT_CPU_MODE_EL1
	eret

SYM_INNER_LABEL(init_el2, SYM_L_LOCAL)
	msr	elr_el2, lr

	// clean all HYP code to the PoC if we booted at EL2 with the MMU on
	cbz	x0, 0f
	adrp	x0, __hyp_idmap_text_start
	adr_l	x1, __hyp_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2

	mov_q	x0, INIT_SCTLR_EL2_MMU_OFF
	pre_disable_mmu_workaround
	msr	sctlr_el2, x0
	isb
0:
	mov_q	x0, HCR_HOST_NVHE_FLAGS

	/*
	 * Compliant CPUs advertise their VHE-onlyness with
	 * ID_AA64MMFR4_EL1.E2H0 < 0. HCR_EL2.E2H can be
	 * RES1 in that case. Publish the E2H bit early so that
	 * it can be picked up by the init_el2_state macro.
	 *
	 * Fruity CPUs seem to have HCR_EL2.E2H set to RAO/WI, but
	 * don't advertise it (they predate this relaxation).
	 */
	mrs_s	x1, SYS_ID_AA64MMFR4_EL1
	tbz	x1, #(ID_AA64MMFR4_EL1_E2H0_SHIFT + ID_AA64MMFR4_EL1_E2H0_WIDTH - 1), 1f

	orr	x0, x0, #HCR_E2H
1:
	msr	hcr_el2, x0
	isb

	init_el2_state

	/* Hypervisor stub */
	adr_l	x0, __hyp_stub_vectors
	msr	vbar_el2, x0
	isb

	mov_q	x1, INIT_SCTLR_EL1_MMU_OFF

	mrs	x0, hcr_el2
	and	x0, x0, #HCR_E2H
	cbz	x0, 2f

	/* Set a sane SCTLR_EL1, the VHE way */
	msr_s	SYS_SCTLR_EL12, x1
	mov	x2, #BOOT_CPU_FLAG_E2H
	b	3f

2:
	msr	sctlr_el1, x1
	mov	x2, xzr
3:
	__init_el2_nvhe_prepare_eret

	mov	w0, #BOOT_CPU_MODE_EL2
	orr	x0, x0, x2
	eret
SYM_FUNC_END(init_kernel_el)

	/*
	 * This provides a "holding pen" for platforms to hold all secondary
	 * cores are held until we're ready for them to initialise.
	 */
SYM_FUNC_START(secondary_holding_pen)
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	mrs	x2, mpidr_el1
	mov_q	x1, MPIDR_HWID_BITMASK
	and	x2, x2, x1
	adr_l	x3, secondary_holding_pen_release
pen:	ldr	x4, [x3]
	cmp	x4, x2
	b.eq	secondary_startup
	wfe
	b	pen
SYM_FUNC_END(secondary_holding_pen)

	/*
	 * Secondary entry point that jumps straight into the kernel. Only to
	 * be used where CPUs are brought online dynamically by the kernel.
	 */
SYM_FUNC_START(secondary_entry)
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	b	secondary_startup
SYM_FUNC_END(secondary_entry)

SYM_FUNC_START_LOCAL(secondary_startup)
	/*
	 * Common entry point for secondary CPUs.
	 */
	mov	x20, x0				// preserve boot mode

#ifdef CONFIG_ARM64_VA_BITS_52
alternative_if ARM64_HAS_VA52
	bl	__cpu_secondary_check52bitva
alternative_else_nop_endif
#endif

	bl	__cpu_setup			// initialise processor
	adrp	x1, swapper_pg_dir
	adrp	x2, idmap_pg_dir
	bl	__enable_mmu
	ldr	x8, =__secondary_switched
	br	x8
SYM_FUNC_END(secondary_startup)

	.text
SYM_FUNC_START_LOCAL(__secondary_switched)
	mov	x0, x20
	bl	set_cpu_boot_mode_flag

	mov	x0, x20
	bl	finalise_el2

	str_l	xzr, __early_cpu_boot_status, x3
	adr_l	x5, vectors
	msr	vbar_el1, x5
	isb

	adr_l	x0, secondary_data
	ldr	x2, [x0, #CPU_BOOT_TASK]
	cbz	x2, __secondary_too_slow

	init_cpu_task x2, x1, x3

#ifdef CONFIG_ARM64_PTR_AUTH
	ptrauth_keys_init_cpu x2, x3, x4, x5
#endif

	bl	secondary_start_kernel
	ASM_BUG()
SYM_FUNC_END(__secondary_switched)

SYM_FUNC_START_LOCAL(__secondary_too_slow)
	wfe
	wfi
	b	__secondary_too_slow
SYM_FUNC_END(__secondary_too_slow)

/*
 * Sets the __boot_cpu_mode flag depending on the CPU boot mode passed
 * in w0. See arch/arm64/include/asm/virt.h for more info.
 */
SYM_FUNC_START_LOCAL(set_cpu_boot_mode_flag)
	adr_l	x1, __boot_cpu_mode
	cmp	w0, #BOOT_CPU_MODE_EL2
	b.ne	1f
	add	x1, x1, #4
1:	str	w0, [x1]			// Save CPU boot mode
	ret
SYM_FUNC_END(set_cpu_boot_mode_flag)

/*
 * The booting CPU updates the failed status @__early_cpu_boot_status,
 * with MMU turned off.
 *
 * update_early_cpu_boot_status tmp, status
 *  - Corrupts tmp1, tmp2
 *  - Writes 'status' to __early_cpu_boot_status and makes sure
 *    it is committed to memory.
 */

	.macro	update_early_cpu_boot_status status, tmp1, tmp2
	mov	\tmp2, #\status
	adr_l	\tmp1, __early_cpu_boot_status
	str	\tmp2, [\tmp1]
	dmb	sy
	dc	ivac, \tmp1			// Invalidate potentially stale cache line
	.endm

/*
 * Enable the MMU.
 *
 *  x0  = SCTLR_EL1 value for turning on the MMU.
 *  x1  = TTBR1_EL1 value
 *  x2  = ID map root table address
 *
 * Returns to the caller via x30/lr. This requires the caller to be covered
 * by the .idmap.text section.
 *
 * Checks if the selected granule size is supported by the CPU.
 * If it isn't, park the CPU
 */
	.section ".idmap.text","a"
SYM_FUNC_START(__enable_mmu)
	mrs	x3, ID_AA64MMFR0_EL1
	ubfx	x3, x3, #ID_AA64MMFR0_EL1_TGRAN_SHIFT, 4
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MIN
	b.lt    __no_granule_support
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MAX
	b.gt    __no_granule_support
	phys_to_ttbr x2, x2
	msr	ttbr0_el1, x2			// load TTBR0
	load_ttbr1 x1, x1, x3

	set_sctlr_el1	x0

	ret
SYM_FUNC_END(__enable_mmu)

#ifdef CONFIG_ARM64_VA_BITS_52
SYM_FUNC_START(__cpu_secondary_check52bitva)
#ifndef CONFIG_ARM64_LPA2
	mrs_s	x0, SYS_ID_AA64MMFR2_EL1
	and	x0, x0, ID_AA64MMFR2_EL1_VARange_MASK
	cbnz	x0, 2f
#else
	mrs	x0, id_aa64mmfr0_el1
	sbfx	x0, x0, #ID_AA64MMFR0_EL1_TGRAN_SHIFT, 4
	cmp	x0, #ID_AA64MMFR0_EL1_TGRAN_LPA2
	b.ge	2f
#endif

	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_52_BIT_VA, x0, x1
1:	wfe
	wfi
	b	1b

2:	ret
SYM_FUNC_END(__cpu_secondary_check52bitva)
#endif

SYM_FUNC_START_LOCAL(__no_granule_support)
	/* Indicate that this CPU can't boot and is stuck in the kernel */
	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_NO_GRAN, x1, x2
1:
	wfe
	wfi
	b	1b
SYM_FUNC_END(__no_granule_support)

SYM_FUNC_START_LOCAL(__primary_switch)
	adrp	x1, reserved_pg_dir
	adrp	x2, init_idmap_pg_dir
	bl	__enable_mmu

	adrp	x1, early_init_stack
	mov	sp, x1
	mov	x29, xzr
	mov	x0, x20				// pass the full boot status
	mov	x1, x21				// pass the FDT
	bl	__pi_early_map_kernel		// Map and relocate the kernel

	ldr	x8, =__primary_switched
	adrp	x0, KERNEL_START		// __pa(KERNEL_START)
	br	x8
SYM_FUNC_END(__primary_switch)
