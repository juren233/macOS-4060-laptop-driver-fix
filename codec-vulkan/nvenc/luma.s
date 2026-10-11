 .text
_f:
 movl 0x10(%r15),%ecx; shrl $6,%ecx; movl %r12d,%eax; shrl $4,%eax; imull %eax,%ecx; shll $10,%ecx
 movl %r12d,%eax; andl $0xc,%eax
 movl %r12d,%edx; andl $0xf,%edx; addl %edx,%eax
 andl $8,%edx; leal (%rax,%rdx,2),%eax; shll $4,%eax; orl %eax,%ecx
 xorl %esi,%esi
1:
 movl %esi,%r8d; andl $-64,%r8d; shll $4,%r8d; addl %ecx,%r8d
 movl %esi,%edx; andl $0x30,%edx; leal (%r8,%rdx,4),%r8d; andl $0x20,%edx; leal (%r8,%rdx,4),%r8d
 movups (%r14,%rsi),%xmm0; movups %xmm0,(%rbx,%r8)
 addq $0x10,%rsi; cmpq %r9,%rsi; jl 1b
