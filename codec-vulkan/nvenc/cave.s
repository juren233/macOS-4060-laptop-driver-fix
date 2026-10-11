 .text
_hook_enc:
 incl 0x88(%r14)
 movq %r14,%rdi
 movq -0x88(%rbp),%rsi
 movl -0x2c(%rbp),%edx
 leaq 0x10(%rbp),%rcx
 jmp _rc
_hook_br:
 cvttsd2si -0x30(%rbp),%rax
 xorl %edx,%edx
 movl $1000,%ecx
 divq %rcx
 movl %eax,0x74(%rbx)
 .byte 0x83,0x3d,0x11,0x22,0x33,0x44,0x00
 ret
_rc:                                    ## @rc
## %bb.0:
	pushq	%rbp
	movq	%rsp, %rbp
	movl	116(%rdi), %r10d
	testq	%r10, %r10
	je	LBB0_25
## %bb.1:
	movl	%edx, %r9d
	testb	$1, 12(%rcx)
	je	LBB0_2
## %bb.3:
	movslq	8(%rcx), %r8
	testq	%r8, %r8
	jle	LBB0_2
## %bb.4:
	movq	(%rcx), %rax
	movq	%rax, %rcx
	shrq	$32, %rcx
	je	LBB0_7
## %bb.5:
	cqto
	idivq	%r8
	jmp	LBB0_8
LBB0_2:
	xorl	%eax, %eax
	jmp	LBB0_12
LBB0_7:
                                        ## kill: def $eax killed $eax killed $rax
	xorl	%edx, %edx
	divl	%r8d
                                        ## kill: def $edx killed $edx def $rdx
                                        ## kill: def $eax killed $eax def $rax
LBB0_8:
	imulq	$1000000, %rax, %rcx            ## imm = 0xF4240
	imulq	$1000000, %rdx, %rax            ## imm = 0xF4240
	movq	%rax, %rdx
	shrq	$32, %rdx
	je	LBB0_10
## %bb.9:
	cqto
	idivq	%r8
	jmp	LBB0_11
LBB0_10:
                                        ## kill: def $eax killed $eax killed $rax
	xorl	%edx, %edx
	divl	%r8d
                                        ## kill: def $eax killed $eax def $rax
LBB0_11:
	addq	%rcx, %rax
LBB0_12:
	movq	%rax, %rcx
	subq	160(%rdi), %rcx
	movq	%rax, 160(%rdi)
	leaq	-1000001(%rcx), %rax
	cmpq	$-1000001, %rax                 ## imm = 0xFFF0BDBF
	ja	LBB0_14
## %bb.13:
	movl	108(%rdi), %eax
	leal	-241(%rax), %ecx
	cmpl	$-236, %ecx
	movl	$40, %ecx
	cmovael	%eax, %ecx
	movl	$1000000, %eax                  ## imm = 0xF4240
	xorl	%edx, %edx
	idivl	%ecx
	movslq	%eax, %rcx
LBB0_14:
	cmpq	$8001, %rcx                     ## imm = 0x1F41
	movl	$8000, %eax                     ## imm = 0x1F40
	cmovgeq	%rcx, %rax
	cmpq	$100000, %rax                   ## imm = 0x186A0
	movl	$100000, %r8d                   ## imm = 0x186A0
	cmovlq	%rax, %r8
	imulq	%r10, %r8
	movabsq	$2305843009213694, %rcx         ## imm = 0x83126E978D4FE
	movq	%r8, %rax
	mulq	%rcx
	testl	%r9d, %r9d
	je	LBB0_16
## %bb.15:
	leaq	3(%rsi), %rax
	testq	%rsi, %rsi
	cmovnsq	%rsi, %rax
	sarq	$2, %rax
	movq	%rax, %rsi
LBB0_16:
	movl	100(%rdi), %ecx
	leaq	(%rdx,%rdx), %rax
	cmpq	%rax, %rsi
	jle	LBB0_18
## %bb.17:
	addl	$3, %ecx
	jmp	LBB0_23
LBB0_18:
	movq	%rdx, %rax
	shrq	$2, %rax
	addq	%rdx, %rax
	cmpq	%rax, %rsi
	jle	LBB0_20
## %bb.19:
	incl	%ecx
	jmp	LBB0_23
LBB0_20:
	shrq	$7, %r8
	movabsq	$147573952589676413, %rdx       ## imm = 0x20C49BA5E353F7D
	movq	%r8, %rax
	mulq	%rdx
	cmpq	%rdx, %rsi
	jge	LBB0_23
## %bb.21:
	movl	148(%rdi), %eax
	leal	1(%rax), %edx
	movl	%edx, 148(%rdi)
	cmpl	$3, %eax
	jl	LBB0_24
## %bb.22:
	decl	%ecx
LBB0_23:
	movl	$0, 148(%rdi)
LBB0_24:
	cmpl	$19, %ecx
	movl	$18, %eax
	cmovgel	%ecx, %eax
	cmpl	$45, %eax
	movl	$45, %ecx
	cmovll	%eax, %ecx
	movl	%ecx, 100(%rdi)
LBB0_25:
	popq	%rbp
	retq
                                        ## -- End function
