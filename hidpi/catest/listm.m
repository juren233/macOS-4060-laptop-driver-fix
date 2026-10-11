#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
int main(void) { @autoreleasepool { id d = MTLCreateSystemDefaultDevice(); for (Class c = object_getClass(d); c; c = class_getSuperclass(c)) { unsigned n; Method *m = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) { const char *s = sel_getName(method_getName(m[i])); if (strcasestr(s, "surface") || strcasestr(s, "shared") ) printf("%s: %s\n", class_getName(c), s); } free(m); } return 0; } }
