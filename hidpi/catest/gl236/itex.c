// itex: integer and non-2D textures through Apple's GL-on-Metal, each read back by texelFetch into a 32x32 RGBA8 FBO.
//   R8I / R8UI / R32I   isampler2D / usampler2D over integer 2D textures: the stored integers (Apple's GL picks the view
//                       format from the reflected textureDataType; reflected Float gave R8Snorm/R8Unorm views -> 255)
//   2DARRAY / I2DARRAY / 3D / CUBE   sampler2DArray, isampler2DArray, sampler3D and samplerCube read their texels
// Prints one line per case and "itex: N of 7 PASS".   cc -O2 -o itex itex.c -framework OpenGL
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
static GLuint sh(GLenum t, const char *s) { GLuint x = glCreateShader(t); glShaderSource(x, 1, &s, NULL); glCompileShader(x); GLint ok; glGetShaderiv(x, GL_COMPILE_STATUS, &ok); if (!ok) { char l[512]; glGetShaderInfoLog(x, 512, NULL, l); fprintf(stderr, "%s\n", l); exit(2); } return x; }
static int check(const char *name) {
	unsigned char px[4]; glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int ok = abs(px[0] - 201) <= 8 && abs(px[1] - 129) <= 8;
	printf("%-9s %s (%d,%d want 201,129)\n", name, ok ? "PASS" : "FAIL", px[0], px[1]);
	return ok;
}
static GLuint prog(const char *fs) {
	GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, "#version 410\nin vec3 pos; void main() { gl_Position = vec4(pos, 1); }\n")); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "pos"); glLinkProgram(p); glUseProgram(p); glUniform1i(glGetUniformLocation(p, "t"), 0); return p;
}
static void nearest(GLenum target) { glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_NEAREST); }
static void draw(void) { glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glFinish(); }
static int run(const char *samp, GLenum ifmt, GLenum fmt, GLenum type, const void *data, double scale, const char *name) {
	char fs[512]; snprintf(fs, sizeof fs, "#version 410\nuniform %s t; out vec4 o; void main() { o = vec4(float(texelFetch(t, ivec2(1,0), 0).r) / %f, float(texelFetch(t, ivec2(2,0), 0).r) / %f, 0, 1); }\n", samp, scale, scale);
	GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, "#version 410\nin vec3 pos; void main() { gl_Position = vec4(pos, 1); }\n")); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "pos"); glLinkProgram(p); glUseProgram(p);
	GLuint tex; glGenTextures(1, &tex); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glTexImage2D(GL_TEXTURE_2D, 0, ifmt, 4, 1, 0, fmt, type, data);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glUniform1i(glGetUniformLocation(p, "t"), 0);
	glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glFinish();
	int ok = check(name); glDeleteTextures(1, &tex); glDeleteProgram(p); return ok;
}
int main(void) {
	CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
	CGLPixelFormatObj pf; GLint n; CGLChoosePixelFormat(a, &pf, &n); CGLContextObj c; CGLCreateContext(pf, NULL, &c); CGLSetCurrentContext(c);
	GLuint fb, rb; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb); glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 32, 32); glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb); glViewport(0, 0, 32, 32);
	GLuint va, vb; glGenVertexArrays(1, &va); glBindVertexArray(va); glGenBuffers(1, &vb); glBindBuffer(GL_ARRAY_BUFFER, vb);
	const float q[] = { -1,-1,0, 1,-1,0, -1,1,0, 1,1,0 }; glBufferData(GL_ARRAY_BUFFER, sizeof q, q, GL_STATIC_DRAW); glVertexAttribPointer(0, 3, GL_FLOAT, 0, 12, 0); glEnableVertexAttribArray(0);
	const signed char s8[4] = { 0, 100, 64, 0 }; const unsigned char u8[4] = { 0, 200, 128, 0 }; const int s32[4] = { 0, 100000, 64000, 0 };
	int pass = 0;
	pass += run("isampler2D", GL_R8I, GL_RED_INTEGER, GL_BYTE, s8, 127.0, "R8I");
	pass += run("usampler2D", GL_R8UI, GL_RED_INTEGER, GL_UNSIGNED_BYTE, u8, 254.0, "R8UI");
	pass += run("isampler2D", GL_R32I, GL_RED_INTEGER, GL_INT, s32, 127000.0, "R32I");
	// layer 1 of a 2-layer RGBA8 array holds (201,129) at texel (1,0)
	{ unsigned char a[2][4][4] = {{{0}}}; a[1][1][0] = 201; a[1][1][1] = 129;
	  GLuint p = prog("#version 410\nuniform sampler2DArray t; out vec4 o; void main() { o = texelFetch(t, ivec3(1,0,1), 0); }\n");
	  GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D_ARRAY, tex); glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8, 4, 1, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, a);
	  nearest(GL_TEXTURE_2D_ARRAY); draw(); pass += check("2DARRAY"); glDeleteTextures(1, &tex); glDeleteProgram(p); }
	{ signed char a[2][4] = {{0}}; a[1][1] = 100; a[1][2] = 64;
	  GLuint p = prog("#version 410\nuniform isampler2DArray t; out vec4 o; void main() { o = vec4(float(texelFetch(t, ivec3(1,0,1), 0).r) / 127.0, float(texelFetch(t, ivec3(2,0,1), 0).r) / 127.0, 0, 1); }\n");
	  GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D_ARRAY, tex); glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_R8I, 4, 1, 2, 0, GL_RED_INTEGER, GL_BYTE, a);
	  nearest(GL_TEXTURE_2D_ARRAY); draw(); pass += check("I2DARRAY"); glDeleteTextures(1, &tex); glDeleteProgram(p); }
	{ unsigned char a[2][2][2][4] = {{{{0}}}}; a[1][0][1][0] = 201; a[1][0][1][1] = 129;   // z 1, y 0, x 1
	  GLuint p = prog("#version 410\nuniform sampler3D t; out vec4 o; void main() { o = texelFetch(t, ivec3(1,0,1), 0); }\n");
	  GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_3D, tex); glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA8, 2, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, a);
	  nearest(GL_TEXTURE_3D); draw(); pass += check("3D"); glDeleteTextures(1, &tex); glDeleteProgram(p); }
	{ unsigned char face[4] = { 0, 0, 0, 255 }, posx[4] = { 201, 129, 0, 255 };
	  GLuint p = prog("#version 410\nuniform samplerCube t; out vec4 o; void main() { o = texture(t, vec3(1.0, 0.0, 0.0)); }\n");
	  GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_CUBE_MAP, tex);
	  for (int f = 0; f < 6; f++) glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + f, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, f ? face : posx);
	  nearest(GL_TEXTURE_CUBE_MAP); draw(); pass += check("CUBE"); glDeleteTextures(1, &tex); glDeleteProgram(p); }
	printf("itex: %d of 7 PASS (glGetError 0x%x)\n", pass, glGetError());
	return pass == 7 ? 0 : 1;
}
