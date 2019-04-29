ENTRY(stext)
	bl	preserve_boot_args
	bl	el2_setup			// Drop to EL1, w0=cpu_boot_mode
	adrp	x23, __PHYS_OFFSET
	and	x23, x23, MIN_KIMG_ALIGN - 1	// KASLR offset, defaults to 0
	bl	set_cpu_boot_mode_flag
	bl	__create_page_tables
	/*
	 * The following calls CPU setup code, see arch/arm64/mm/proc.S for
	 * details.
	 * On return, the CPU will be ready for the MMU to be turned on and
	 * the TCR will have been set.
	 */
	bl	__cpu_setup			// initialise processor
	b	__primary_switch
ENDPROC(stext)

preserve_boot_args:
	mov	x21, x0					// x21=FDT 在UBOOT启动后，设备树地址传递到了X0， 用X21	暂时保存
	adr_l	x0, boot_args		// record the contents of  X0保存boot_args变量的地址， 这个boot_args哪里来的？
								// boot_args是一个虚拟地址，由于此时页表还未建立好，通过adr_l这个宏来完成，
								// 这个宏实际上是通过adrp这个汇编指令完成，将符号地址变成运行时地址。
								// 因而获取到了实际的物理地址（但是是以页的方式对其的）
	stp	x21, x1, [x0]			// x0 .. x3 at kernel entry，
								// x21=设备树地址，x1=0，保留以后使用的。
								// boot_args[0]=设备树地址，boot_args[1]=0，保留
	stp	x2, x3, [x0, #16]		// boot_args[2]=x2=0,保留。 boot_args[3]=x3=0，保留
								//这里的偏移为什么是16byte？？？因为是64位的X0，X1

	dmb	sy						// needed before dc ivac with 
								// Data Memory Barrier 数据内存屏障，在以上的指令还未执行完毕时，下面的指令不能执行
								// MMU off
	mov	x1, #0x20				// 4 x 8 bytes， 由于此时MMU还是关闭状态，但是实际的物理内存已经有数据更新了(boot_args指向的区域)
								// 但是boot_args内存区域对应的相应cache也需要更新。因而计算需要刷新的长度。
								// 刷新长度= sizeof(boot_args[]) = 4 x 8byte = 32byte = 0x20
	b	__inval_dcache_area		// tail call
ENDPROC(preserve_boot_args)


ENTRY(el2_setup)
	msr	SPsel, #1				// We want to use SP_EL{1,2}
								//SPsel： Stack Pointer Select 【32位寄存器】，
								//MSR <special-purpose register>, Xt ; Write to special-purpose register,写一个特殊的寄存器
								//SPsel[31:0]位保留，只有SPsel[0]位有用。
								//SPsel[0]=0:使用SP_EL0执行等级。SPsel[0]=1:使用SP_ELx执行等级
	mrs	x0, CurrentEL			//CurrentEL： Current Exception Level【32位一个寄存器】
								//获取当前的执行等级，对于CurrentEL寄存器。只有 CurrentEL[3:2]代表了执行的等级，其他均保留
								//CurrentEL[3:2]位指示如下：00-EL0  01-EL1 10-EL2 11-EL3
	cmp	x0, #CurrentEL_EL2		//判断当前是否处于EL2等级
								//#define CurrentEL_EL2              (2 << 2)
	b.eq	1f					//是处于EL2等级的话跳转到1f
	mrs	x0, sctlr_el1			//SCTLR_EL1：System Control Register (EL1) 【32位寄存器】
								//执行到这里说明不是处于EL2等级，无法掌控全局。
								
CPU_BE(	orr	x0, x0, #(3 << 24)	)	// Set the EE and E0E bits for EL1
CPU_LE(	bic	x0, x0, #(3 << 24)	)	// Clear the EE and E0E bits for EL1
	msr	sctlr_el1, x0
	mov	w0, #BOOT_CPU_MODE_EL1		// This cpu booted in EL1
	isb
	ret
1:	mrs	x0, sctlr_el2			//SCTLR_EL2：System Control Register (EL2) 【32位寄存器】
								//CPU处于EL2状态的时候，该寄存器可以控制整个系统的行为。
CPU_BE(	orr	x0, x0, #(1 << 25)	)	// Set the EE bit for EL2
									//设置sctlr_el2[25]位EE位，是大端格式还是小端格式，1 Big-endian
									//对于CPU_BE和CPU_LE会根据配置选择执行其中一个
CPU_LE(	bic	x0, x0, #(1 << 25)	)	// Clear the EE bit for EL2 
									// 0 Little-endian.
	msr	sctlr_el2, x0				//写回
#ifdef CONFIG_ARM64_VHE
	/*
	 * Check for VHE being present. For the rest of the EL2 setup,
	 * x2 being non-zero indicates that we do have VHE, and that the
	 * kernel is intended to run at EL2.
	 */
	mrs	x2, id_aa64mmfr1_el1	//ID_AA64MMFR1_EL1：AArch64 Memory Model Feature Register 1（内存模型）【64位寄存器】
								//id_aa64mmfr1_el1[63:0]全部保留,如果是非0值，则表明使用VHE
	ubfx	x2, x2, #8, #4		//无符号位段提取
#else
	mov	x2, xzr					//xzr：Zero register， 
								//x2=0
#endif
	/* Hyp configuration. */
	mov	x0, #HCR_RW				// 64-bit EL1
								//#define HCR_RW            (UL(1) << HCR_RW_SHIFT)
								//#define HCR_RW_SHIFT      31
								//x0[31] = 1
	cbz	x2, set_hcr				//是否使用VHE？
	orr	x0, x0, #HCR_TGE		// Enable Host Extensions
	orr	x0, x0, #HCR_E2H
set_hcr:
	msr	hcr_el2, x0				//HCR_EL2：Hypervisor(管理) Configuration Register 【64位寄存器】
								//当执行AARCH32时被映射成2部分：HCR和HCR2
								//提供Virtualization配置，这里第31位被设置为1，确保Low level的EL1也是Aarch64的 
	isb
	/*
	 * Allow Non-secure EL1 and EL0 to access physical timer and counter.
	 * This is not necessary for VHE, since the host kernel runs in EL2,
	 * and EL0 accesses are configured in the later stage of boot process.
	 * Note that when HCR_EL2.E2H == 1, CNTHCTL_EL2 has the same bit layout
	 * as CNTKCTL_EL1, and CNTKCTL_EL1 accessing instructions are redefined
	 * to access CNTHCTL_EL2. This allows the kernel designed to run at EL1
	 * to transparently mess with the EL0 bits via CNTKCTL_EL1 access in
	 * EL2.
	 */
	cbnz	x2, 1f
	mrs	x0, cnthctl_el2		//CNTHCTL_EL2：Counter-timer Hypervisor Control register 【32位寄存器】
	orr	x0, x0, #3			// Enable EL1 physical timers
	msr	cnthctl_el2, x0		//这里对Generic timer进行配置:
							//用来控制系统中的physical counter和virutal counter如何产生event stream
							//以及在EL1和EL0状态访问physical counter和timer的硬件行为的。
1:
	msr	cntvoff_el2, xzr	// Clear virtual offset
							//由于virutal counter=physical counter + offset。这里将offset清空
							//也就是virutal counter = physical counter，访问虚拟的实际也就是访问的物理的

#ifdef CONFIG_ARM_GIC_V3
	/* GICv3 system register access */
	mrs	x0, id_aa64pfr0_el1 	//ID_AA64PFR0_EL1：Processor Feature Register 0
	ubfx	x0, x0, #24, #4		//取出24 bit开始的4个bit的值并将该值赋给x0
								//该PE是否实现了system register来访问GIC
								//GIC：bits [27:24]
								//0000 No GIC system registers are supported
								//0001 GICv3 system registers are supported
								//其他值保留
	cmp	x0, #1
	b.ne	3f					//不支持GICv3的话就跳转
	mrs_s	x0, SYS_ICC_SRE_EL2 //ICC_SRE_EL2, Interrupt Controller System Register Enable register (EL2) 【32位寄存器】
								//中断控制使能寄存器
								//[5:0]有效，其他保留
	orr	x0, x0, #ICC_SRE_EL2_SRE	// Set ICC_SRE_EL2.SRE==1
									//:#define ICC_SRE_EL2_SRE	(1 << 0)
									//将SRE bit设定为1确保通过system register方式进行GIC interface cpu寄存器的访问
	orr	x0, x0, #ICC_SRE_EL2_ENABLE	// Set ICC_SRE_EL2.Enable==1
									//#define ICC_SRE_EL2_ENABLE	(1 << 3)
									//将enable bit设定为1确保在EL1状态的时候可以通过
									//ICC_SRE_EL1寄存器对GIC进行配置而不是陷入EL2。 
	msr_s	SYS_ICC_SRE_EL2, x0
	isb					// Make sure SRE is now set
	mrs_s	x0, SYS_ICC_SRE_EL2		// Read SRE back,
	tbz	x0, #0, 3f			// and check that it sticks
	msr_s	SYS_ICH_HCR_EL2, xzr		// Reset ICC_HCR_EL2 to defaults
3:
#endif

	/* Populate（填充） ID registers. */
	mrs	x0, midr_el1			//MIDR_EL1：Main ID Register 【32位寄存器】 只能读！！！
								//该寄存器给出了该PE的architecture信息，Implementer是谁等等信息
	mrs	x1, mpidr_el1			//MPIDR_EL1：Multiprocessor Affinity（类同） Register  【64位寄存器】
								//processor ID。
	msr	vpidr_el2, x0------------|
								 V 
	msr	vmpidr_el2, x1			//vpidr_el2和vmpidr_el2是上面的两个寄存器是对应的，
								//只不过是for virtual processor的。

#ifdef CONFIG_COMPAT			//是否支持64 bit kernel上运行32bit 的application 
	msr	hstr_el2, xzr			// Disable CP15 traps to EL2 
								//HSTR_EL2:Hypervisor System Trap Register 
#endif

	mrs	x1, id_aa64dfr0_el1		// Check ID_AA64DFR0_EL1 PMUVer
								//ID_AA64DFR0_EL1：AArch64 Debug Feature Register 0 【64位寄存器】
								//PMUVer, bits [11:8]
	sbfx	x0, x1, #8, #4		//获取从8位开始的4位数据。刚好是PMU相关的设置
	cmp	x0, #1
	b.lt	4f					// Skip if no PMU present
	mrs	x0, pmcr_el0			// Disable debug access traps
	ubfx	x0, x0, #11, #5			// to EL2 and allow access to
4:
	csel	x3, xzr, x0, lt			// all PMU counters from EL1


	ubfx	x0, x1, #32, #4			// Check ID_AA64DFR0_EL1 PMSVer
	cbz	x0, 6f				// Skip if SPE not present
	cbnz	x2, 5f				// VHE?
	mov	x1, #(MDCR_EL2_E2PB_MASK << MDCR_EL2_E2PB_SHIFT)
	orr	x3, x3, x1			// If we dont have VHE, then
	b	6f					// use EL1&0 translation
	
5:							// For VHE, use EL2 translation
	orr	x3, x3, #MDCR_EL2_TPMS		// and disable access from EL1
6:
	msr	mdcr_el2, x3			// Configure debug traps
	/* Stage-2 translation */
	msr	vttbr_el2, xzr
	cbz	x2, install_el2_stub
	mov	w0, #BOOT_CPU_MODE_EL2		// This CPU booted in EL2
									//#define BOOT_CPU_MODE_EL2    (0xe12)
	isb
	ret						//

install_el2_stub:
	/*
	 * When VHE is not in use, early init of EL2 and EL1 needs to be
	 * done here.
	 * When VHE _is_ in use, EL1 will not be used in the host and
	 * requires no configuration, and all non-hyp-specific EL2 setup
	 * will be done via the _EL1 system register aliases in __cpu_setup.
	 */
	/* sctlr_el1 */
	mov	x0, #0x0800			// Set/clear RES{1,0} bits
CPU_BE(	movk	x0, #0x33d0, lsl #16	)	// Set EE and E0E on BE systems
											//实际将0x33d00800放入x0
CPU_LE(	movk	x0, #0x30d0, lsl #16	)	// Clear EE and E0E on LE systems
	msr	sctlr_el1, x0						//SCTLR_EL1：System Control Register (EL1) 【32位寄存器】
	/* Coprocessor traps. */
	mov	x0, #0x33ff
	msr	cptr_el2, x0			// Disable copro. traps to EL2
	/* Hypervisor stub */
	adr_l	x0, __hyp_stub_vectors  //获取异常向量表相对地址
	msr	vbar_el2, x0				//VBAR_EL2： Vector Base Address Register (EL2) 【64位寄存器】
									//Bits [63:11]有用，其他保留
	/* spsr */
	mov	x0, #(PSR_F_BIT | PSR_I_BIT | PSR_A_BIT | PSR_D_BIT |\
		      PSR_MODE_EL1h)
	msr	spsr_el2, x0
	msr	elr_el2, lr
	mov	w0, #BOOT_CPU_MODE_EL2		// This CPU booted in EL2-------------w0------------|
	eret                                                                                |
ENDPROC(el2_setup)                                                                      |
                                                                                        |
/*                                                                                      |
 * Sets the __boot_cpu_mode flag depending on the CPU boot mode passed                  |
 * in w0. See arch/arm64/include/asm/virt.h for more info.                              |
 */                                                                                     |
set_cpu_boot_mode_flag:                                                                 |
	adr_l	x1, __boot_cpu_mode		//获取到了实际的物理地址 							|
									//全局变量_boot_cpu_mode用来保存启动时候的CPU mode。|
	cmp	w0, #BOOT_CPU_MODE_EL2		//进入这个函数前需要判定是否是从EL2启动--------<----|
									//__boot_cpu_mode内存布局
									//ENTRY(__boot_cpu_mode)
									//.long    BOOT_CPU_MODE_EL2－－－－－－－－A
									//.long    BOOT_CPU_MODE_EL1－－－－－－－－B 
	b.ne	1f
	add	x1, x1, #4
1:	str	w0, [x1]			// This CPU has booted in EL1
	dmb	sy
	dc	ivac, x1			// Invalidate potentially stale cache line
	ret
ENDPROC(set_cpu_boot_mode_flag)

__create_page_tables:
	mov	x28, lr				//保存返回地址
	/*
	 * Invalidate the idmap and swapper page tables to avoid potential
	 * dirty cache lines being evicted.
	 */
	adrp	x0, idmap_pg_dir	//获取idmap的页表基地址（物理地址）
	ldr	x1, =(IDMAP_DIR_SIZE + SWAPPER_DIR_SIZE + RESERVED_TTBR0_SIZE)	//idmap的页表结束地址
	bl	__inval_dcache_area		//在页表清除前需要先对cache进行无效操作。因为这个时候mmu还没有开启
	/*
	 * Clear the idmap and swapper page tables.
	 */
	adrp	x0, idmap_pg_dir	//重新获取idmap的页表基地址（物理地址）
	ldr	x1, =(IDMAP_DIR_SIZE + SWAPPER_DIR_SIZE + RESERVED_TTBR0_SIZE)  //idmap的页表结束地址
																		//#define IDMAP_DIR_SIZE	(IDMAP_PGTABLE_LEVELS * PAGE_SIZE)
1:	stp	xzr, xzr, [x0], #16		//页表清零
	stp	xzr, xzr, [x0], #16
	stp	xzr, xzr, [x0], #16
	stp	xzr, xzr, [x0], #16
	subs	x1, x1, #64			//相当于cmp	x0, x1 ，实则就是判断页表清零是否到达了结束地址
	b.ne	1b
	mov	x7, SWAPPER_MM_MMUFLAGS //#define SWAPPER_MM_MMUFLAGS	(PMD_ATTRINDX(MT_NORMAL) | SWAPPER_PMD_FLAGS)
								//
	/*
	 * Create the identity mapping.
	 */
	adrp	x0, idmap_pg_dir
	adrp	x3, __idmap_text_start		// __pa(__idmap_text_start)
										//VMLINUX_SYMBOL(__idmap_text_start) = .;

#ifndef CONFIG_ARM64_VA_BITS_48
#define EXTRA_SHIFT	(PGDIR_SHIFT + PAGE_SHIFT - 3)
#define EXTRA_PTRS	(1 << (48 - EXTRA_SHIFT))
	/*
	 * If VA_BITS < 48, it may be too small to allow for an ID mapping to be
	 * created that covers system RAM if that is located sufficiently high
	 * in the physical address space. So for the ID map, use an extended
	 * virtual range in that case, by configuring an additional translation
	 * level.
	 * First, we have to verify our assumption that the current value of
	 * VA_BITS was chosen such that all translation levels are fully
	 * utilised, and that lowering T0SZ will always result in an additional
	 * translation level to be configured.
	 */
#if VA_BITS != EXTRA_SHIFT
#error "Mismatch between VA_BITS and page size/number of translation levels"
#endif
	/*
	 * Calculate the maximum allowed value for TCR_EL1.T0SZ so that the
	 * entire ID map region can be mapped. As T0SZ == (64 - #bits used),
	 * this number conveniently equals the number of leading zeroes in
	 * the physical address of __idmap_text_end.
	 */
	adrp	x5, __idmap_text_end
	clz	x5, x5
	cmp	x5, TCR_T0SZ(VA_BITS)	// default T0SZ small enough?
	b.ge	1f			// .. then skip additional level

	adr_l	x6, idmap_t0sz
	str	x5, [x6]
	dmb	sy
	dc	ivac, x6		// Invalidate potentially stale cache line
	create_table_entry x0, x3, EXTRA_SHIFT, EXTRA_PTRS, x5, x6
1:
#endif

	create_pgd_entry x0, x3, x5, x6
	mov	x5, x3				// __pa(__idmap_text_start)
	adr_l	x6, __idmap_text_end		// __pa(__idmap_text_end)
	create_block_map x0, x7, x3, x5, x6
	/*
	 * Map the kernel image (starting with PHYS_OFFSET).
	 */
	adrp	x0, swapper_pg_dir
	mov_q	x5, KIMAGE_VADDR + TEXT_OFFSET	// compile time __va(_text)
	add	x5, x5, x23			// add KASLR displacement
	create_pgd_entry x0, x5, x3, x6
	adrp	x6, _end			// runtime __pa(_end)
	adrp	x3, _text			// runtime __pa(_text)
	sub	x6, x6, x3			// _end - _text
	add	x6, x6, x5			// runtime __va(_end)
	create_block_map x0, x7, x3, x5, x6
	/*
	 * Since the page tables have been populated with non-cacheable
	 * accesses (MMU disabled), invalidate the idmap and swapper page
	 * tables again to remove any speculatively loaded cache lines.
	 */
	adrp	x0, idmap_pg_dir
	ldr	x1, =(IDMAP_DIR_SIZE + SWAPPER_DIR_SIZE + RESERVED_TTBR0_SIZE)
	dmb	sy
	bl	__inval_dcache_area
	ret	x28
ENDPROC(__create_page_tables)


ENTRY(__cpu_setup)
	tlbi	vmalle1				// Invalidate local TLB
	dsb	nsh

	mov	x0, #3 << 20
	msr	cpacr_el1, x0			// Enable FP/ASIMD
	mov	x0, #1 << 12			// Reset mdscr_el1 and disable
	msr	mdscr_el1, x0			// access to the DCC from EL0
	isb					// Unmask debug exceptions now,
	enable_dbg				// since this is per-cpu
	reset_pmuserenr_el0 x0			// Disable PMU access from EL0
	/*
	 * Memory region attributes for LPAE:
	 *
	 *   n = AttrIndx[2:0]
	 *			n	MAIR
	 *   DEVICE_nGnRnE	000	00000000
	 *   DEVICE_nGnRE	001	00000100
	 *   DEVICE_GRE		010	00001100
	 *   NORMAL_NC		011	01000100
	 *   NORMAL		100	11111111
	 *   NORMAL_WT		101	10111011
	 */
	ldr	x5, =MAIR(0x00, MT_DEVICE_nGnRnE) | \
		     MAIR(0x04, MT_DEVICE_nGnRE) | \
		     MAIR(0x0c, MT_DEVICE_GRE) | \
		     MAIR(0x44, MT_NORMAL_NC) | \
		     MAIR(0xff, MT_NORMAL) | \
		     MAIR(0xbb, MT_NORMAL_WT)
	msr	mair_el1, x5
	/*
	 * Prepare SCTLR
	 */
	adr	x5, crval
	ldp	w5, w6, [x5]
	mrs	x0, sctlr_el1
	bic	x0, x0, x5			// clear bits
	orr	x0, x0, x6			// set bits
	/*
	 * Set/prepare TCR and TTBR. We use 512GB (39-bit) address range for
	 * both user and kernel.
	 */
	ldr	x10, =TCR_TxSZ(VA_BITS) | TCR_CACHE_FLAGS | TCR_SMP_FLAGS | \
			TCR_TG_FLAGS | TCR_ASID16 | TCR_TBI0 | TCR_A1
	tcr_set_idmap_t0sz	x10, x9

	/*
	 * Read the PARange bits from ID_AA64MMFR0_EL1 and set the IPS bits in
	 * TCR_EL1.
	 */
	mrs	x9, ID_AA64MMFR0_EL1
	bfi	x10, x9, #32, #3
#ifdef CONFIG_ARM64_HW_AFDBM
	/*
	 * Hardware update of the Access and Dirty bits.
	 */
	mrs	x9, ID_AA64MMFR1_EL1
	and	x9, x9, #0xf
	cbz	x9, 2f
	cmp	x9, #2
	b.lt	1f
#ifdef CONFIG_ARM64_ERRATUM_1024718
	/* Disable hardware DBM on Cortex-A55 r0p0, r0p1 & r1p0 */
	cpu_midr_match MIDR_CORTEX_A55, MIDR_CPU_VAR_REV(0, 0), MIDR_CPU_VAR_REV(1, 0), x1, x2, x3, x4
	cbnz	x1, 1f
#endif
	orr	x10, x10, #TCR_HD		// hardware Dirty flag update
1:	orr	x10, x10, #TCR_HA		// hardware Access flag update
2:
#endif	/* CONFIG_ARM64_HW_AFDBM */
	msr	tcr_el1, x10
	ret					// return to head.S
ENDPROC(__cpu_setup)

	/*
	 * We set the desired value explicitly, including those of the
	 * reserved bits. The values of bits EE & E0E were set early in
	 * el2_setup, which are left untouched below.
	 *
	 *                 n n            T
	 *       U E      WT T UD     US IHBS
	 *       CE0      XWHW CZ     ME TEEA S
	 * .... .IEE .... NEAI TE.I ..AD DEN0 ACAM
	 * 0011 0... 1101 ..0. ..0. 10.. .0.. .... < hardware reserved
	 * .... .1.. .... 01.1 11.1 ..01 0.01 1101 < software settings
	 */
	.type	crval, #object
crval:
	.word	0xfcffffff			// clear
	.word	0x34d5d91d			// set
	.popsection